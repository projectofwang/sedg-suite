using Sedg.Desktop.Services;
using Sedg.Desktop.ViewModels;
using Sedg.Protocol;

/// <summary>
/// The Input - Review - Progress - Result machine: engine and broker routes, the busy gate,
/// cancelled-is-never-success, CloseResult, retained form values, and the absence of any purge
/// control or blacklist editor on the visible surface.
/// </summary>
public static class StageMachineTests
{
    private sealed record Harness(
        OperationViewModel Vm,
        FakeEngineClient Engine,
        FakeBrokerCoordinator Broker,
        AppLog AppLog,
        LocalizationManager Localization,
        string TempDir) : IDisposable
    {
        public string OperationsPath => AppLog.OperationsLogPath;

        public void Dispose() => Directory.Delete(TempDir, recursive: true);
    }

    private static Harness NewHarness(FakeEngineClient engine, FakeBrokerCoordinator broker)
    {
        var tempDirectory = Support.NewTempDirectory();
        var localization = Support.NewLocalization(tempDirectory + "\\loc");
        var appLog = Support.NewAppLog(tempDirectory);
        var preflight = Support.AllGreenPreflight(localization);
        return new Harness(
            new OperationViewModel(engine, broker, preflight, new Validator(), appLog, localization),
            engine,
            broker,
            appLog,
            localization,
            tempDirectory);
    }

    private static void WaitUntil(Harness harness, Func<OperationViewModel, bool> condition)
        => Support.WaitUntil(() => condition(harness.Vm), 10_000);

    private static void Choose(Harness harness, OperationViewModel.Descriptor descriptor)
        => harness.Vm.Chosen = new OperationChoice(descriptor, descriptor.TitleKey);

    private static EngineRunResult Success()
        => Support.EngineRunResult(ok: true, ErrorCode.None, string.Empty);

    private static void RunToReview(Harness harness, OperationViewModel.Descriptor descriptor)
    {
        Choose(harness, descriptor);
        harness.Vm.ContinueCommand.Execute(null);
        WaitUntil(harness, vm => vm.IsReview);
    }

    [Test]
    public static void EngineRouteRunsInputThroughResult()
    {
        using var harness = NewHarness(new FakeEngineClient(Success()), FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;

        RunToReview(harness, new(
            ProtocolAction.Status, "Op_Action_Status", OperationViewModel.FormKind.None,
            Destructive: false, BrokerRouted: false));
        Assert.False(vm.ValidationTitle.Length > 0);
        Assert.False(vm.ContinueCommand.CanExecute(null), "review disables continue until back");

        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsOutcomeSuccess);
        Assert.False(vm.IsOutcomeFailed);
        Assert.Equal(string.Empty, vm.ResultCodeText);
        Assert.False(vm.HasCurrentState);
        Assert.True(vm.IsInput == false && vm.IsReview == false && vm.IsProgress == false);

        Assert.Equal(1, harness.Engine.Calls.Count);
        Assert.Equal(ProtocolAction.Status, harness.Engine.Calls[0].Action);

        var lines = File.ReadAllLines(harness.OperationsPath);
        Assert.Equal(1, lines.Length);
        Assert.True(lines[0].Contains("\"action\":\"status\"", StringComparison.Ordinal), lines[0]);
        Assert.True(lines[0].Contains("\"lateCompletion\":false", StringComparison.Ordinal), lines[0]);
    }

    [Test]
    public static void BrokerRouteRunsInstallThroughTheCoordinator()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), new FakeBrokerCoordinator(Support.BrokerResult(true, ErrorCode.None, string.Empty)));
        var vm = harness.Vm;
        RunToReview(harness, new(
            ProtocolAction.Install, "Op_Action_Install", OperationViewModel.FormKind.InstallMode,
            Destructive: true, BrokerRouted: true));
        Assert.True(vm.IsInstallModeForm);
        vm.InstallClean = true;
        Assert.True(vm.ReviewDestructive);
        Assert.False(vm.ReviewNoteVisible);

        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);
        Assert.True(vm.IsOutcomeSuccess);
        Assert.Equal(1, harness.Broker.Calls.Count);
        Assert.Equal(ProtocolAction.Install, harness.Broker.Calls[0].Action);
        Assert.True(harness.Broker.Calls[0].Args.ContainsKey("mode"), "install must map the mode argument");
        Assert.Equal("clean", harness.Broker.Calls[0].Args["mode"]);

        var lines = File.ReadAllLines(harness.OperationsPath);
        Assert.True(lines[0].Contains("\"action\":\"install\"", StringComparison.Ordinal), lines[0]);
    }

    [Test]
    public static void BusyGateDisablesNavigationUntilTheTerminal()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;

        RunToReview(harness, new(
            ProtocolAction.Status, "Op_Action_Status", OperationViewModel.FormKind.None,
            Destructive: false, BrokerRouted: false));
        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsProgress);
        Assert.True(vm.IsBusy);

        // Mid-run there is nothing to confirm and no input to continue from.
        Assert.False(vm.ContinueCommand.CanExecute(null));
        Assert.False(vm.ConfirmCommand.CanExecute(null));
        Assert.True(vm.ClosingBlocked);

        harness.Engine.Complete(Success());
        WaitUntil(harness, x => x.IsResult);
        Assert.False(vm.IsBusy);
        Assert.False(vm.ClosingBlocked);

        vm.CloseResultCommand.Execute(null);
        WaitUntil(harness, x => x.IsInput);
        Assert.True(vm.ContinueCommand.CanExecute(null));
        Assert.False(vm.IsOutcomeSuccess);
    }

    [Test]
    public static void AppCancelledEngineRunLogsTheLateCompletion()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;

        RunToReview(harness, new(
            ProtocolAction.Status, "Op_Action_Status", OperationViewModel.FormKind.None,
            Destructive: false, BrokerRouted: false));
        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsProgress);

        Assert.True(vm.CancelRunCommand.CanExecute(null));
        vm.CancelRunCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);
        Assert.True(vm.IsOutcomeCancelled);
        Assert.False(vm.IsOutcomeSuccess);
        Assert.False(vm.IsOutcomeFailed);
        Assert.True(vm.ClosingBlocked, "the child is still running after an app-side cancel");

        var afterCancel = Support.ReadOperationLines(harness.OperationsPath);
        Assert.Equal(1, afterCancel.Length);
        Assert.True(afterCancel[0].Contains("\"code\":\"Cancelled\"", StringComparison.Ordinal), afterCancel[0]);
        Assert.True(afterCancel[0].Contains("\"lateCompletion\":false", StringComparison.Ordinal), afterCancel[0]);

        // The child keeps running: when it finally reports, the same record logs the true terminal.
        harness.Engine.Complete(Success());
        var lines = Support.ReadOperationLines(harness.OperationsPath, x => x.Length == 2);
        Assert.Equal(2, lines.Length);
        Assert.True(lines[1].Contains("\"lateCompletion\":true", StringComparison.Ordinal), lines[1]);
        Assert.True(lines[1].Contains("\"ok\":true", StringComparison.Ordinal), lines[1]);
        Assert.False(vm.ClosingBlocked);
    }

    [Test]
    public static void BrokerCancelledResultNeverRendersAsSuccess()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), FakeBrokerCoordinator.Gated());
        harness.Broker.Complete(new BrokerResult
        {
            Ok = false,
            Code = ErrorCode.Cancelled,
            Message = "stopped",
            CurrentState = "unchanged",
            RestoredState = "notRequired",
            NextStep = "retry",
            Cancelled = true,
        });

        var vm = harness.Vm;
        RunToReview(harness, new(
            ProtocolAction.Install, "Op_Action_Install", OperationViewModel.FormKind.InstallMode,
            Destructive: true, BrokerRouted: true));
        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);

        Assert.True(vm.IsOutcomeCancelled);
        Assert.False(vm.IsOutcomeSuccess);
        Assert.False(vm.IsOutcomeFailed);
        Assert.Equal(string.Empty, vm.ResultCodeText);

        // The coordinator records its own cancelled terminal in operations.jsonl (plan 5.3); the fake
        // coordinator is silent by design, so the VM surface is all this case asserts.
    }

    [Test]
    public static void FailureRenderingCarriesCodeStateRestoreAndNextStep()
    {
        using var harness = NewHarness(
            new FakeEngineClient(Support.EngineRunResult(
                ok: false, ErrorCode.EngineSpawn, "the engine transcript is not there")),
            FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;

        RunToReview(harness, new(
            ProtocolAction.Status, "Op_Action_Status", OperationViewModel.FormKind.None,
            Destructive: false, BrokerRouted: false));
        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);

        Assert.True(vm.IsOutcomeFailed);
        Assert.False(vm.IsOutcomeSuccess);
        Assert.Equal(harness.Localization.GetString("Error_EngineSpawn"), vm.ResultTitle);
        Assert.Equal("EngineSpawn", vm.ResultCodeText);
        Assert.Equal("the engine transcript is not there", vm.ResultMessage);
        Assert.True(vm.HasCurrentState);
        Assert.Equal("unknown", vm.CurrentStateValue);
        Assert.True(vm.HasRestoredState);
        Assert.Equal("dnsproxy-service kept running", vm.RestoredStateValue);
        Assert.True(vm.HasNextStep);
        Assert.Equal("Review the state before retrying.", vm.NextStepValue);
        Assert.True(vm.IsIncompleteVisible, "a restore hint on failure must show the incomplete note");
        Assert.False(vm.HasLogPath);

        var lines = File.ReadAllLines(harness.OperationsPath);
        Assert.True(lines[0].Contains("\"code\":\"EngineSpawn\"", StringComparison.Ordinal), lines[0]);
        Assert.True(lines[0].Contains("\"ok\":false", StringComparison.Ordinal), lines[0]);
    }

    [Test]
    public static void FailedValidationRetainsTheEnteredValues()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;
        Choose(harness, new(
            ProtocolAction.SetUpstream, "Op_Action_SetUpstream", OperationViewModel.FormKind.Upstream,
            Destructive: true, BrokerRouted: true));
        Assert.True(vm.IsUpstreamForm);
        vm.UpstreamCustom = true;
        vm.UpstreamUrl = "https://";

        vm.ContinueCommand.Execute(null);
        Assert.True(vm.IsInput);
        Assert.True(vm.ValidationTitle.Length > 0, "the field failure must surface a validation title");
        Assert.True(vm.UpstreamUrlError.Length > 0, "the upstream field must show its own error");
        Assert.Equal("https://", vm.UpstreamUrl);
        Assert.True(vm.UpstreamCustom, "entered values are retained on failure");

        vm.UpstreamUrl = "https://upstream.example.net";
        vm.ContinueCommand.Execute(null);
        WaitUntil(harness, x => x.IsReview);
    }

    [Test]
    public static void TheLanguageChoiceCarriesItsArgument()
    {
        using var harness = NewHarness(new FakeEngineClient(Success()), FakeBrokerCoordinator.Gated());
        var vm = harness.Vm;
        Choose(harness, new(
            ProtocolAction.SetLanguage, "Op_Action_SetLanguage", OperationViewModel.FormKind.Language,
            Destructive: false, BrokerRouted: false));
        Assert.True(vm.IsLanguageForm);
        vm.LanguageVi = true;

        vm.ContinueCommand.Execute(null);
        WaitUntil(harness, x => x.IsReview);
        vm.ConfirmCommand.Execute(null);
        WaitUntil(harness, x => x.IsResult);

        Assert.Equal("vi", harness.Engine.Calls[0].Args["language"]);
    }

    [Test]
    public static void NoPurgeControlOrBlacklistEditorOnTheSurface()
    {
        using var harness = NewHarness(FakeEngineClient.Gated(), FakeBrokerCoordinator.Gated());
        var actions = harness.Vm.Choices.Select(choice => choice.Descriptor.Action).ToArray();
        Assert.Equal(11, actions.Length);
        Assert.False(actions.Contains(ProtocolAction.Purge));
        Assert.False(actions.Contains(ProtocolAction.RestoreEngine));
        foreach (var choice in harness.Vm.Choices)
        {
            var title = choice.Descriptor.TitleKey.ToUpperInvariant();
            Assert.False(title.Contains("PURGE", StringComparison.Ordinal), title);
            Assert.False(title.Contains("BLACKLIST", StringComparison.Ordinal), title);
        }
    }
}
