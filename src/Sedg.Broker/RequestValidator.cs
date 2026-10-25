using System.Text.Json.Nodes;
using Sedg.Protocol;

namespace Sedg.Broker;

/// <summary>Allow-list + schema validation; broker re-serializes its own request (never app bytes).</summary>
public sealed class RequestValidator
{
    public static readonly IReadOnlySet<ProtocolAction> AllowList = new HashSet<ProtocolAction>
    {
        ProtocolAction.Status,
        ProtocolAction.Install,
        ProtocolAction.Update,
        ProtocolAction.Pause,
        ProtocolAction.Resume,
        ProtocolAction.Restart,
        ProtocolAction.Uninstall,
        ProtocolAction.Purge,
        ProtocolAction.SetUpstream,
        ProtocolAction.SetDns,
        ProtocolAction.RestoreEngine,
    };

    private readonly string? _expectedNonce;
    private readonly NonceValidator _nonces = new();

    public RequestValidator(string? expectedNonce = null) => _expectedNonce = expectedNonce;

    public bool Validate(ProtocolRequest request, out ProtocolRequest? sanitized, out string? error)
        => Validate(request, out sanitized, out _, out error);

    public bool Validate(
        ProtocolRequest request,
        out ProtocolRequest? sanitized,
        out ErrorCode code,
        out string? error)
    {
        sanitized = null;
        code = ErrorCode.BrokerSchema;

        if (request is null)
        {
            error = "The request is absent.";
            return false;
        }

        if (!string.Equals(request.Type, "request", StringComparison.Ordinal))
        {
            error = "A broker request must have type 'request'.";
            return false;
        }

        if (request.ProtocolVersion != ProtocolJson.CurrentProtocolVersion)
        {
            error = "Unsupported protocolVersion " + request.ProtocolVersion + ".";
            return false;
        }

        if (!AllowList.Contains(request.Action))
        {
            error = "Action '" + request.Action + "' is not allowed by the broker.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(request.OperationId)
            || !Guid.TryParse(request.OperationId, out var operationId)
            || operationId == Guid.Empty)
        {
            error = "The operationId must be a non-empty GUID.";
            return false;
        }

        if (!ArgumentSchemas.Validate(request.Action, request.Args, out var schemaError))
        {
            error = schemaError ?? "The request arguments are invalid.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(request.Nonce)
            || request.IssuedUtc is null
            || request.ExpiresUtc is null)
        {
            code = ErrorCode.BrokerNonce;
            error = "Every broker request must carry nonce, issuedUtc, and expiresUtc.";
            return false;
        }

        if (!_nonces.IsValid(request.Nonce, request.IssuedUtc.Value, request.ExpiresUtc.Value, out var nonceError))
        {
            code = ErrorCode.BrokerNonce;
            error = nonceError;
            return false;
        }

        if (_expectedNonce is not null && !NonceValidator.NonceEquals(_expectedNonce, request.Nonce))
        {
            code = ErrorCode.BrokerNonce;
            error = "The request nonce does not match the handshake nonce.";
            return false;
        }

        var args = request.Args?.DeepClone() as JsonObject;
        if (args is null)
        {
            error = "args must be a JSON object.";
            return false;
        }

        sanitized = new ProtocolRequest
        {
            Type = "request",
            ProtocolVersion = ProtocolJson.CurrentProtocolVersion,
            Action = request.Action,
            OperationId = operationId.ToString("D"),
            Args = args,
        };

        code = ErrorCode.None;
        error = null;
        return true;
    }
}
