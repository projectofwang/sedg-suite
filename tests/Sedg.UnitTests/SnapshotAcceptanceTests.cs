using System.Text.Json;
using Sedg.Protocol;
using Sedg.UnitTests;

/// <summary>A Status result accepts an object payload only; non-object Data stays raw (Task 2 criterion 6).</summary>
public static class SnapshotAcceptanceTests
{
    private static ProtocolResponse Result(JsonElement data)
        => new()
        {
            Type = "result",
            Ok = true,
            Code = ErrorCode.None,
            Message = "ok",
            CurrentState = "installed",
            RestoredState = "notRequired",
            NextStep = string.Empty,
            Data = data,
        };

    [Test]
    public static void ObjectPayloadParsesIntoSnapshot()
    {
        var snapshot = """
            {
              "installPresence": {"state":"known","value":{"installed":true,"installPath":"C:\\gateway"}},
              "services": {"state":"known","value":[{"name":"dnsproxy-service","status":"Running","startType":"Automatic"}]},
              "watchdog": {"state":"known","value":{"taskName":"SEDG-DNS-Watchdog","enabled":true,"failClosed":true}},
              "dnsPerAdapter": {"state":"notApplicable"},
              "upstream": {"state":"known","value":{"host":"dns.example.com","scheme":"https","source":"manifest"}},
              "versions": {"state":"known","value":[{"component":"installer","approved":"2.5.0","installed":"2.5.0","match":"ok"}]},
              "lastUpdate": {"state":"known","value":{"utc":"2026-01-01T00:00:00Z","outcome":"install","reportedBy":"installer"}},
              "readiness": {"state":"known","value":{"state":"ready","reasons":[]}},
              "phases": [],
              "observedUtc": "2026-01-01T12:00:00Z"
            }
            """;
        var response = Result(JsonDocument.Parse(snapshot).RootElement);
        Assert.True(response.TryGetStatusSnapshot(out var parsed));
        Assert.Equal(ProbeState.Known, parsed!.InstallPresence.State);
        Assert.Equal("gateway", parsed.InstallPresence.Value!.InstallPath.Split('\\')[^1]);
        Assert.Equal(ProbeState.NotApplicable, parsed.DnsPerAdapter.State);
        Assert.Equal("ready", parsed.Readiness.Value!.State);
        Assert.Equal(1, parsed.Services.Value!.Length);
        Assert.Equal("dnsproxy-service", parsed.Services.Value![0].Name);
        Assert.True(parsed.Services.Value![0].Status == "Running");
    }

    [Test]
    public static void StringPayloadStaysRawAndSnapshotIsRejected()
    {
        var response = Result(JsonDocument.Parse("""{"Data":"not a snapshot"}""").RootElement.GetProperty("Data"));
        Assert.False(response.TryGetStatusSnapshot(out _));
        Assert.Equal("not a snapshot", response.Data!.Value.GetString());
    }

    [Test]
    public static void NumberAndArrayPayloadsStayRaw()
    {
        var number = Result(JsonDocument.Parse("42").RootElement);
        Assert.False(number.TryGetStatusSnapshot(out _));
        Assert.Equal(42, number.Data!.Value.GetInt32());

        var array = Result(JsonDocument.Parse("[1,2]").RootElement);
        Assert.False(array.TryGetStatusSnapshot(out _));
        Assert.Equal(2, array.Data!.Value.GetArrayLength());
    }

    [Test]
    public static void MissingOrCorruptSnapshotIsRejectedWithoutLosingData()
    {
        var literal = """{"state":"known","missing":"value"}""";
        var response = Result(JsonDocument.Parse(literal).RootElement);
        Assert.False(response.TryGetStatusSnapshot(out _));
        Assert.Equal(JsonValueKind.Object, response.Data!.Value.ValueKind);
    }

    [Test]
    public static void UnknownProbeReasonIsCarried()
    {
        var literal = """{"readiness":{"state":"unknown","reason":"Engine did not report"}}""";
        var response = Result(JsonDocument.Parse(literal).RootElement);
        Assert.True(response.TryGetStatusSnapshot(out var parsed));
        Assert.Equal(ProbeState.Unknown, parsed!.Readiness.State);
        Assert.Equal("Engine did not report", parsed.Readiness.Reason);
    }
}
