using System.Diagnostics;
using System.IO;
using System.Text;
using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// App-spawned one-shot engine process in <c>-Protocol jsonl</c> mode (design §3.2/§3.3).
/// Spawn timeout 15 s (no hello ⇒ E_ENGINE_SPAWN); no timeout for the result line; a schema-valid
/// terminal result is authoritative regardless of exit code. The interpreter is pinned to
/// <c>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</c> with
/// <c>-NoProfile -ExecutionPolicy Bypass</c>, mirroring the Task 3 broker hardening.
/// </summary>
public sealed class EngineProcessClient : IEngineClient
{
    private const int SpawnTimeoutMilliseconds = 15_000;
    private const int PostResultExitGraceMilliseconds = 30_000;
    private const int StderrTailLength = 512;

    /// <summary>Shared, single-run state between the stdout reader, the watchdog, and the classifier.</summary>
    private sealed class RunState
    {
        public volatile bool HelloSeen;

        public volatile bool StreamEnded;

        public string? ProtocolError;

        public ProtocolResponse? Terminal;
    }

    private readonly EngineLocator _locator;
    private readonly AppLog _appLog;
    private readonly LocalizationManager _localization;
    private readonly Func<ProcessStartInfo, Process?> _startProcess;

    public EngineProcessClient(EngineLocator locator, AppLog appLog, LocalizationManager localization)
        : this(locator, appLog, localization, startProcess: null)
    {
    }

    /// <summary>Test seam only: production code always spawns through Process.Start.</summary>
    internal EngineProcessClient(
        EngineLocator locator,
        AppLog appLog,
        LocalizationManager localization,
        Func<ProcessStartInfo, Process?>? startProcess)
    {
        _locator = locator;
        _appLog = appLog;
        _localization = localization;
        _startProcess = startProcess ?? (startInfo => Process.Start(startInfo));
    }

    /// <summary>The pinned interpreter path (System32\WindowsPowerShell\v1.0\powershell.exe), never PATH-resolved.</summary>
    internal static string ResolvedPowerShellPath => ResolvePowerShellPath();

    public async Task<EngineRunResult> RunAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken)
    {
        var enginePath = _locator.Locate();
        if (enginePath is null)
        {
            return Fault(ErrorCode.NotInstalled, "Engine_NotInstalled", nextStepKey: "Engine_NextStep_InstallEngine");
        }

        if (!ProtocolArgs.TryBuild(action, args, out var wireArgs, out var argumentError))
        {
            _appLog.Write("warn", $"{action} arguments failed app-side mapping: {argumentError}");
            return Fault(ErrorCode.Validation, "Engine_ArgumentMapping", detail: argumentError);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return Fault(ErrorCode.Cancelled, "Engine_CancelledBeforeStart");
        }

        // The library does not validate operationId; the app generates a GUID per operation.
        var operationId = Guid.NewGuid().ToString("D");
        var request = new ProtocolRequest { Action = action, OperationId = operationId, Args = wireArgs };

        var startInfo = new ProcessStartInfo
        {
            FileName = ResolvedPowerShellPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(enginePath) ?? string.Empty,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            // The engine reads UTF-8; do not let the console code page add a BOM.
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in new[]
                 {
                     "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", enginePath, "-Protocol", "jsonl",
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }

        _appLog.Write("info", $"Spawning {EngineLocator.InstallDirectory}\\manager.ps1 for {action} (operation {operationId}).");

        Process? process;
        try
        {
            process = _startProcess(startInfo);
        }
        catch (Exception exception)
        {
            _appLog.Write("warn", $"The engine could not be started: {exception.Message}");
            return Fault(ErrorCode.EngineSpawn, "Engine_SpawnFailed", detail: exception.Message);
        }

        if (process is null)
        {
            return Fault(ErrorCode.EngineSpawn, "Engine_SpawnFailed");
        }

        // Statement of intent: the cancellation token is not honored again after the spawn. App-side
        // cancel stops WAITING (the view model), never the engine child; the reader keeps draining
        // until the terminal result so the operation is recorded exactly once (design §5.3).
        // No continuation may resume on the caller's synchronization context: the caller is the UI
        // thread, and it must stay free to paint while the engine runs (1.2.5 deadlock class).
        return await RunCoreAsync(process, action, request, progress).ConfigureAwait(false);
    }

    private async Task<EngineRunResult> RunCoreAsync(
        Process process,
        ProtocolAction action,
        ProtocolRequest request,
        IProgress<ProtocolResponse> progress)
    {
        var state = new RunState();

        try
        {
            var stderrTask = ReadStderrAsync(process);
            var stdoutTask = RunStdoutLoopAsync(process, request, progress, state);

            // Fire-and-forget: the 15 s spawn watchdog kills the tree only if hello is still absent.
            _ = WatchSpawnAsync(process, state);

            // Write the single request line, then close stdin (EOF: exactly one JSON request).
            process.StandardInput.WriteLine(ProtocolJson.Serialize(request));
            process.StandardInput.Close();

            await stdoutTask.ConfigureAwait(false);

            var exitCode = await TryWaitForExitAsync(process, state.Terminal is not null ? PostResultExitGraceMilliseconds : null).ConfigureAwait(false);
            var stderr = await ReadStderrTailAsync(stderrTask).ConfigureAwait(false);

            if (state.Terminal is null)
            {
                var code = state.HelloSeen ? ErrorCode.Protocol : ErrorCode.EngineSpawn;
                var messageKey = state.HelloSeen ? "Engine_Run_NoTerminal" : "Engine_Run_NoHello";
                if (state.HelloSeen && state.ProtocolError is not null)
                {
                    messageKey = "Engine_Run_InvalidLine";
                }

                _appLog.Write("warn", $"Engine run for {action} ended without a terminal result (exit {exitCode?.ToString() ?? "?"}).");
                return new EngineRunResult
                {
                    Ok = false,
                    Code = code,
                    Message = _localization.GetString(messageKey),
                    CurrentState = "unknown",
                    RestoredState = "notRequired",
                    NextStep = _localization.GetString("Engine_NextStep_InspectLog"),
                    StderrTail = stderr,
                    ExitCode = exitCode,
                    LogPath = null,
                };
            }

            // A schema-valid terminal result is authoritative regardless of exit code (design §3.2).
            if (action == ProtocolAction.Status && state.Terminal.Ok == true && !state.Terminal.TryGetStatusSnapshot(out _))
            {
                _appLog.Write("warn", "The status result was ok=true but its data payload is not a valid snapshot object.");
                return new EngineRunResult
                {
                    Ok = false,
                    Code = ErrorCode.Protocol,
                    Message = _localization.GetString("Engine_Status_InvalidSnapshot"),
                    CurrentState = "unknown",
                    RestoredState = "notRequired",
                    NextStep = _localization.GetString("Engine_NextStep_InspectLog"),
                    StderrTail = stderr,
                    ExitCode = exitCode,
                    Data = state.Terminal.Data,
                };
            }

            return new EngineRunResult
            {
                Ok = state.Terminal.Ok ?? false,
                Code = state.Terminal.Code ?? ErrorCode.EngineGeneric,
                Message = state.Terminal.Message ?? string.Empty,
                CurrentState = state.Terminal.CurrentState ?? string.Empty,
                RestoredState = state.Terminal.RestoredState ?? string.Empty,
                NextStep = state.Terminal.NextStep ?? string.Empty,
                StderrTail = stderr,
                ExitCode = exitCode,
                Data = state.Terminal.Data,
                LogPath = state.Terminal.TranscriptPath,
                // Note: state.HelloSeen is retained only for logging; a valid terminal is authoritative.
            };
        }
        catch (Exception exception)
        {
            _appLog.Write("warn", $"Engine run failed: {exception.Message}");
            return new EngineRunResult
            {
                Ok = false,
                Code = ErrorCode.EngineGeneric,
                Message = _localization.GetString("Engine_Run_Failed"),
                CurrentState = "unknown",
                RestoredState = "notRequired",
                NextStep = _localization.GetString("Engine_NextStep_InspectLog"),
                StderrTail = exception.Message,
            };
        }
        finally
        {
            TryDisposeProcess(process);
        }
    }

    private async Task RunStdoutLoopAsync(
        Process process,
        ProtocolRequest request,
        IProgress<ProtocolResponse> progress,
        RunState state)
    {
        await Task.Run(() =>
        {
            using var stdout = new StreamReader(
                process.StandardOutput.BaseStream,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: true,
                bufferSize: 4096,
                leaveOpen: true);

            string? line;
            while ((line = stdout.ReadLine()) is not null)
            {
                line = StripBomPrefix(line);
                if (!ProtocolJson.TryDeserializeLine(line, out var response, out var lineError) || response is null)
                {
                    state.ProtocolError ??= lineError ?? "The engine wrote an invalid JSONL line.";
                    continue;
                }

                switch (response.Type)
                {
                    case "hello":
                        state.HelloSeen = true;
                        break;
                    case "result":
                        state.Terminal = response;
                        return;
                    default:
                        progress.Report(response);
                        break;
                }
            }

            state.StreamEnded = true;
        }).ConfigureAwait(false);
    }

    private async Task WatchSpawnAsync(Process process, RunState state)
    {
        await Task.Delay(SpawnTimeoutMilliseconds).ConfigureAwait(false);
        if (state.HelloSeen || state.Terminal is not null)
        {
            return;
        }

        _appLog.Write("warn", "The engine did not emit hello within 15 s; killing the tree.");
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception)
        {
            // The process already exited; classification continues below.
        }
    }

    private EngineRunResult Fault(ErrorCode code, string messageKey, string? detail = null, string? nextStepKey = null)
    {
        var message = _localization.GetString(messageKey);
        if (!string.IsNullOrEmpty(detail))
        {
            message += " (" + detail + ")";
        }

        return new EngineRunResult
        {
            Ok = false,
            Code = code,
            Message = message,
            CurrentState = "unchanged",
            RestoredState = "notRequired",
            NextStep = _localization.GetString(nextStepKey ?? "Engine_NextStep_InspectLog"),
        };
    }

    private static async Task<int?> TryWaitForExitAsync(Process process, int? postResultGraceMilliseconds)
    {
        int? exitCode = null;
        try
        {
            if (postResultGraceMilliseconds is null)
            {
                await process.WaitForExitAsync().ConfigureAwait(false);
            }
            else
            {
                using var grace = new CancellationTokenSource(postResultGraceMilliseconds.Value);
                try
                {
                    await process.WaitForExitAsync(grace.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // The operation is already terminal; do not let a stuck engine block the session.
                    try
                    {
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync().ConfigureAwait(false);
                    }
                    catch (Exception)
                    {
                        // Best effort only; the terminal result remains authoritative.
                    }
                }
            }

            if (process.HasExited)
            {
                exitCode = process.ExitCode;
            }
        }
        catch (Exception)
        {
            // A vanished or unqueryable process: the exit code stays unknown.
        }

        return exitCode;
    }

    private static async Task<string> ReadStderrAsync(Process process)
    {
        try
        {
            return await process.StandardError.ReadToEndAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }

    private static async Task<string> ReadStderrTailAsync(Task<string> stderrTask)
    {
        string stderr;
        try
        {
            stderr = await stderrTask.ConfigureAwait(false);
        }
        catch (Exception)
        {
            return string.Empty;
        }

        if (string.IsNullOrEmpty(stderr) || stderr.Length <= StderrTailLength)
        {
            return stderr;
        }

        return stderr[^StderrTailLength..];
    }

    private static void TryDisposeProcess(Process process)
    {
        try
        {
            process.Dispose();
        }
        catch
        {
            // Ignore; the process object is disposable-only.
        }
    }

    internal static string StripBomPrefix(string line)
        => line.Length > 0 && line[0] == '\uFEFF' ? line[1..] : line;

    private static string ResolvePowerShellPath()
    {
        var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
        if (string.IsNullOrWhiteSpace(systemDirectory))
        {
            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
            systemDirectory = Path.Combine(systemRoot, "System32");
        }

        return Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
    }
}
