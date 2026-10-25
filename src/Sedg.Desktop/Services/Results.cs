using System.Text.Json;
using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// Terminal outcome of one app-direct engine run (design §8.1 name). The library's
/// <c>Sedg.Protocol.EngineResult</c> is snapshot-only, so this app-level result carries the
/// terminal fields plus the raw payload (Task 2 review carry-over), the process exit code,
/// the stderr diagnostic tail, and the surfaced log path.
/// </summary>
public sealed class EngineRunResult
{
    public bool Ok { get; init; }

    public ErrorCode Code { get; init; }

    public string Message { get; init; } = string.Empty;

    public string CurrentState { get; init; } = string.Empty;

    public string RestoredState { get; init; } = string.Empty;

    public string NextStep { get; init; } = string.Empty;

    /// <summary>Raw result payload preserved as delivered (status snapshot, CDN test result, or operation data).</summary>
    public JsonElement? Data { get; init; }

    public int? ExitCode { get; init; }

    /// <summary>Verbatim engine stderr tail; diagnostics only, never parsed.</summary>
    public string? StderrTail { get; init; }

    /// <summary>Engine transcript path when the engine emitted one; otherwise null.</summary>
    public string? LogPath { get; init; }
}

/// <summary>Terminal outcome of one broker-routed request (design §8.1 name). Same terminal fields as <see cref="EngineRunResult"/>.</summary>
public sealed class BrokerResult
{
    public bool Ok { get; init; }

    public ErrorCode Code { get; init; }

    public string Message { get; init; } = string.Empty;

    public string CurrentState { get; init; } = string.Empty;

    public string RestoredState { get; init; } = string.Empty;

    public string NextStep { get; init; } = string.Empty;

    public JsonElement? Data { get; init; }

    public int? ExitCode { get; init; }

    /// <summary>The broker's stderr is never read (design §3.1); always null here.</summary>
    public string? StderrTail { get; init; }

    public string? LogPath { get; init; }

    /// <summary>True when the app stopped waiting while the broker may still be executing; the broker result arrives log-only.</summary>
    public bool Cancelled { get; init; }
}
