using System.Collections.ObjectModel;
using System.Threading;
using System.Windows.Input;
using Sedg.Desktop.Services;
using Sedg.Protocol;

namespace Sedg.Desktop.ViewModels;

/// <summary>
/// One operation on the design §5.2 machine: `Input → Review → Progress → Result`, terminal exactly
/// one of `Success`, `Failed(code)`, `Cancelled`, and `Cancelled` is never rendered as success
/// (REQ-005). App-side cancel only stops waiting (§5.3): a one-shot run keeps being awaited so its
/// true terminal lands in operations.jsonl as a late completion of the same record; a broker request
/// frees its slot on the true arrival and the coordinator records that arrival itself.
/// Field validation runs at `Input → Review` and retains the entered values on failure.
/// </summary>
public sealed class OperationViewModel : ObservableObject
{
    internal enum FormKind
    {
        None,
        InstallMode,
        Upstream,
        DnsServers,
        Language,
    }

    internal sealed record Descriptor(
        ProtocolAction Action,
        string TitleKey,
        FormKind Form,
        bool Destructive,
        bool BrokerRouted);

    internal enum Stage
    {
        Input,
        Review,
        Progress,
        Result,
    }

    private static readonly Descriptor[] Descriptors =
    {
        new(ProtocolAction.Status, "Op_Action_Status", FormKind.None, false, false),
        new(ProtocolAction.Install, "Op_Action_Install", FormKind.InstallMode, true, true),
        new(ProtocolAction.Update, "Op_Action_Update", FormKind.None, true, true),
        new(ProtocolAction.Pause, "Op_Action_Pause", FormKind.None, false, true),
        new(ProtocolAction.Resume, "Op_Action_Resume", FormKind.None, false, true),
        new(ProtocolAction.Restart, "Op_Action_Restart", FormKind.None, true, true),
        new(ProtocolAction.Uninstall, "Op_Action_Uninstall", FormKind.None, true, true),
        new(ProtocolAction.SetUpstream, "Op_Action_SetUpstream", FormKind.Upstream, true, true),
        new(ProtocolAction.SetDns, "Op_Action_SetDns", FormKind.DnsServers, true, true),
        new(ProtocolAction.SetLanguage, "Op_Action_SetLanguage", FormKind.Language, false, false),
        new(ProtocolAction.TestCdnOptimization, "Op_Action_TestCdnOptimization", FormKind.None, false, false),
    };

    /// <summary>Static per-plan Review scope: install path, both services, the watchdog, the DNS change.</summary>
    private static readonly string[] ScopeKeys =
    {
        "Review_Scope_InstallPath",
        "Review_Scope_Services",
        "Review_Scope_Watchdog",
        "Review_Scope_Dns",
    };

    private const int MaxPhaseLines = 200;

    private readonly IEngineClient _engine;
    private readonly IBrokerCoordinator _broker;
    private readonly Preflight _preflight;
    private readonly Validator _validator;
    private readonly AppLog _appLog;
    private readonly LocalizationManager _localization;

    private Stage _stage = Stage.Input;
    private Descriptor _descriptor = Descriptors[0];
    private OperationChoice _chosen = null!;
    private bool _isBusy;
    private string _stageText = string.Empty;
    private string _validationTitle = string.Empty;

    // Form state is retained verbatim across a failed validation (criterion 4).
    private bool _installClean;
    private bool _upstreamCustom;
    private string _upstreamUrl = string.Empty;
    private string _upstreamUrlError = string.Empty;
    private string _dnsServers = string.Empty;
    private string _dnsServersError = string.Empty;
    private bool _languageEn = true;

    // Terminal fields; values empty ⇒ the row is hidden (no fabrication, §6.1).
    private string _outcome = string.Empty;
    private string _resultTitle = string.Empty;
    private string _resultMessage = string.Empty;
    private string _resultCodeText = string.Empty;
    private string _currentState = string.Empty;
    private string _restoredState = string.Empty;
    private string _nextStep = string.Empty;
    private string _logPath = string.Empty;
    private bool _hasCurrentState;
    private bool _hasRestoredState;
    private bool _hasNextStep;
    private bool _hasLogPath;
    private bool _incompleteVisible;
    private bool _copiedNote;
    private string _currentPhase = string.Empty;

    private string _operationId = string.Empty;
    private DateTimeOffset _startedUtc;
    private CancellationTokenSource? _cts;
    private bool _cancelled;
    private bool _sessionActive;
    private ErrorCode? _lastErrorCode;

    // Localized static labels (retranslated on language switch).
    private string _chooseActionLabel = string.Empty;
    private string _continueLabel = string.Empty;
    private string _backLabel = string.Empty;
    private string _confirmLabel = string.Empty;
    private string _cancelLabel = string.Empty;
    private string _closeLabel = string.Empty;
    private string _reviewScopeLabel = string.Empty;
    private string _reviewNoteLabel = string.Empty;
    private string _installModeLabel = string.Empty;
    private string _installModeCleanLabel = string.Empty;
    private string _upstreamKindLabel = string.Empty;
    private string _upstreamDefaultsLabel = string.Empty;
    private string _upstreamCustomLabel = string.Empty;
    private string _upstreamUrlLabel = string.Empty;
    private string _dnsServersLabel = string.Empty;
    private string _languageEnLabel = string.Empty;
    private string _languageViLabel = string.Empty;
    private string _openLogLabel = string.Empty;
    private string _copyLabel = string.Empty;
    private string _copiedNoteLabel = string.Empty;
    private string _incompleteNoteLabel = string.Empty;
    private string _codeLabel = string.Empty;
    private string _stateLabel = string.Empty;
    private string _restoredLabel = string.Empty;
    private string _nextStepLabel = string.Empty;
    private string _logPathLabel = string.Empty;

    /// <summary>Raised when a terminal is recorded so the shell can auto-refresh the dashboard.</summary>
    public event EventHandler? OperationEnded;

    public OperationViewModel(
        IEngineClient engine,
        IBrokerCoordinator broker,
        Preflight preflight,
        Validator validator,
        AppLog appLog,
        LocalizationManager localization)
    {
        _engine = engine;
        _broker = broker;
        _preflight = preflight;
        _validator = validator;
        _appLog = appLog;
        _localization = localization;

        foreach (var descriptor in Descriptors)
        {
            Choices.Add(new OperationChoice(descriptor, _localization.GetString(descriptor.TitleKey)));
        }

        _chosen = Choices[0];
        foreach (var scopeKey in ScopeKeys)
        {
            Scope.Add(_localization.GetString(scopeKey));
        }

        RetranslateLabels();

        _stageText = _localization.GetString("Op_Stage_Input");

        BackCommand = new RelayCommand(_ => LeaveReview(), _ => _stage == Stage.Review);
        ContinueCommand = new RelayCommand(_ => _ = EnterReviewAsync(), _ => _stage == Stage.Input && !_isBusy);
        ConfirmCommand = new RelayCommand(_ => StartRun(), _ => _stage == Stage.Review);
        CancelRunCommand = new RelayCommand(_ => CancelWaiting(), _ => _stage == Stage.Progress && !_cancelled);
        CloseResultCommand = new RelayCommand(_ => CloseResult(), _ => _stage == Stage.Result);
        OpenLogCommand = new RelayCommand(_ => _appLog.OpenInExplorer(_logPath), _ => _hasLogPath);
        CopyDetailsCommand = new RelayCommand(_ => CopyDetails(), _ => _stage == Stage.Result);
    }

    /// <summary>Localized action names (retranslated on language switch).</summary>
    public ObservableCollection<OperationChoice> Choices { get; } = new();

    /// <summary>The engine's phase/event lines, capped for an honest tail.</summary>
    public ObservableCollection<string> Phases { get; } = new();

    public ObservableCollection<string> Scope { get; } = new();

    public ObservableCollection<string> PreflightBlockers { get; } = new();

    public OperationChoice Chosen
    {
        get => _chosen;
        set
        {
            if (SetProperty(ref _chosen, value) && value is not null)
            {
                _descriptor = value.Descriptor;
                UpdateFormVisibility();
            }
        }
    }

    public string StageText { get => _stageText; private set => SetProperty(ref _stageText, value); }

    public bool IsBusy { get => _isBusy; private set => SetProperty(ref _isBusy, value); }

    public bool IsInput { get; private set; } = true;

    public bool IsReview { get; private set; }

    public bool IsProgress { get; private set; }

    public bool IsResult { get; private set; }

    public bool IsInstallModeForm { get; private set; }

    public bool IsUpstreamForm { get; private set; }

    public bool IsDnsForm { get; private set; }

    public bool IsLanguageForm { get; private set; }

    public string ValidationTitle { get => _validationTitle; private set => SetProperty(ref _validationTitle, value); }

    public bool HasFieldErrors => _upstreamUrlError.Length > 0 || _dnsServersError.Length > 0;

    public string UpstreamUrl { get => _upstreamUrl; set => SetProperty(ref _upstreamUrl, value); }

    public string UpstreamUrlError { get => _upstreamUrlError; private set => SetProperty(ref _upstreamUrlError, value); }

    public string DnsServers { get => _dnsServers; set => SetProperty(ref _dnsServers, value); }

    public string DnsServersError { get => _dnsServersError; private set => SetProperty(ref _dnsServersError, value); }

    /// <summary>Install mode: false = engine default, true = 'clean'.</summary>
    public bool InstallClean { get => _installClean; set => SetProperty(ref _installClean, value); }

    /// <summary>Upstream mode: false = reset to defaults, true = custom URL.</summary>
    public bool UpstreamCustom { get => _upstreamCustom; set => SetProperty(ref _upstreamCustom, value); }

    public bool LanguageEn
    {
        get => _languageEn;
        set => SetProperty(ref _languageEn, value);
    }

    public bool LanguageVi
    {
        get => !_languageEn;
        set
        {
            if (value)
            {
                _languageEn = false;
                OnPropertyChanged(nameof(LanguageEn));
                OnPropertyChanged();
            }
        }
    }

    public string CurrentPhase { get => _currentPhase; private set => SetProperty(ref _currentPhase, value); }

    public string OutcomeBadge { get; private set; } = string.Empty;

    public bool IsOutcomeSuccess => _outcome == "Success";

    public bool IsOutcomeFailed => _outcome == "Failed";

    public bool IsOutcomeCancelled => _outcome == "Cancelled";

    public string ResultTitle => _resultTitle;

    public string ResultMessage { get => _resultMessage; private set => SetProperty(ref _resultMessage, value); }

    public string ResultCodeText { get => _resultCodeText; private set => SetProperty(ref _resultCodeText, value); }

    public string CurrentStateValue => _currentState;

    public string RestoredStateValue => _restoredState;

    public string NextStepValue => _nextStep;

    public string LogPathValue => _logPath;

    public bool HasCurrentState => _hasCurrentState;

    public bool HasRestoredState => _hasRestoredState;

    public bool HasNextStep => _hasNextStep;

    public bool HasLogPath => _hasLogPath;

    public bool HasCopiedNote => _copiedNote;

    /// <summary>A failure whose engine reports a restore hint ⇒ cleanup may be incomplete (criterion 6).</summary>
    public bool IsIncompleteVisible => _incompleteVisible;

    public bool ReviewDestructive => _descriptor.Destructive;

    /// <summary>The reversible note shows only on a non-destructive review (criterion 5).</summary>
    public bool ReviewNoteVisible { get; private set; } = true;

    /// <summary>True while the engine child keeps running (exit gate; §5.3).</summary>
    public bool ClosingBlocked => _sessionActive;

    public RelayCommand BackCommand { get; }

    public RelayCommand ContinueCommand { get; }

    public RelayCommand ConfirmCommand { get; }

    public RelayCommand CancelRunCommand { get; }

    public RelayCommand CloseResultCommand { get; }

    public RelayCommand OpenLogCommand { get; }

    public RelayCommand CopyDetailsCommand { get; }

    internal Stage CurrentStage => _stage;

    public string ChooseActionLabel => _chooseActionLabel;

    public string ContinueLabel => _continueLabel;

    public string BackLabel => _backLabel;

    public string ConfirmLabel => _confirmLabel;

    public string CancelLabel => _cancelLabel;

    public string CloseLabel => _closeLabel;

    public string ReviewScopeLabel => _reviewScopeLabel;

    public string ReviewNoteLabel => _reviewNoteLabel;

    public string InstallModeLabel => _installModeLabel;

    public string InstallModeCleanLabel => _installModeCleanLabel;

    public string UpstreamKindLabel => _upstreamKindLabel;

    public string UpstreamDefaultsLabel => _upstreamDefaultsLabel;

    public string UpstreamCustomLabel => _upstreamCustomLabel;

    public string UpstreamUrlLabel => _upstreamUrlLabel;

    public string DnsServersLabel => _dnsServersLabel;

    public string LanguageEnLabel => _languageEnLabel;

    public string LanguageViLabel => _languageViLabel;

    public string OpenLogLabel => _openLogLabel;

    public string CopyLabel => _copyLabel;

    public string CopiedNoteLabel => _copiedNoteLabel;

    public string IncompleteNoteLabel => _incompleteNoteLabel;

    public string CodeLabel => _codeLabel;

    public string StateLabel => _stateLabel;

    public string RestoredLabel => _restoredLabel;

    public string NextStepLabel => _nextStepLabel;

    public string LogPathLabel => _logPathLabel;

    private string L(string key) => _localization.GetString(key);

    private void RetranslateLabels()
    {
        _chooseActionLabel = L("Op_ChooseAction");
        _continueLabel = L("Op_Continue");
        _backLabel = L("Op_Back");
        _confirmLabel = L("Op_Confirm");
        _cancelLabel = L("Op_Cancel");
        _closeLabel = L("Op_CloseResult");
        _reviewScopeLabel = L("Review_Scope");
        _reviewNoteLabel = L("Review_NonDestructive");
        _installModeLabel = L("Op_Install_Mode");
        _installModeCleanLabel = L("Op_Install_Mode_Clean");
        _upstreamKindLabel = L("Op_Upstream_Kind");
        _upstreamDefaultsLabel = L("Op_Upstream_ResetDefaults");
        _upstreamCustomLabel = L("Op_Upstream_Custom");
        _upstreamUrlLabel = L("Op_Upstream_Url");
        _dnsServersLabel = L("Op_DnsServersLabel");
        _languageEnLabel = L("Language_English");
        _languageViLabel = L("Language_Vietnamese");
        _openLogLabel = L("Result_OpenLog");
        _copyLabel = L("Result_CopyDetails");
        _copiedNoteLabel = L("Result_Copied");
        _incompleteNoteLabel = L("Result_Incomplete");
        _codeLabel = L("Result_Code");
        _stateLabel = L("Result_State");
        _restoredLabel = L("Result_Restored");
        _nextStepLabel = L("Result_NextStep");
        _logPathLabel = L("Result_LogPath");
        OnPropertyChanged(nameof(ChooseActionLabel));
        OnPropertyChanged(nameof(ContinueLabel));
        OnPropertyChanged(nameof(BackLabel));
        OnPropertyChanged(nameof(ConfirmLabel));
        OnPropertyChanged(nameof(CancelLabel));
        OnPropertyChanged(nameof(CloseLabel));
        OnPropertyChanged(nameof(ReviewScopeLabel));
        OnPropertyChanged(nameof(ReviewNoteLabel));
        OnPropertyChanged(nameof(InstallModeLabel));
        OnPropertyChanged(nameof(InstallModeCleanLabel));
        OnPropertyChanged(nameof(UpstreamKindLabel));
        OnPropertyChanged(nameof(UpstreamDefaultsLabel));
        OnPropertyChanged(nameof(UpstreamCustomLabel));
        OnPropertyChanged(nameof(UpstreamUrlLabel));
        OnPropertyChanged(nameof(DnsServersLabel));
        OnPropertyChanged(nameof(LanguageEnLabel));
        OnPropertyChanged(nameof(LanguageViLabel));
        OnPropertyChanged(nameof(OpenLogLabel));
        OnPropertyChanged(nameof(CopyLabel));
        OnPropertyChanged(nameof(CopiedNoteLabel));
        OnPropertyChanged(nameof(IncompleteNoteLabel));
        OnPropertyChanged(nameof(CodeLabel));
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(RestoredLabel));
        OnPropertyChanged(nameof(NextStepLabel));
        OnPropertyChanged(nameof(LogPathLabel));
    }

    private void LeaveReview()
    {
        ValidationTitle = string.Empty;
        SetStage(Stage.Input);
    }

    private async Task EnterReviewAsync()
    {
        ValidationTitle = string.Empty;
        _upstreamUrlError = string.Empty;
        _dnsServersError = string.Empty;
        var failed = false;

        if (_descriptor.Form == FormKind.Upstream && _upstreamCustom)
        {
            var error = _validator.Validate(Validator.UpstreamField, _upstreamUrl);
            _upstreamUrlError = error ?? string.Empty;
            OnPropertyChanged(nameof(UpstreamUrlError));
            failed |= error is not null;
        }

        if (_descriptor.Form == FormKind.DnsServers)
        {
            var error = _validator.Validate(Validator.DnsServersField, _dnsServers);
            _dnsServersError = error ?? string.Empty;
            OnPropertyChanged(nameof(DnsServersError));
            failed |= error is not null;
        }

        OnPropertyChanged(nameof(HasFieldErrors));

        PreflightBlockers.Clear();
        try
        {
            foreach (var blocker in _preflight.Run().Blockers)
            {
                PreflightBlockers.Add(blocker);
            }
        }
        catch (Exception exception)
        {
            PreflightBlockers.Add(L("Preflight_EngineCheckFailed") + " " + exception.Message);
        }

        // Field errors appear per field; entered values were never cleared (criterion 4).
        if (failed || PreflightBlockers.Count > 0)
        {
            ValidationTitle = L("Error_FieldValidation");
            SetStage(Stage.Input);
            return;
        }

        SetStage(Stage.Review);
    }

    private void StartRun()
    {
        if (_sessionActive || _isBusy)
        {
            return;
        }

        _operationId = Guid.NewGuid().ToString("D");
        _startedUtc = DateTimeOffset.UtcNow;
        _cancelled = false;
        _sessionActive = true;
        _lastErrorCode = null;
        _copiedNote = false;
        OnPropertyChanged(nameof(HasCopiedNote));

        Phases.Clear();
        CurrentPhase = L("Op_Progress_None");

        // Built on the UI thread so the callbacks marshal back (§7.2).
        var progress = new Progress<ProtocolResponse>(OnPhase);
        _cts = new CancellationTokenSource();

        SetStage(Stage.Progress);
        IsBusy = true;

        if (_descriptor.BrokerRouted)
        {
            RunBrokerAsync(_descriptor, BuildArgs(), progress, _cts.Token);
        }
        else
        {
            RunEngineAsync(_descriptor, BuildArgs(), progress, _cts.Token);
        }
    }

    private async void RunBrokerAsync(Descriptor descriptor, IReadOnlyDictionary<string, string> args, IProgress<ProtocolResponse> progress, CancellationToken token)
    {
        var runTask = _broker.InvokeAsync(descriptor.Action, args, progress, token);
        try
        {
            if (!await WaitTerminalOrCancel(runTask, token))
            {
                // App-side cancel: the request keeps executing in the broker session; the coordinator
                // frees its slot on the true arrival and records that terminal in the log itself (§5.3).
                _sessionActive = false;
                OnPropertyChanged(nameof(ClosingBlocked));
                ShowCancelled();
                return;
            }

            var result = await runTask;
            if (result.Cancelled)
            {
                _sessionActive = false;
                OnPropertyChanged(nameof(ClosingBlocked));
                ShowCancelled();
                return;
            }

            OnTerminal(
                descriptor,
                result.Ok,
                result.Code,
                result.Message,
                result.CurrentState,
                result.RestoredState,
                result.NextStep,
                result.LogPath);
        }
        catch (Exception exception)
        {
            OnTerminal(
                descriptor,
                ok: false,
                ErrorCode.EngineGeneric,
                AppLog.Redact(exception.Message),
                "unknown",
                "notRequired",
                L("Engine_NextStep_InspectLog"),
                null);
        }
    }

    private async void RunEngineAsync(Descriptor descriptor, IReadOnlyDictionary<string, string> args, IProgress<ProtocolResponse> progress, CancellationToken token)
    {
        var runTask = _engine.RunAsync(descriptor.Action, args, progress, token);
        try
        {
            if (!await WaitTerminalOrCancel(runTask, token))
            {
                // App-side cancel (§5.3): the child is NOT killed. The Cancelled surface shows now;
                // the late true result lands in the log under the same record id (log-only completion).
                RecordOperation(descriptor, ok: false, ErrorCode.Cancelled.ToString(), L("Result_CancelNote"), null);
                ShowCancelled();

                var late = await runTask;
                RecordOperation(
                    descriptor,
                    late.Ok,
                    late.Code.ToString(),
                    late.Message,
                    late.LogPath,
                    lateCompletion: true);
                _sessionActive = false;
                OnPropertyChanged(nameof(ClosingBlocked));
                return;
            }

            var result = await runTask;
            OnTerminal(
                descriptor,
                result.Ok,
                result.Code,
                result.Message,
                result.CurrentState,
                result.RestoredState,
                result.NextStep,
                result.LogPath);
        }
        catch (Exception exception)
        {
            OnTerminal(
                descriptor,
                ok: false,
                ErrorCode.EngineGeneric,
                AppLog.Redact(exception.Message),
                "unknown",
                "notRequired",
                L("Engine_NextStep_InspectLog"),
                null);
        }
    }

    private static async Task<bool> WaitTerminalOrCancel(Task runTask, CancellationToken token)
    {
        var completed = await Task.WhenAny(runTask, Task.Delay(Timeout.Infinite, token));
        return ReferenceEquals(completed, runTask);
    }

    private void ShowCancelled()
    {
        _cancelled = true;
        IsBusy = false;
        _outcome = "Cancelled";
        _resultTitle = L("Result_Badge_Cancelled");
        ResultMessage = L("Result_CancelNote");
        _resultCodeText = string.Empty;
        _currentState = string.Empty;
        _restoredState = string.Empty;
        _nextStep = string.Empty;
        _logPath = string.Empty;
        _hasCurrentState = false;
        _hasRestoredState = false;
        _hasNextStep = false;
        _hasLogPath = false;
        _incompleteVisible = false;
        OutcomeBadge = "Cancelled";
        UpdateOutcomeAssertions();
        SetStage(Stage.Result);
    }

    private void OnTerminal(
        Descriptor descriptor,
        bool ok,
        ErrorCode code,
        string message,
        string currentState,
        string restoredState,
        string nextStep,
        string? logPath)
    {
        _sessionActive = false;
        IsBusy = false;
        OnPropertyChanged(nameof(ClosingBlocked));

        _outcome = ok ? "Success" : "Failed";
        _resultTitle = ok ? L("Result_Badge_Success") : L(LocalizationManager.ErrorTitleKey(code));
        ResultMessage = string.IsNullOrEmpty(message) ? L("Dash_LoadFailed") : message;
        _resultCodeText = ok ? string.Empty : code.ToString();
        _lastErrorCode = code;

        _currentState = currentState ?? string.Empty;
        _restoredState = restoredState ?? string.Empty;
        _nextStep = nextStep ?? string.Empty;
        _logPath = logPath ?? string.Empty;
        _hasCurrentState = !ok && _currentState.Length > 0;
        _hasRestoredState = !ok && _restoredState.Length > 0;
        _hasNextStep = !ok && _nextStep.Length > 0;
        _hasLogPath = (!ok || _logPath.Length > 0) && _logPath.Length > 0;
        _incompleteVisible = !ok
            && _restoredState.Length > 0
            && _restoredState is not ("notRequired" or "unchanged" or "unknown");

        OutcomeBadge = ok ? "Success" : "Failed";
        UpdateOutcomeAssertions();

        RecordOperation(descriptor, ok, code.ToString(), message, logPath);
        SetStage(Stage.Result);
    }

    private void UpdateOutcomeAssertions()
    {
        OnPropertyChanged(nameof(OutcomeBadge));
        OnPropertyChanged(nameof(IsOutcomeSuccess));
        OnPropertyChanged(nameof(IsOutcomeFailed));
        OnPropertyChanged(nameof(IsOutcomeCancelled));
        OnPropertyChanged(nameof(ResultTitle));
        OnPropertyChanged(nameof(CurrentStateValue));
        OnPropertyChanged(nameof(RestoredStateValue));
        OnPropertyChanged(nameof(NextStepValue));
        OnPropertyChanged(nameof(HasCurrentState));
        OnPropertyChanged(nameof(HasRestoredState));
        OnPropertyChanged(nameof(HasNextStep));
        OnPropertyChanged(nameof(IsIncompleteVisible));
        OnPropertyChanged(nameof(HasLogPath));
        OnPropertyChanged(nameof(LogPathValue));
        OnPropertyChanged(nameof(HasCopiedNote));
    }

    private void RecordOperation(
        Descriptor descriptor,
        bool ok,
        string code,
        string message,
        string? transcriptPath,
        bool lateCompletion = false)
        => _appLog.WriteOperation(
            _operationId,
            WireAction(descriptor.Action),
            _startedUtc,
            DateTimeOffset.UtcNow,
            ok,
            code,
            message,
            transcriptPath,
            lateCompletion);

    private void OnPhase(ProtocolResponse phase)
    {
        var stamp = phase.TsUtc is { } ts
            ? ts.ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture)
            : "--:--:--";
        var tail = $"[{phase.Phase ?? phase.Type}] {AppLog.Redact(phase.Message ?? string.Empty)}";
        Phases.Add($"{stamp} {tail}".TrimEnd());
        while (Phases.Count > MaxPhaseLines)
        {
            Phases.RemoveAt(0);
        }

        if (!string.IsNullOrEmpty(phase.Phase))
        {
            CurrentPhase = phase.Phase;
        }
    }

    private void CancelWaiting()
    {
        try
        {
            _cts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The source is already gone; the wait has ended by itself.
        }
    }

    private void CloseResult()
    {
        _outcome = string.Empty;
        _cancelled = false;
        _lastErrorCode = null;
        SetStage(Stage.Input);
    }

    private void CopyDetails()
    {
        var text = _appLog.ReadOperationLines(_operationId) ?? ResultMessage;
        _appLog.CopyToClipboard(text);
        _copiedNote = true;
        OnPropertyChanged(nameof(HasCopiedNote));
    }

    private IReadOnlyDictionary<string, string> BuildArgs()
    {
        var map = new Dictionary<string, string>();
        switch (_descriptor.Form)
        {
            case FormKind.InstallMode:
                if (_installClean)
                {
                    map["mode"] = "clean";
                }

                break;

            case FormKind.Upstream:
                map["mode"] = _upstreamCustom ? "custom" : "resetDefaults";
                if (_upstreamCustom)
                {
                    map["upstreamUrl"] = _upstreamUrl;
                }

                break;

            case FormKind.DnsServers:
                map["servers"] = _dnsServers;
                break;

            case FormKind.Language:
                map["language"] = _languageEn ? "en" : "vi";
                break;
        }

        return map;
    }

    private void UpdateFormVisibility()
    {
        IsInstallModeForm = _descriptor.Form == FormKind.InstallMode;
        IsUpstreamForm = _descriptor.Form == FormKind.Upstream;
        IsDnsForm = _descriptor.Form == FormKind.DnsServers;
        IsLanguageForm = _descriptor.Form == FormKind.Language;
        ReviewNoteVisible = !_descriptor.Destructive;
        OnPropertyChanged(nameof(IsInstallModeForm));
        OnPropertyChanged(nameof(IsUpstreamForm));
        OnPropertyChanged(nameof(IsDnsForm));
        OnPropertyChanged(nameof(IsLanguageForm));
        OnPropertyChanged(nameof(ReviewDestructive));
        OnPropertyChanged(nameof(ReviewNoteVisible));
    }

    private void SetStage(Stage stage)
    {
        _stage = stage;
        StageText = L(stage switch
        {
            Stage.Input => "Op_Stage_Input",
            Stage.Review => "Op_Stage_Review",
            Stage.Progress => "Op_Stage_Progress",
            _ => "Op_Stage_Result",
        });

        IsInput = stage == Stage.Input;
        IsReview = stage == Stage.Review;
        IsProgress = stage == Stage.Progress;
        IsResult = stage == Stage.Result;
        OnPropertyChanged(nameof(IsInput));
        OnPropertyChanged(nameof(IsReview));
        OnPropertyChanged(nameof(IsProgress));
        OnPropertyChanged(nameof(IsResult));
        InvalidateCommands();
        if (stage == Stage.Result)
        {
            OperationEnded?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Retranslates presentation strings after a language switch.</summary>
    internal void OnLanguageChanged()
    {
        RetranslateLabels();

        foreach (var choice in Choices)
        {
            choice.Name = _localization.GetString(choice.Descriptor.TitleKey);
        }

        for (var index = 0; index < ScopeKeys.Length && index < Scope.Count; index++)
        {
            Scope[index] = _localization.GetString(ScopeKeys[index]);
        }

        var stageKey = _stage switch
        {
            Stage.Input => "Op_Stage_Input",
            Stage.Review => "Op_Stage_Review",
            Stage.Progress => "Op_Stage_Progress",
            _ => "Op_Stage_Result",
        };
        StageText = L(stageKey);

        if (_stage == Stage.Result)
        {
            switch (_outcome)
            {
                case "Cancelled":
                    _resultTitle = L("Result_Badge_Cancelled");
                    ResultMessage = L("Result_CancelNote");
                    break;
                case "Success":
                    _resultTitle = L("Result_Badge_Success");
                    break;
                case "Failed" when _lastErrorCode is { } code:
                    _resultTitle = L(LocalizationManager.ErrorTitleKey(code));
                    break;
            }
        }

        if (_stage == Stage.Progress)
        {
            CurrentPhase = L("Op_Progress_None");
        }
    }

    private void InvalidateCommands() => CommandManager.InvalidateRequerySuggested();

    private static string WireAction(ProtocolAction action)
    {
        var name = action.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }
}

/// <summary>Combo entry: descriptor + localized display name retained for retranslation.</summary>
public sealed class OperationChoice : ObservableObject
{
    private string _name;

    internal OperationChoice(OperationViewModel.Descriptor descriptor, string name)
    {
        Descriptor = descriptor;
        _name = name;
    }

    internal OperationViewModel.Descriptor Descriptor { get; }

    public string Name { get => _name; set => SetProperty(ref _name, value); }
}
