using Sedg.Desktop.Services;

namespace Sedg.Desktop.ViewModels;

/// <summary>
/// Product language control (BR-15) without reinstall: the switch persists to
/// settings.json immediately and raises LanguageChanged so every surface retranslates.
/// The operations log / app log stay record-first resolvable %%LOCALAPPDATA%%\SedgManager.
/// </summary>
public sealed class SettingsViewModel : ObservableObject
{
    private readonly AppLog _appLog;
    private readonly LocalizationManager _localization;
    private bool _languageEn;
    private bool _languageVi;
    private string _title = string.Empty;
    private string _languageLabel = string.Empty;
    private string _languageNote = string.Empty;
    private string _dataFolderLabel = string.Empty;
    private string _dataFolderPath = string.Empty;
    private string _logsLabel = string.Empty;
    private string _openAppLogLabel = string.Empty;
    private string _openOperationsLabel = string.Empty;
    private string _englishLabel = string.Empty;
    private string _vietnameseLabel = string.Empty;

    public SettingsViewModel(AppLog appLog, LocalizationManager localization)
    {
        _appLog = appLog;
        _localization = localization;
        _languageEn = !string.Equals(_localization.CurrentLanguage, "vi", StringComparison.OrdinalIgnoreCase);
        _languageVi = !_languageEn;

        OpenAppLogCommand = new RelayCommand(_ => _appLog.OpenInExplorer(_appLog.LogDirectory), _ => true);
        OpenOperationsCommand = new RelayCommand(_ => _appLog.OpenInExplorer(_appLog.OperationsLogPath), _ => true);
        Retranslate();
    }

    public RelayCommand OpenAppLogCommand { get; }

    public RelayCommand OpenOperationsCommand { get; }

    public string Title => _title;

    public string LanguageLabel => _languageLabel;

    public string LanguageNote => _languageNote;

    public string DataFolderLabel => _dataFolderLabel;

    public string DataFolderPath => _dataFolderPath;

    public string LogsLabel => _logsLabel;

    public string OpenAppLogLabel => _openAppLogLabel;

    public string OpenOperationsLabel => _openOperationsLabel;

    public string EnglishLabel => _englishLabel;

    public string VietnameseLabel => _vietnameseLabel;

    public bool LanguageEn
    {
        get => _languageEn;
        set
        {
            // A group de-select pushes false into the other radio's binding; only a check switches.
            if (value)
            {
                Select("en");
            }
        }
    }

    public bool LanguageVi
    {
        get => _languageVi;
        set
        {
            if (value)
            {
                Select("vi");
            }
        }
    }

    private void Select(string language)
    {
        if (string.Equals(_localization.CurrentLanguage, language, StringComparison.Ordinal))
        {
            return;
        }

        // An unset first run lands here once the first-run dialog chooses; the radio reflects it.
        _localization.SetLanguage(language);
        _appLog.Write("info", "Language: " + language);
        _languageEn = language == "en";
        _languageVi = language == "vi";
        OnPropertyChanged(nameof(LanguageEn));
        OnPropertyChanged(nameof(LanguageVi));
        Retranslate();
    }

    /// <summary>Synchronous retranslation after an external language change (first-run dialog).</summary>
    internal void OnLanguageChanged()
    {
        _languageEn = !string.Equals(_localization.CurrentLanguage, "vi", StringComparison.OrdinalIgnoreCase);
        _languageVi = !_languageEn;
        OnPropertyChanged(nameof(LanguageEn));
        OnPropertyChanged(nameof(LanguageVi));
        Retranslate();
    }

    private void Retranslate()
    {
        _title = _localization.GetString("Settings_Title");
        _languageLabel = _localization.GetString("Settings_Language");
        _languageNote = _localization.GetString("Settings_LanguageNote");
        _dataFolderLabel = _localization.GetString("Settings_DataFolder");
        _dataFolderPath = _appLog.BaseDirectory;
        _logsLabel = _localization.GetString("Settings_Logs");
        _openAppLogLabel = _localization.GetString("Settings_OpenAppLog");
        _openOperationsLabel = _localization.GetString("Settings_OpenOperations");
        _englishLabel = _localization.GetString("Language_English");
        _vietnameseLabel = _localization.GetString("Language_Vietnamese");
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(LanguageLabel));
        OnPropertyChanged(nameof(LanguageNote));
        OnPropertyChanged(nameof(DataFolderLabel));
        OnPropertyChanged(nameof(DataFolderPath));
        OnPropertyChanged(nameof(LogsLabel));
        OnPropertyChanged(nameof(OpenAppLogLabel));
        OnPropertyChanged(nameof(OpenOperationsLabel));
        OnPropertyChanged(nameof(EnglishLabel));
        OnPropertyChanged(nameof(VietnameseLabel));
    }
}
