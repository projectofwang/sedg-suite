using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Sedg.Protocol;

/// <summary>Single JSON request line sent to the engine, or app-to-broker envelope.</summary>
public sealed class ProtocolRequest
{
    [JsonRequired]
    public string Type { get; init; } = "request";

    [JsonRequired]
    public int ProtocolVersion { get; init; } = ProtocolJson.CurrentProtocolVersion;

    [JsonRequired]
    public ProtocolAction Action { get; init; }

    public string OperationId { get; init; } = string.Empty;

    public JsonObject? Args { get; init; } = new();

    public string? Nonce { get; init; }

    public DateTimeOffset? IssuedUtc { get; init; }

    public DateTimeOffset? ExpiresUtc { get; init; }
}
