using System.Text.Json;
using Sedg.Protocol;

/// <summary>JSONL round-trips of every line type and the malformed-line path (Task 2 criterion 5).</summary>
public static class ProtocolJsonTests
{
    [Test]
    public static void HelloLineRoundTrips()
    {
        var line = ProtocolJson.Serialize(new ProtocolResponse { Type = "hello", ProtocolVersion = 1, Pid = 99, EngineVersion = "9.9.9" });
        Assert.True(ProtocolJson.TryDeserializeLine(line, out var parsed, out var error));
        Assert.Null(error);
        Assert.Equal("hello", parsed!.Type);
        Assert.Equal(1, parsed.ProtocolVersion!.Value);
        Assert.Equal(99, parsed.Pid!.Value);
        Assert.Equal("9.9.9", parsed.EngineVersion);
    }

    [Test]
    public static void EventLineRoundTrips()
    {
        var stamp = DateTimeOffset.Parse("2026-01-01T12:00:00Z", CultureInfo.InvariantCulture);
        var line = ProtocolJson.Serialize(new ProtocolResponse { Type = "event", Seq = 7, TsUtc = stamp, Phase = "stage", Message = "msg" });
        Assert.True(ProtocolJson.TryDeserializeLine(line, out var parsed, out var error));
        Assert.Null(error);
        Assert.Equal("event", parsed!.Type);
        Assert.Equal(7, parsed.Seq!.Value);
        Assert.Equal(stamp, parsed.TsUtc!.Value);
        Assert.Equal("stage", parsed.Phase);
        Assert.Equal("msg", parsed.Message);
    }

    [Test]
    public static void ProgressLineRoundTrips()
    {
        var stamp = DateTimeOffset.Parse("2026-01-01T12:00:01Z", CultureInfo.InvariantCulture);
        var line = ProtocolJson.Serialize(new ProtocolResponse
        {
            Type = "progress",
            Seq = 8,
            TsUtc = stamp,
            Phase = "install",
            Message = "bytes",
            BytesTransferred = 1024,
            BytesTotal = 2048,
        });
        Assert.True(ProtocolJson.TryDeserializeLine(line, out var parsed, out var error));
        Assert.Null(error);
        Assert.Equal("progress", parsed!.Type);
        Assert.Equal(1024, parsed.BytesTransferred!.Value);
        Assert.Equal(2048, parsed.BytesTotal!.Value);
    }

    [Test]
    public static void ResultLineRoundTrips()
    {
        var line = ProtocolJson.Serialize(new ProtocolResponse
        {
            Type = "result",
            Ok = false,
            Code = ErrorCode.BrokerNonce,
            Message = "bad",
            CurrentState = "installed",
            RestoredState = "unchanged",
            NextStep = "retry",
        });
        Assert.True(ProtocolJson.TryDeserializeLine(line, out var parsed, out var error));
        Assert.Null(error);
        Assert.False(parsed!.Ok!.Value);
        Assert.Equal(ErrorCode.BrokerNonce, parsed.Code!.Value);
        Assert.Equal("installed", parsed.CurrentState);
        Assert.Equal("unchanged", parsed.RestoredState);
        Assert.Equal("retry", parsed.NextStep);
    }

    [Test]
    public static void EmptyLineIsRejected()
    {
        Assert.False(ProtocolJson.TryDeserializeLine("", out var response, out var error));
        Assert.Null(response);
        Assert.NotNull(error);
        Assert.False(ProtocolJson.TryDeserializeLine("   ", out _, out _));
    }

    [Test]
    public static void MalformedJsonBecomesProtocolErrorResponse()
    {
        var degraded = ProtocolJson.DeserializeLine("{ nope");
        Assert.NotNull(degraded);
        Assert.False(degraded!.Ok!.Value);
        Assert.Equal(ErrorCode.Protocol, degraded.Code!.Value);
    }

    [Test]
    public static void UnknownLineTypeIsRejected()
    {
        var degraded = ProtocolJson.DeserializeLine("""{"type":"banana"}""");
        Assert.False(degraded!.Ok!.Value);
        Assert.True(degraded.Message!.Contains("banana", StringComparison.Ordinal));
    }

    [Test]
    public static void UnknownFieldsAreRejected()
    {
        var degraded = ProtocolJson.DeserializeLine(
            """{"type":"hello","protocolVersion":1,"engineVersion":"1","pid":5,"extra":1}""");
        Assert.False(degraded!.Ok!.Value);
        Assert.True(degraded.Message!.Contains("extra", StringComparison.Ordinal));
    }

    [Test]
    public static void HelloBomPrefixedLineIsRejected()
    {
        var degraded = ProtocolJson.DeserializeLine("\uFEFF" + """{"type":""}""");
        Assert.False(degraded!.Ok!.Value);
        Assert.Equal(ErrorCode.Protocol, degraded.Code!.Value);
    }

    [Test]
    public static void HelloLineRequiresPid()
    {
        var degraded = ProtocolJson.DeserializeLine("""{"type":"hello","protocolVersion":1,"engineVersion":"1"}""");
        Assert.False(degraded!.Ok!.Value);
        Assert.True(degraded.Message!.Contains("pid", StringComparison.Ordinal));
    }

    [Test]
    public static void NegativeProgressCountsRejected()
    {
        var degraded = ProtocolJson.DeserializeLine(
            """{"type":"progress","seq":1,"tsUtc":"2026-01-01T12:00:00Z","phase":"p","bytesTotal":-5}""");
        Assert.False(degraded!.Ok!.Value);
        Assert.True(degraded.Message!.Contains("negative", StringComparison.Ordinal));
    }

    [Test]
    public static void RawDataPreservesForeignPayload()
    {
        const string payload = """{"alpha":1,"beta":"remote-identity-value"}""";
        var response = new ProtocolResponse
        {
            Type = "result",
            Ok = true,
            Code = ErrorCode.None,
            Message = "ok",
            CurrentState = "installed",
            RestoredState = "notRequired",
            NextStep = "",
            Data = JsonDocument.Parse(payload).RootElement,
        };
        var line = ProtocolJson.Serialize(response);
        Assert.True(line.Contains("remote-identity-value", StringComparison.Ordinal));

        Assert.True(ProtocolJson.TryDeserializeLine(line, out var parsed, out _));
        Assert.Equal(payload, parsed!.Data!.Value.GetRawText());
    }

    [Test]
    public static void RequestUnknownFieldRejected()
    {
        var bad = """{"type":"request","protocolVersion":1,"action":"status","operationId":"6d2fd80a-1c47-4a1c-8a5a-6f8afdda7f96","junk":1}""";
        Assert.False(ProtocolJson.TryDeserializeRequest(bad, out var request, out var error));
        Assert.Null(request);
        Assert.NotNull(error);
    }

    [Test]
    public static void RequestRequiresRequestTypeAndSchema()
    {
        Assert.False(ProtocolJson.TryDeserializeRequest(
            """{"type":"response","protocolVersion":1,"action":"status"}""", out _, out var typeError));
        Assert.True(typeError!.Contains("request", StringComparison.Ordinal));

        Assert.False(ProtocolJson.TryDeserializeRequest(
            """{"type":"request","protocolVersion":9,"action":"status"}""", out _, out var versionError));
        Assert.True(versionError!.Contains("protocolVersion", StringComparison.Ordinal));

        Assert.False(ProtocolJson.TryDeserializeRequest(
            """{"type":"request","protocolVersion":1,"action":"setDns","args":{"servers":"nope"}}""", out _,
            out var schemaError));
        Assert.True(schemaError!.Contains("array", StringComparison.Ordinal));
    }
}
