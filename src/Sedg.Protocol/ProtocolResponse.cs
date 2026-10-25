using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sedg.Protocol;

/// <summary>One JSONL line from the engine (or broker): hello, event, progress, or result.</summary>
public sealed class ProtocolResponse
{
    [JsonRequired]
    public string Type { get; init; } = string.Empty;

    // hello
    public int? ProtocolVersion { get; init; }

    public int? Pid { get; init; }

    public string? EngineVersion { get; init; }

    // event / progress
    public long? Seq { get; init; }

    public DateTimeOffset? TsUtc { get; init; }

    public string? Phase { get; init; }

    public string? Message { get; init; }

    public long? BytesTransferred { get; init; }

    public long? BytesTotal { get; init; }

    // result
    public bool? Ok { get; init; }

    public ErrorCode? Code { get; init; }

    public string? CurrentState { get; init; }

    public string? RestoredState { get; init; }

    public string? NextStep { get; init; }

    /// <summary>
    /// Result payload preserved as raw JSON because it can be a StatusSnapshot,
    /// a CDN test result, or operation data. Use <see cref="TryGetStatusSnapshot"/>
    /// when the payload is known to be a snapshot.
    /// </summary>
    public JsonElement? Data { get; init; }

    public string? TranscriptPath { get; init; }

    public bool TryGetStatusSnapshot([NotNullWhen(true)] out StatusSnapshot? snapshot)
    {
        snapshot = null;
        if (Data is not JsonElement data || data.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        try
        {
            snapshot = data.Deserialize<StatusSnapshot>(ProtocolJson.SerializerOptions);
        }
        catch (JsonException)
        {
            return false;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (NotSupportedException)
        {
            return false;
        }

        return snapshot is not null;
    }
}
