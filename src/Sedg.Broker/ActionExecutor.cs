using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Sedg.Protocol;

namespace Sedg.Broker;

/// <summary>Executes a validated action by spawning the one engine copy in JSONL mode.</summary>
public sealed class ActionExecutor
{
    private const int PostResultExitGraceMilliseconds = 30_000;
    private const int DiagnosticTailLength = 512;
    private static readonly string PowerShellPath = ResolvePowerShellPath();

    private readonly string _enginePath;
    private readonly bool _validateEnginePath;
    private readonly Func<ProcessStartInfo, Process?> _startProcess;

    public ActionExecutor()
        : this(EnginePathValidator.EnginePath, validateEnginePath: true, startProcess: null)
    {
    }

    /// <summary>Test seam only: the production entry point always uses the hardcoded validated engine path.</summary>
    internal ActionExecutor(
        string enginePath,
        bool validateEnginePath = true,
        Func<ProcessStartInfo, Process?>? startProcess = null)
    {
        _enginePath = enginePath;
        _validateEnginePath = validateEnginePath;
        _startProcess = startProcess ?? (startInfo => Process.Start(startInfo));
    }

    public ProtocolResponse Execute(ProtocolRequest request, IProgress<ProtocolResponse>? progress)
    {
        try
        {
            if (_validateEnginePath)
            {
                var pathValidator = new EnginePathValidator(_enginePath);
                if (!pathValidator.Validate(out var pathError))
                {
                    return BrokerResults.Error(
                        ErrorCode.EngineSpawn,
                        "The engine path failed validation: " + pathError);
                }
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = PowerShellPath,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(_enginePath) ?? string.Empty,
                // The engine reads UTF-8; do not let the console code page add a BOM.
                StandardInputEncoding = new UTF8Encoding(false),
            };
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(_enginePath);
            startInfo.ArgumentList.Add("-Protocol");
            startInfo.ArgumentList.Add("jsonl");

            using var process = _startProcess(startInfo);
            if (process is null)
            {
                return BrokerResults.Error(ErrorCode.EngineSpawn, "The engine process could not be started.");
            }

            var stderrTask = process.StandardError.ReadToEndAsync();
            using var stdout = new StreamReader(
                process.StandardOutput.BaseStream,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: true,
                bufferSize: 4096,
                leaveOpen: true);

            process.StandardInput.WriteLine(ProtocolJson.Serialize(request));
            process.StandardInput.Close();

            ProtocolResponse? terminal = null;
            var sawHello = false;
            string? protocolError = null;

            string? line;
            while ((line = stdout.ReadLine()) is not null)
            {
                if (!ProtocolJson.TryDeserializeLine(line, out var response, out var lineError) || response is null)
                {
                    protocolError ??= lineError ?? "The engine wrote an invalid JSONL line.";
                    continue;
                }

                if (string.Equals(response.Type, "result", StringComparison.Ordinal))
                {
                    terminal = response;
                    break;
                }

                if (string.Equals(response.Type, "hello", StringComparison.Ordinal))
                {
                    sawHello = true;
                }

                progress?.Report(response);
            }

            if (terminal is null)
            {
                process.WaitForExit();
            }
            else if (!process.WaitForExit(PostResultExitGraceMilliseconds))
            {
                // The operation is already terminal; do not let a stuck engine block the session.
                try
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit();
                }
                catch (Exception)
                {
                    // Best effort only; the terminal result remains authoritative.
                }
            }

            var stderr = ReadStderr(stderrTask);

            if (terminal is null)
            {
                var diagnostic = Truncate(stderr);
                if (!sawHello)
                {
                    return BrokerResults.Error(
                        ErrorCode.EngineSpawn,
                        AppendDiagnostic("The engine did not complete its hello handshake.", diagnostic));
                }

                return BrokerResults.Error(
                    ErrorCode.Protocol,
                    AppendDiagnostic(protocolError ?? "The engine did not produce a terminal result.", diagnostic));
            }

            if (request.Action == ProtocolAction.Status && terminal.Ok == true)
            {
                if (terminal.Data is null || terminal.Data.Value.ValueKind != JsonValueKind.Object)
                {
                    return BrokerResults.Error(
                        ErrorCode.Protocol,
                        "The status result did not include a snapshot object.");
                }

                if (!terminal.TryGetStatusSnapshot(out _))
                {
                    return BrokerResults.Error(
                        ErrorCode.Protocol,
                        "The status result data is not a valid StatusSnapshot.");
                }
            }

            return terminal;
        }
        catch (Exception exception)
        {
            return BrokerResults.Error(ErrorCode.EngineGeneric, exception.Message, currentState: "unknown");
        }
    }

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

    private static string ReadStderr(Task<string> stderrTask)
    {
        try
        {
            return stderrTask.GetAwaiter().GetResult();
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }

    private static string AppendDiagnostic(string message, string stderr)
    {
        if (string.IsNullOrWhiteSpace(stderr))
        {
            return message;
        }

        return message + " stderr: " + stderr;
    }

    private static string Truncate(string value)
    {
        if (value.Length <= DiagnosticTailLength)
        {
            return value;
        }

        return value[^DiagnosticTailLength..];
    }
}
