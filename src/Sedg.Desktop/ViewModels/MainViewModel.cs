using Sedg.Desktop.Services;

namespace Sedg.Desktop.ViewModels;

/// <summary>
/// Shell composition (design §5.1): three child views (Dashboard / Operation / Settings), the global
/// Busy gate, the broker status bar text (State-derived, Redacted), first-run language handling, and
/// the auto-refresh of the dashboard after every operation terminal. Nothing shown about the machine
/// is computed here — all value rendering lives in the child view models.
/// </summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly AppLog _appLog;
    private readonly IBrokerCoordinator _broker;
    private readonly LocalizationManager _localization;
    private readonly OperationViewModel _operation;
    private readonly bool _firstRunRequested;
    private bool _isActiveDashboard = true;
    private bool _isActiveSettings;
    private bool _isActiveOperation;
    private bool _busy;
    private string _title = string.Empty;
    private string _brokerStatusText = string.Empty;
    private string _retryElevationLabel = string.Empty;
    private bool _showRetryElevation;
    private string _navDashboard = string.Empty;
    private string _navOperation = string.Empty;
    private string _navSettings = string.Empty;

    public MainViewModel(
        AppLog appLog,
        IEngineClient engine,
        IBrokerCoordinator broker,
        Preflight preflight,
        Validator validator,
        LocalizationManager localization)
    {
        _appLog = appLog;
        _broker = broker;
        _localization = localization;
        _firstRunRequested = localization.IsLanguageUnset;

        Dashboard = new DashboardViewModel(engine, appLog, localization);
        Settings = new SettingsViewModel(appLog, localization);
        _operation = new OperationViewModel(engine, broker, preflight, validator, appLog, localization);
        _operation.OperationEnded += (_, _) => _ = Dashboard.RefreshAsync();
        _operation.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(OperationViewModel.IsBusy))
            {
                Busy = _operation.IsBusy;
            }
        };

        broker.StateChanged += (_, _) => UpdateBrokerStatus();
        localization.LanguageChanged += (_, _) => OnLanguageChanged();

        ShowDashboardCommand = new RelayCommand(_ => ShowDashboard(), _ => CanLeaveWhile(!_operation.IsBusy));
        ShowSettingsCommand = new RelayCommand(_ => ShowSettings(), _ => CanLeaveWhile(true));
        ShowOperationCommand = new RelayCommand(_ => ShowOperation(), _ => CanLeaveWhile(!_operation.IsBusy));
        RetryElevationCommand = new RelayCommand(
            _ => RetryElevation(),
            _ => !_busy && !_broker.CanInvokeMutations);
        RefreshDashboardCommand = new RelayCommand(_ => _ = Dashboard.RefreshAsync(), _ => !_busy);

        Retranslate();
        UpdateBrokerStatus();
    }

    public DashboardViewModel Dashboard { get; }

    public SettingsViewModel Settings { get; }

    public OperationViewModel Operation => _operation;

    public RelayCommand ShowDashboardCommand { get; }

    public RelayCommand ShowSettingsCommand { get; }

    public RelayCommand ShowOperationCommand { get; }

    public RelayCommand RetryElevationCommand { get; }

    public RelayCommand RefreshDashboardCommand { get; }

    public string Title => _title;

    public string BrokerStatusText => _brokerStatusText;

    public string RetryElevationLabel => _retryElevationLabel;

    public string NavDashboard => _navDashboard;

    public string NavOperation => _navOperation;

    public string NavSettings => _navSettings;

    public string RetryBlockedReason => _localization.GetString("Close_Blocked_Reason");

    public bool ShowRetryElevation => _showRetryElevation;

    public bool IsActiveDashboard { get => _isActiveDashboard; private set => SetProperty(ref _isActiveDashboard, value); }

    public bool IsActiveSettings { get => _isActiveSettings; private set => SetProperty(ref _isActiveSettings, value); }

    public bool IsActiveOperation { get => _isActiveOperation; private set => SetProperty(ref _isActiveOperation, value); }

    /// <summary>Global Busy: an operation is actively being waited on (§5.1 gate).</summary>
    public bool Busy { get => _busy; private set => SetProperty(ref _busy, value); }

    /// <summary>True once per run when settings.language is unset (first-run prompt; criterion 10).</summary>
    public bool FirstRunRequested => _firstRunRequested;

    /// <summary>Exit gate: blocked while a one-shot engine child is still awaited (§5.3).</summary>
    public bool ClosingBlocked => _operation.ClosingBlocked;

    private bool CanLeaveWhile(bool canNavigate)
    {
        // Result dismissal lands on the dashboard (§5.2).
        if (!canNavigate)
        {
            return false;
        }

        if (_operation.CurrentStage == OperationViewModel.Stage.Result)
        {
            _operation.CloseResultCommand.Execute(null);
        }

        return true;
    }

    private void ShowDashboard()
    {
        IsActiveDashboard = true;
        IsActiveSettings = false;
        IsActiveOperation = false;
        _ = Dashboard.RefreshAsync();
    }

    private void ShowSettings()
    {
        IsActiveSettings = true;
        IsActiveDashboard = false;
        IsActiveOperation = false;
    }

    private void ShowOperation()
    {
        IsActiveOperation = true;
        IsActiveDashboard = false;
        IsActiveSettings = false;
    }

    private void RetryElevation()
    {
        _appLog.Write("info", "The user requested a fresh elevation attempt.");
        _broker.ResetDecline();
        UpdateBrokerStatus();
    }

    private void UpdateBrokerStatus()
    {
        var text = _localization.GetString(_broker.StatusBarKey);
        if (!_broker.CanInvokeMutations && _broker.DeclineReason is { } reason)
        {
            text += " — " + AppLog.Redact(reason);
        }

        _brokerStatusText = text;
        _showRetryElevation = !_broker.CanInvokeMutations;
        OnPropertyChanged(nameof(BrokerStatusText));
        OnPropertyChanged(nameof(ShowRetryElevation));
    }

    private void OnLanguageChanged()
    {
        Retranslate();
        Dashboard.OnLanguageChanged();
        Settings.OnLanguageChanged();
        _operation.OnLanguageChanged();
        UpdateBrokerStatus();
    }

    private void Retranslate()
    {
        _title = _localization.GetString("App_Title");
        _retryElevationLabel = _localization.GetString("Btn_RetryElevation");
        _navDashboard = _localization.GetString("Nav_Dashboard");
        _navOperation = _localization.GetString("Nav_Operation");
        _navSettings = _localization.GetString("Nav_Settings");
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(RetryElevationLabel));
        OnPropertyChanged(nameof(NavDashboard));
        OnPropertyChanged(nameof(NavOperation));
        OnPropertyChanged(nameof(NavSettings));
    }

    /// <summary>Window shell may offer the first-run prompt and exit gate text directly.</summary>
    internal LocalizationManager Localization => _localization;
}
