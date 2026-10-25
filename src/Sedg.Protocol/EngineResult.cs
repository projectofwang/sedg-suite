namespace Sedg.Protocol;

/// <summary>Terminal result line of a one-shot engine run (ok=false exits 1; see design.md §3.2).</summary>
public sealed class EngineResult
{
    public bool Ok { get; init; }

    public ErrorCode Code { get; init; }

    public string Message { get; init; } = string.Empty;

    public string CurrentState { get; init; } = string.Empty;

    public string RestoredState { get; init; } = string.Empty;

    public string NextStep { get; init; } = string.Empty;

    public string? TranscriptPath { get; init; }

    public StatusSnapshot? Data { get; init; }
}
