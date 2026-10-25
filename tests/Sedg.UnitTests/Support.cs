namespace Sedg.UnitTests;

using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Sedg.Desktop.Services;
using Sedg.Protocol;

/// <summary>
/// Shared fixtures: disposable temporary directories, fake clients, and small builders.
/// Everything external (engine, broker, clock, preflight probes, app-data paths) is faked;
/// writes outside the owning per-run temporary directory never happen.
/// </summary>
public static class Support
{
    private static int _counter;

    /// <summary>Creates a per-test directory under the run's percent-TEMP%; the test cleans it in finally.</summary>
    public static string NewTempDirectory()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "Sedg.UnitTests",
            DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + Interlocked.Increment(ref _counter));
        Directory.CreateDirectory(root);
        return root;
    }

    /// <summary>Localization bound to a temporary settings directory (never the real app-data path).</summary>
    public static LocalizationManager NewLocalization(string settingsDirectory)
        => new(settingsDirectory, null);

    /// <summary>A Preflight that reports Windows 11 x64, .NET 10, engine present, and no warnings.</summary>
    public static Preflight AllGreenPreflight(LocalizationManager localization)
        => new(
            new EngineLocator(Path.Combine(Path.GetTempPath(), "Sedg.UnitTests", "not-installed", "manager.ps1")),
            localization,
            osVersionOverride: new Version(10, 0, 26300),
            is64BitOsOverride: true,
            is64BitProcessOverride: true,
            networkUpOverride: true,
            freeBytesOverride: 1_000_000_000,
            editionOverride: string.Empty,
            enginePathExistsOverride: true);

    public static AppLog NewAppLog(string baseDirectory)
        => new(baseDirectory, () => DateTimeOffset.Parse("2026-01-01T12:00:00Z", CultureInfo.InvariantCulture));

    /// <summary>Polls a condition on a dedicated polling cadence; returns false after the budget elapses.</summary>
    public static bool WaitUntil(Func<bool> condition, int milliseconds = 5_000)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.ElapsedMilliseconds > milliseconds)
            {
                return false;
            }

            Thread.Sleep(25);
        }

        return true;
    }

    /// <summary>
    /// Reads all lines of an operations log, waiting out a concurrent record append: the writer
    /// holds its handle mid-write, so a plain read can hit a sharing violation (and the file does
    /// not exist until the first record). The deadline elapses into empty lines; asserts report it.
    /// </summary>
    public static string[] ReadOperationLines(string path, Func<string[], bool>? until = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            try
            {
                var lines = File.ReadAllLines(path);
                if (until is null || until(lines))
                {
                    return lines;
                }
            }
            catch (FileNotFoundException)
            {
                // The first record has not landed yet.
            }
            catch (IOException)
            {
                // The writer is appending right now.
            }

            if (DateTime.UtcNow >= deadline)
            {
                return Array.Empty<string>();
            }

            Thread.Sleep(25);
        }
    }

    public static ProtocolResponse StatusResult(bool ok, JsonElement data, string message = "")        => new()
        {
            Type = "result",
            Ok = ok,
            Code = ok ? ErrorCode.None : ErrorCode.Protocol,
            Message = message,
            CurrentState = ok ? "installed" : "unknown",
            RestoredState = ok ? "notRequired" : "unchanged",
            NextStep = ok ? string.Empty : "Check the engine transcript.",
            Data = data,
        };

    public static EngineRunResult EngineRunResult(bool ok, ErrorCode code, string message, JsonElement? data = null)
        => new()
        {
            Ok = ok,
            Code = code,
            Message = message,
            CurrentState = ok ? "installed" : "unknown",
            RestoredState = ok ? "notRequired" : "dnsproxy-service kept running",
            NextStep = ok ? string.Empty : "Review the state before retrying.",
            Data = data,
        };

    public static BrokerResult BrokerResult(bool ok, ErrorCode code, string message)
        => new()
        {
            Ok = ok,
            Code = code,
            Message = message,
            CurrentState = ok ? "installed" : "unchanged",
            RestoredState = ok ? "notRequired" : "dnsproxy-service kept running",
            NextStep = ok ? string.Empty : "Retry after fixing the problem.",
        };

    /// <summary>Parses a JSON object literal; a malformed literal is a bug in the test itself.</summary>
    public static JsonElement Json(string literal)
        => JsonSerializer.Deserialize<JsonElement>(literal);

    public static string FixedNonce = "5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a";
}

/// <summary>
/// Engine stand-in (design 10): recorded calls, either a fixed result or a held TaskCompletionSource.
/// </summary>
public sealed class FakeEngineClient : IEngineClient
{
    private readonly TaskCompletionSource<EngineRunResult> _gate;
    private readonly EngineRunResult? _fixed;

    /// <summary>Null result = the run stays held on a TaskCompletionSource until Complete().</summary>
    public FakeEngineClient(EngineRunResult? fixedResult)
    {
        _fixed = fixedResult;
        _gate = new TaskCompletionSource<EngineRunResult>(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    /// <summary>Use when the run must be held mid-flight; release with Complete().</summary>
    public static FakeEngineClient Gated()
        => new(null);

    public List<(ProtocolAction Action, IReadOnlyDictionary<string, string> Args)> Calls { get; } = new();

    public List<string> ReportedPhases { get; } = new();

    public bool Completed { get; private set; }

    public void Complete(EngineRunResult result)
    {
        Completed = true;
        _gate.TrySetResult(result);
    }

    public Task<EngineRunResult> RunAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken)
    {
        Calls.Add((action, args));
        if (_fixed is { } fixedResult)
        {
            return Task.FromResult(fixedResult);
        }

        return _gate.Task;
    }
}

/// <summary>Broker stand-in (design 10): same shape as the engine fake for broker-routed runs.</summary>
public sealed class FakeBrokerCoordinator : IBrokerCoordinator
{
    private readonly TaskCompletionSource<BrokerResult> _gate;
    private readonly BrokerResult? _fixed;

    /// <summary>Null result = the invocation stays held on a TaskCompletionSource until Complete().</summary>
    public FakeBrokerCoordinator(BrokerResult? fixedResult)
    {
        _fixed = fixedResult;
        _gate = new TaskCompletionSource<BrokerResult>(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    public static FakeBrokerCoordinator Gated()
        => new(null);

    public List<(ProtocolAction Action, IReadOnlyDictionary<string, string> Args)> Calls { get; } = new();

    public event EventHandler? StateChanged
    {
        add { }
        remove { }
    }

    public string StatusBarKey => "Broker_Ready";

    public bool CanInvokeMutations => true;

    public string? DeclineReason => null;

    public void ResetDecline()
    {
    }

    public void Complete(BrokerResult result) => _gate.TrySetResult(result);

    public Task<BrokerResult> InvokeAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken)
    {
        Calls.Add((action, args));
        if (_fixed is { } fixedResult)
        {
            return Task.FromResult(fixedResult);
        }

        return _gate.Task;
    }
}
