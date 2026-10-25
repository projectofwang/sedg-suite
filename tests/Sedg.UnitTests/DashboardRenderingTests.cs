using Sedg.Desktop.Services;
using Sedg.Desktop.ViewModels;
using Sedg.Protocol;

/// <summary>
/// The dashboard renders exactly what the engine delivered: eight fixed fields, honest
/// unknown-with-reason, no locally computed readiness, and a busy-gated refresh path.
/// </summary>
public static class DashboardRenderingTests
{
    private sealed class Row
    {
        internal const string Install = "install";
        internal const string Services = "services";
        internal const string Watchdog = "watchdog";
        internal const string Dns = "dns";
        internal const string Upstream = "upstream";
        internal const string Versions = "versions";
        internal const string LastUpdate = "lastUpdate";
        internal const string Readiness = "readiness";
    }

    private record Harness(DashboardViewModel Vm, FakeEngineClient Engine, AppLog AppLog, LocalizationManager Localization, string TempDir) : IDisposable
    {
        public void Dispose() => Directory.Delete(TempDir, recursive: true);
    }

    private static Harness NewHarness(FakeEngineClient engine)
    {
        var tempDirectory = Support.NewTempDirectory();
        var localization = Support.NewLocalization(tempDirectory + "\\loc");
        var appLog = Support.NewAppLog(tempDirectory);
        return new Harness(new DashboardViewModel(engine, appLog, localization), engine, appLog, localization, tempDirectory);
    }

    [Test]
    public static void EightRowsRenderTheFixedFieldSet()
    {
        using var harness = NewHarness(FakeEngineClient.Gated());
        var keys = harness.Vm.Rows.Select(row => row.Key).ToArray();
        Assert.Equal(
            new[]
            {
                Row.Install, Row.Services, Row.Watchdog, Row.Dns,
                Row.Upstream, Row.Versions, Row.LastUpdate, Row.Readiness,
            },
            keys);
    }

    [Test]
    public static void KnownProbesRenderDeliveredValuesOnly()
    {
        using var harness = NewHarness(FakeEngineClient.Gated());
        harness.Vm.ApplySnapshot(Support.Json(statusSnapshotJson()));

        AssertRowKnown(harness.Vm, Row.Install, "installed", "C:/sedgwz");
        AssertRowKnown(harness.Vm, Row.Services, "dnsproxy (Running Automatic)");
        AssertRowKnown(harness.Vm, Row.Watchdog, "sedg-watchdog (enabled)");
        AssertRowKnown(harness.Vm, Row.Upstream, "edge.example.net (https custom)");
        AssertRowKnown(harness.Vm, Row.Readiness, "ready (gate1)");
        AssertRowKnown(harness.Vm, Row.LastUpdate, "2026-01-01T00:00:00Z");

        // A probe whose engine says "known" but ships no value stays muted with the stock reason.
        AssertRowUnknown(harness.Vm, Row.Dns, harness.Localization.GetString("Dash_Unknown"));
        // A missing probe is honest "unknown", never a guess.
        AssertRowUnknown(harness.Vm, Row.Versions, harness.Localization.GetString("Dash_SnapshotMissing"));
    }

    [Test]
    public static void UnknownProbesAreMutedAndReadinessIsNeverLocallyComputed()
    {
        using var harness = NewHarness(FakeEngineClient.Gated());
        harness.Vm.ApplySnapshot(Support.Json(
            """
            {
              "installPresence": {"state": "unknown", "reason": "the engine could not probe installation"},
              "services": {"state": "unknown", "reason": "the engine could not enumerate services"},
              "watchdog": {"state": "unknown", "reason": "the engine could not read the scheduled task"},
              "dnsPerAdapter": {"state": "unknown", "reason": "the engine could not read the adapters"},
              "upstream": {"state": "unknown", "reason": "the engine could not probe the upstream"},
              "versions": {"state": "unknown", "reason": "the engine could not read the manifests"},
              "lastUpdate": {"state": "unknown", "reason": "history is empty"},
              "readiness": {"state": "unknown", "reason": "gate blocked"}
            }
            """));

        foreach (var row in harness.Vm.Rows)
        {
            Assert.True(row.IsUnknown, row.Key + " must render unknown, not a guess");
            Assert.False(row.HasValue, row.Key + " must not carry a fabricated value");
            Assert.True(row.Reason.Length > 0, row.Key + " must carry the engine's reason");
        }

        AssertRowUnknown(harness.Vm, Row.Install, "the engine could not probe installation");
        AssertRowUnknown(harness.Vm, Row.Readiness, "gate blocked");
        Assert.False(
            harness.Vm.Rows.Single(x => x.Key == Row.Readiness).Value.Contains("ready", StringComparison.Ordinal),
            "readiness must stay muted");
    }

    [Test]
    public static void AFailedRefreshShowsTheBannerAndKeepsRowsUnknown()
    {
        using var harness = NewHarness(new FakeEngineClient(Support.EngineRunResult(
            ok: false,
            ErrorCode.Config,
            "The config file was not valid JSON.")));
        harness.Vm.RefreshAsync().GetAwaiter().GetResult();

        Assert.True(harness.Vm.HasError);
        Assert.Equal("The config file was not valid JSON.", harness.Vm.StatusText);
        Assert.False(harness.Vm.IsBusy);
        foreach (var row in harness.Vm.Rows)
        {
            Assert.True(row.IsUnknown, row.Key + " must stay unknown after a failed refresh");
        }

        var lines = File.ReadAllLines(harness.AppLog.OperationsLogPath);
        Assert.Equal(1, lines.Length);
        Assert.True(lines[0].Contains("\"action\":\"status\"", StringComparison.Ordinal), lines[0]);
    }

    [Test]
    public static void AOkRunWithNonObjectDataStaysSnapshotMissing()
    {
        var runResult = new EngineRunResult
        {
            Ok = true,
            Code = ErrorCode.None,
            Message = string.Empty,
            CurrentState = "installed",
            RestoredState = "notRequired",
            NextStep = string.Empty,
            Data = Support.Json("7"),
        };
        using var harness = NewHarness(new FakeEngineClient(runResult));

        harness.Vm.RefreshAsync().GetAwaiter().GetResult();

        Assert.True(harness.Vm.HasError);
        Assert.Equal(harness.Localization.GetString("Dash_SnapshotMissing"), harness.Vm.StatusText);
        var row = harness.Vm.Rows.Single(x => x.Key == Row.Versions);
        Assert.True(row.IsUnknown);
    }

    [Test]
    public static void BusyGatedRefreshDeliversTheStatusSnapshot()
    {
        using var harness = NewHarness(FakeEngineClient.Gated());
        var refresh = harness.Vm.RefreshAsync();
        Assert.True(harness.Vm.IsBusy);
        Assert.False(harness.Vm.RefreshCommand.CanExecute(null));

        harness.Engine.Complete(new EngineRunResult
        {
            Ok = true,
            Code = ErrorCode.None,
            Message = string.Empty,
            CurrentState = "installed",
            RestoredState = "notRequired",
            NextStep = string.Empty,
            Data = Support.Json(statusSnapshotJson()),
        });

        refresh.GetAwaiter().GetResult();
        Assert.False(harness.Vm.IsBusy);
        Assert.True(harness.Vm.RefreshCommand.CanExecute(null));
        Assert.False(harness.Vm.HasError);
        AssertRowKnown(harness.Vm, Row.Install, "installed", "C:/sedgwz");
    }

    private static string statusSnapshotJson() => """
        {
          "installPresence": {"state": "known", "value": {"installed": true, "installPath": "C:/sedgwz"}},
          "services": {"state": "known", "value": [{"name": "dnsproxy", "status": "Running", "startType": "Automatic"}]},
          "watchdog": {"state": "known", "value": {"taskName": "sedg-watchdog", "enabled": "true"}},
          "dnsPerAdapter": {"state": "known"},
          "upstream": {"state": "known", "value": {"host": "edge.example.net", "scheme": "https", "source": "custom"}},
          "readiness": {"state": "known", "value": {"state": "ready", "reasons": ["gate1"]}},
          "lastUpdate": {"state": "known", "value": {"utc": "2026-01-01T00:00:00Z"}}
        }
        """;

    private static void AssertRowKnown(DashboardViewModel viewModel, string key, params string[] tokens)
    {
        var row = viewModel.Rows.Single(x => x.Key == key);
        Assert.True(row.HasValue, key + " was expected to carry a value");
        Assert.False(row.IsUnknown, key + " was expected to be a known probe");
        foreach (var token in tokens)
        {
            Assert.True(
                row.Value.Contains(token, StringComparison.Ordinal),
                key + " value '" + row.Value + "' must contain '" + token + "'");
        }
    }

    private static void AssertRowUnknown(DashboardViewModel viewModel, string key, string reason)
    {
        var row = viewModel.Rows.Single(x => x.Key == key);
        Assert.True(row.IsUnknown, key + " was expected to be muted");
        Assert.Equal(reason, row.Reason);
        Assert.False(row.HasValue, key + " known-without-value must not fabricate");
    }
}
