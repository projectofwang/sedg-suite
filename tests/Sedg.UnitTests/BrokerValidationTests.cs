using System.Text.Json.Nodes;
using Sedg.Broker;
using Sedg.Protocol;

/// <summary>The broker allow-list is exactly the approved set; outside actions are rejected before execution.</summary>
public static class BrokerValidationTests
{
    private static readonly ProtocolAction[] ExpectedAllowList =
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

    [Test]
    public static void AllowListIsExactlyTheApprovedSet()
    {
        Assert.Equal(ExpectedAllowList.Length, RequestValidator.AllowList.Count);
        foreach (var action in ExpectedAllowList)
        {
            Assert.True(RequestValidator.AllowList.Contains(action));
        }

        Assert.False(RequestValidator.AllowList.Contains(ProtocolAction.SetLanguage));
        Assert.False(RequestValidator.AllowList.Contains(ProtocolAction.TestCdnOptimization));
    }

    [Test]
    public static void LanguageAndCdnActionsAreRejectedBeforeExecution()
    {
        foreach (var action in new[] { ProtocolAction.SetLanguage, ProtocolAction.TestCdnOptimization })
        {
            var validator = new RequestValidator();
            var request = NewRequest(action);
            Assert.True(!validator.Validate(request, out var sanitized, out var code, out var error));
            Assert.Null(sanitized);
            Assert.Equal(ErrorCode.BrokerSchema, code);
            Assert.True(error!.Contains("not allowed", StringComparison.Ordinal));
        }
    }

    [Test]
    public static void RequestShapeIsEnforced()
    {
        var validator = new RequestValidator();
        var wrongType = new ProtocolRequest
        {
            Type = "response",
            Action = ProtocolAction.Status,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new JsonObject(),
        };
        Assert.True(!validator.Validate(wrongType, out _, out var codeA, out var errorA));
        Assert.Equal(ErrorCode.BrokerSchema, codeA);
        Assert.True(errorA!.Contains("type 'request'", StringComparison.Ordinal));

        var wrongVersion = new ProtocolRequest
        {
            ProtocolVersion = 2,
            Action = ProtocolAction.Status,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new JsonObject(),
        };
        Assert.True(!validator.Validate(wrongVersion, out _, out var codeB, out _));
        Assert.Equal(ErrorCode.BrokerSchema, codeB);
    }

    [Test]
    public static void OperationIdMustBeANonEmptyGuid()
    {
        var validator = new RequestValidator();
        foreach (var operationId in new[] { string.Empty, "  ", "junk", Guid.Empty.ToString("D") })
        {
            var request = new ProtocolRequest
            {
                Action = ProtocolAction.Status,
                OperationId = operationId,
                Args = new JsonObject(),
            };
            Assert.True(!validator.Validate(request, out var sanitized, out var code, out var error));
            Assert.Null(sanitized);
            Assert.Equal(ErrorCode.BrokerSchema, code);
            Assert.True(error!.Contains("operationId", StringComparison.Ordinal));
        }
    }

    [Test]
    public static void NullArgsAreRejectedWithSchemaCode()
    {
        var validator = new RequestValidator();
        var request = new ProtocolRequest
        {
            Action = ProtocolAction.Status,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = null,
        };
        Assert.True(!validator.Validate(request, out _, out var code, out var error));
        Assert.Equal(ErrorCode.BrokerSchema, code);
        Assert.True(error!.Contains("object", StringComparison.Ordinal));
    }

    [Test]
    public static void MissingNonceStampFieldsGetServerCode()
    {
        var validator = new RequestValidator();
        var missingNonce = new ProtocolRequest
        {
            Action = ProtocolAction.Status,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new JsonObject(),
        };
        Assert.True(!validator.Validate(missingNonce, out _, out var code, out var error));
        Assert.Equal(ErrorCode.BrokerNonce, code);
        Assert.True(error!.Contains("nonce", StringComparison.Ordinal));
    }

    [Test]
    public static void HandshakeNonceMustMatchButFixedTimeEqualsAcceptsAlternates()
    {
        var serverNonce = Support.FixedNonce;
        var validator = new RequestValidator(serverNonce);

        var matching = NewValidStampedRequest(serverNonce);
        Assert.True(validator.Validate(matching, out _, out _, out _));

        var mismatched = NewValidStampedRequest("cccc6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a");
        Assert.True(!validator.Validate(mismatched, out _, out var code, out var error));
        Assert.Equal(ErrorCode.BrokerNonce, code);
        Assert.True(error!.Contains("handshake", StringComparison.Ordinal));
    }

    [Test]
    public static void ReSerializationNeverForwardsAppBytes()
    {
        var serverNonce = Support.FixedNonce;
        var validator = new RequestValidator(serverNonce);

        // Unknown fields cannot survive the schema wall: the broker never sees app bytes carrying them.
        var drift = new ProtocolRequest
        {
            Action = ProtocolAction.Install,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new JsonObject { ["mode"] = JsonValue.Create("clean") },
            Nonce = serverNonce,
            IssuedUtc = DateTimeOffset.UtcNow,
            ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(60),
        };
        drift.Args!.Add("extra", JsonValue.Create(1));
        Assert.True(!validator.Validate(drift, out var unrecognized, out var code, out var error));
        Assert.Null(unrecognized);
        Assert.Equal(ErrorCode.BrokerSchema, code);
        Assert.True(error!.Contains("extra", StringComparison.Ordinal));

        var request = new ProtocolRequest
        {
            Action = ProtocolAction.Install,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new JsonObject { ["mode"] = JsonValue.Create("clean") },
            Nonce = serverNonce,
            IssuedUtc = DateTimeOffset.UtcNow,
            ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(60),
        };
        Assert.True(validator.Validate(request, out var sanitized, out _, out _));
        Assert.NotNull(sanitized);
        Assert.Equal("request", sanitized!.Type);
        Assert.Equal(ProtocolJson.CurrentProtocolVersion, sanitized.ProtocolVersion);
        Assert.Equal(ProtocolAction.Install, sanitized.Action);
        Assert.Equal(new Guid(request.OperationId).ToString("D"), sanitized.OperationId);
        Assert.Null(sanitized.Nonce);
        Assert.Null(sanitized.IssuedUtc);
        Assert.Null(sanitized.ExpiresUtc);
        Assert.Equal("""{"mode":"clean"}""", sanitized.Args!.ToJsonString());
    }

    [Test]
    public static void SanitizedArgsAreAClone()
    {
        var serverNonce = Support.FixedNonce;
        var validator = new RequestValidator(serverNonce);
        var args = new JsonObject { ["mode"] = JsonValue.Create("clean") };
        var request = new ProtocolRequest
        {
            Action = ProtocolAction.Install,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = args,
            Nonce = serverNonce,
            IssuedUtc = DateTimeOffset.UtcNow,
            ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(60),
        };
        Assert.True(validator.Validate(request, out var sanitized, out _, out _));
        args!["mode"] = JsonValue.Create((string?)"tampered");
        Assert.Equal("clean", sanitized!.Args!["mode"]!.GetValue<string>());
    }

    [Test]
    public static void UnknownFieldsAreDroppedAtTheWireLayer()
    {
        var line = """{"type":"request","protocolVersion":1,"action":"install","operationId":"6d2fd80a-1c47-4a1c-8a5a-6f8afdda7f96","args":{"mode":"clean"},"junkAttribution":true}""";
        Assert.False(ProtocolJson.TryDeserializeRequest(line, out var request, out var error));
        Assert.Null(request);
        Assert.True(error!.Contains("junkAttribution", StringComparison.Ordinal));
    }

    private static ProtocolRequest NewRequest(ProtocolAction action) => new()
    {
        Action = action,
        OperationId = Guid.NewGuid().ToString("D"),
        Args = new JsonObject(),
    };

    private static ProtocolRequest NewValidStampedRequest(string nonce) => new()
    {
        Action = ProtocolAction.Status,
        OperationId = Guid.NewGuid().ToString("D"),
        Args = new JsonObject(),
        Nonce = nonce,
        IssuedUtc = DateTimeOffset.UtcNow,
        ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(60),
    };
}
