using System.Collections;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Resources;
using System.Text.Json;
using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// EN/VI resource loading (ResourceManager, no package), runtime switching, settings.json persistence
/// at %LOCALAPPDATA%\SedgManager, and the EN/VI parity check (decision record REQ-019 extension).
/// </summary>
public sealed class LocalizationManager
{
    private const string ResourceBaseName = "Sedg.Desktop.Resources.Strings";

    private static readonly IReadOnlySet<string> AllowedLanguages = new HashSet<string> { "en", "vi" };

    private readonly string _settingsDirectory;
    private readonly Assembly _resourceAssembly;
    private ResourceManager? _resources;

    public event EventHandler? LanguageChanged;

    public LocalizationManager()
        : this(settingsDirectory: null, resourceAssembly: null)
    {
    }

    /// <summary>Test seam only: production code uses %LOCALAPPDATA%\SedgManager and the app assembly.</summary>
    internal LocalizationManager(string? settingsDirectory, Assembly? resourceAssembly)
    {
        _resourceAssembly = resourceAssembly ?? Assembly.GetExecutingAssembly();
        _settingsDirectory = settingsDirectory
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SedgManager");
        SettingsFilePath = Path.Combine(_settingsDirectory, "settings.json");
        CurrentLanguage = LoadPersistedLanguage();
    }

    /// <summary>"en", "vi", or "" when unset (first run).</summary>
    public string CurrentLanguage { get; private set; }

    public bool IsLanguageUnset => string.IsNullOrEmpty(CurrentLanguage);

    public string SettingsFilePath { get; }

    public string GetString(string key) => GetString(key, CurrentLanguage);

    /// <summary>Looks up a resource for an explicit language; missing keys are surfaced verbatim so parity fails loudly.</summary>
    public string GetString(string key, string language)
    {
        _resources ??= new ResourceManager(ResourceBaseName, _resourceAssembly);

        var culture = string.IsNullOrEmpty(language)
            ? CultureInfo.InvariantCulture
            : new CultureInfo(language);
        return _resources.GetString(key, culture) ?? "<" + key + ">";
    }

    public void SetLanguage(string language)
    {
        if (!AllowedLanguages.Contains(language))
        {
            throw new ArgumentOutOfRangeException(nameof(language), language, "Language must be 'en' or 'vi'.");
        }

        CurrentLanguage = language;
        PersistLanguage(language);
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    private string LoadPersistedLanguage()
    {
        try
        {
            if (!File.Exists(SettingsFilePath))
            {
                return string.Empty;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(SettingsFilePath));
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("language", out var language))
            {
                return string.Empty;
            }

            var value = language.ValueKind == JsonValueKind.String ? language.GetString() : null;
            return value is not null && AllowedLanguages.Contains(value) ? value : string.Empty;
        }
        catch (Exception)
        {
            // A corrupt settings file must not block the app; a first-run prompt then follows.
            return string.Empty;
        }
    }

    private void PersistLanguage(string language)
    {
        try
        {
            Directory.CreateDirectory(_settingsDirectory);
            File.WriteAllText(SettingsFilePath, JsonSerializer.Serialize(new { @language }));
        }
        catch (Exception)
        {
            // Swallowed: a persistence failure must never break an operation.
        }
    }

    /// <summary>
    /// Verifies the EN and VI resource key sets are identical and every non-None ErrorCode title
    /// from design §14 exists in both files. Returns the missing/extra key list (empty = parity).
    /// </summary>
    public IReadOnlyList<string> VerifyParity()
    {
        var problems = new List<string>();

        var neutralKeys = LoadResourceKeys(_resourceAssembly, $"{ResourceBaseName}.resources");
        if (neutralKeys.Count == 0)
        {
            problems.Add("The neutral EN resource set is empty.");
            return problems;
        }

        var viKeys = LoadViResourceKeys();
        if (viKeys.Count == 0)
        {
            problems.Add("The VI resource set is empty.");
            return problems;
        }

        problems.AddRange(neutralKeys.Where(key => !viKeys.Contains(key)).Select(key => "Missing in VI: " + key));
        problems.AddRange(viKeys.Where(key => !neutralKeys.Contains(key)).Select(key => "Extra in VI: " + key));

        foreach (var code in Enum.GetValues<ErrorCode>())
        {
            if (code == ErrorCode.None)
            {
                continue;
            }

            var key = ErrorTitleKey(code);
            if (!neutralKeys.Contains(key))
            {
                problems.Add("Missing EN title: " + key);
            }
            else if (!viKeys.Contains(key))
            {
                problems.Add("Missing VI title: " + key);
            }
        }

        return problems;
    }

    public static string ErrorTitleKey(ErrorCode code) => "Error_" + code;

    private static HashSet<string> LoadResourceKeys(Assembly assembly, string resourceName)
    {
        try
        {
            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream is null)
            {
                return new HashSet<string>();
            }

            using var reader = new ResourceReader(stream);
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (DictionaryEntry entry in reader)
            {
                if (entry.Key is string key)
                {
                    keys.Add(key);
                }
            }

            return keys;
        }
        catch (Exception)
        {
            return new HashSet<string>();
        }
    }

    /// <summary>Loads the VI key set from the satellite assembly file, or from the main assembly when embedded there.</summary>
    private HashSet<string> LoadViResourceKeys()
    {
        var embedded = LoadResourceKeys(_resourceAssembly, $"{ResourceBaseName}.vi.resources");
        if (embedded.Count > 0)
        {
            return embedded;
        }

        try
        {
            var satellitePath = Path.Combine(AppContext.BaseDirectory, "vi", _resourceAssembly.GetName().Name + ".resources.dll");
            if (!File.Exists(satellitePath))
            {
                return new HashSet<string>();
            }

            var satellite = Assembly.LoadFrom(satellitePath);
            return LoadResourceKeys(satellite, $"{ResourceBaseName}.vi.resources");
        }
        catch (Exception)
        {
            return new HashSet<string>();
        }
    }
}
