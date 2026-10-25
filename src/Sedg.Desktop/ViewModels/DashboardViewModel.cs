using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using Sedg.Desktop.Services;
using Sedg.Protocol;

namespace Sedg.Desktop.ViewModels;

/// <summary>
/// Read-only dashboard (behaviour 1): the eight StatusSnapshot fields, rendered exactly as the
/// engine delivered them. <c>status</c> is app-direct and unelevated — it never causes a UAC
/// prompt (criteria 1). Unknown probes are muted, carry their reason, and are never guessed;
/// readiness is never computed or fabricated locally (§4.3).
/// </summary>
public sealed class DashboardViewModel : ObservableObject
{
    private static readonly (string Key, string Field, string TitleKey)[] RowSpec =
    {
        ("install", "installPresence", "Dash_Row_Install"),
        ("services", "services", "Dash_Row_Services"),
        ("watchdog", "watchdog", "Dash_Row_Watchdog"),
        ("dns", "dnsPerAdapter", "Dash_Row_Dns"),
        ("upstream", "upstream", "Dash_Row_Upstream"),
        ("versions", "versions", "Dash_Row_Versions"),
        ("lastUpdate", "lastUpdate", "Dash_Row_LastUpdate"),
        ("readiness", "readiness", "Dash_Row_Readiness"),
    };

    private static readonly IProgress<ProtocolResponse> NoProgress = new Progress<ProtocolResponse>();
    private static readonly IReadOnlyDictionary<string, string> EmptyArgs = new Dictionary<string, string>();

    private readonly IEngineClient _engine;
    private readonly AppLog _appLog;
    private readonly LocalizationManager _localization;

    private bool _isBusy;
    private string _statusText = string.Empty;
    private bool _hasError;
    private string _refreshLabel = string.Empty;
    private string _notApplicableText = string.Empty;

    public DashboardViewModel(IEngineClient engine, AppLog appLog, LocalizationManager localization)
    {
        _engine = engine;
        _appLog = appLog;
        _localization = localization;
        for (var index = 0; index < RowSpec.Length; index++)
        {
            Rows.Add(new DashboardRow(RowSpec[index].Key, _localization.GetString(RowSpec[index].TitleKey)));
        }

        _refreshLabel = _localization.GetString("Dash_Refresh");
        _notApplicableText = _localization.GetString("Dash_NotApplicable");
        RefreshCommand = new RelayCommand(_ => _ = RefreshAsync(), _ => !_isBusy);
    }

    public string RefreshLabel
    {
        get => _refreshLabel;
        private set => SetProperty(ref _refreshLabel, value);
    }

    public string NotApplicableText
    {
        get => _notApplicableText;
        private set => SetProperty(ref _notApplicableText, value);
    }

    public ObservableCollection<DashboardRow> Rows { get; } = new();

    public bool IsBusy { get => _isBusy; private set => SetProperty(ref _isBusy, value); }

    /// <summary>Banner text: populated on a failed refresh; otherwise empty.</summary>
    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    public bool HasError { get => _hasError; private set => SetProperty(ref _hasError, value); }

    public RelayCommand RefreshCommand { get; }

    private string L(string key) => _localization.GetString(key);

    /// <summary>Refreshes via IEngineClient only; never a UAC prompt (behaviour 1). One operation line is recorded.</summary>
    internal async Task RefreshAsync()
    {
        if (_isBusy)
        {
            return;
        }

        IsBusy = true;
        HasError = false;
        StatusText = string.Empty;

        var operationId = Guid.NewGuid().ToString("D");
        var startedUtc = DateTimeOffset.UtcNow;
        try
        {
            EngineRunResult result;
            try
            {
                result = await _engine.RunAsync(
                    ProtocolAction.Status,
                    EmptyArgs,
                    NoProgress,
                    CancellationToken.None);
            }
            catch (Exception exception)
            {
                result = new EngineRunResult
                {
                    Ok = false,
                    Code = ErrorCode.EngineGeneric,
                    Message = AppLog.Redact(exception.Message),
                };
            }

            if (result.Ok && result.Data is JsonElement data && data.ValueKind == JsonValueKind.Object)
            {
                ApplySnapshot(data);
            }
            else
            {
                var reason = result.Ok
                    ? L("Dash_SnapshotMissing")
                    : string.IsNullOrEmpty(result.Message) ? L("Dash_LoadFailed") : result.Message;
                ResetRowsUnknown(reason);
                HasError = true;
                StatusText = reason;
            }

            _appLog.WriteOperation(
                operationId,
                "status",
                startedUtc,
                DateTimeOffset.UtcNow,
                result.Ok,
                result.Code.ToString(),
                result.Message,
                result.LogPath);
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Retranslates row titles after a language switch.</summary>
    internal void OnLanguageChanged()
    {
        for (var index = 0; index < RowSpec.Length; index++)
        {
            Rows[index].Title = _localization.GetString(RowSpec[index].TitleKey);
        }

        RefreshLabel = _localization.GetString("Dash_Refresh");
        NotApplicableText = _localization.GetString("Dash_NotApplicable");
    }

    /// <summary>Test seam: fills all eight rows from a snapshot object.</summary>
    internal void ApplySnapshot(JsonElement snapshot)
    {
        for (var index = 0; index < RowSpec.Length; index++)
        {
            RenderRow(index, TryProbe(snapshot, RowSpec[index].Field), Renderers[index]);
        }
    }

    private static readonly Func<JsonElement, string>[] Renderers =
    {
        RenderInstall,
        RenderServices,
        RenderWatchdog,
        RenderDns,
        RenderUpstream,
        RenderVersions,
        RenderLastUpdate,
        RenderReadiness,
    };

    private static JsonElement? TryProbe(JsonElement snapshot, string field)
    {
        if (snapshot.ValueKind != JsonValueKind.Object || !snapshot.TryGetProperty(field, out var probe))
        {
            return null;
        }

        return probe;
    }

    private void RenderRow(int index, JsonElement? probe, Func<JsonElement, string> renderValue)
    {
        var row = Rows[index];

        if (probe is not JsonElement probeElement || probeElement.ValueKind != JsonValueKind.Object)
        {
            // Structurally wrong or absent probe: honest "unknown", never a guess (BR honesty).
            SetUnknown(row, "unknown", L("Dash_SnapshotMissing"));
            return;
        }

        var state = GetStringProperty(probeElement, "state");
        switch (state)
        {
            case "known":
                if (probeElement.TryGetProperty("value", out var value)
                    && value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined))
                {
                    row.State = "known";
                    row.IsUnknown = false;
                    row.IsNotApplicable = false;
                    row.HasValue = true;
                    row.Value = renderValue(value);
                    row.Reason = string.Empty;
                }
                else
                {
                    SetUnknown(row, "unknown", L("Dash_Unknown"));
                }

                break;

            case "unknown":
                SetUnknown(
                    row,
                    "unknown",
                    GetStringProperty(probeElement, "reason") is { Length: > 0 } reason
                        ? reason
                        : L("Dash_Unknown"));
                break;

            case "notApplicable":
                row.State = "notApplicable";
                row.IsUnknown = false;
                row.IsNotApplicable = true;
                row.HasValue = false;
                row.Value = string.Empty;
                row.Reason = string.Empty;
                break;

            default:
                SetUnknown(row, state.Length == 0 ? "unknown" : state, L("Dash_Unknown"));
                break;
        }
    }

    private static void SetUnknown(DashboardRow row, string state, string reason)
    {
        row.State = state;
        row.IsUnknown = true;
        row.IsNotApplicable = false;
        row.HasValue = false;
        row.Value = string.Empty;
        row.Reason = reason;
    }

    private void ResetRowsUnknown(string reason)
    {
        for (var index = 0; index < RowSpec.Length; index++)
        {
            SetUnknown(Rows[index], "unknown", reason);
        }
    }

    // ---- per-field renderers (design §4.3 shapes); a shape mismatch degrades to Compact -------

    private static string RenderInstall(JsonElement value)
        => value.ValueKind != JsonValueKind.Object
            ? Compact(value)
            : (TryGetBoolean(value, "installed") ?? false ? "installed" : "not installed")
              + Suffix(GetStringProperty(value, "installPath"))
              + Paren(GetStringProperty(value, "installUtc"));

    private static string RenderServices(JsonElement value)
        => value.ValueKind != JsonValueKind.Array
            ? Compact(value)
            : string.Join("; ", value.EnumerateArray().Select(service =>
                service.ValueKind == JsonValueKind.Object
                    ? GetStringProperty(service, "name")
                      + Paren(
                          GetStringProperty(service, "status")
                          + Suffix(GetStringProperty(service, "startType")))
                    : Compact(service)));

    private static string RenderWatchdog(JsonElement value)
        => value.ValueKind != JsonValueKind.Object
            ? Compact(value)
            : GetStringProperty(value, "taskName")
              + Paren(string.Join(", ", Details(value)));

    private static IEnumerable<string> Details(JsonElement value)
    {
        var details = new List<string>();
        var enabled = TryGetBoolean(value, "enabled");
        if (enabled is not null)
        {
            details.Add(enabled.Value ? "enabled" : "disabled");
        }

        var outcome = GetStringProperty(value, "lastOutcome");
        if (outcome.Length > 0)
        {
            details.Add("last outcome: " + outcome);
        }

        if (TryGetBoolean(value, "failClosed") == true)
        {
            details.Add("fail-closed");
        }

        var lastRun = GetStringProperty(value, "lastRunUtc");
        if (lastRun.Length > 0)
        {
            details.Add(lastRun);
        }

        var lastFallback = GetStringProperty(value, "lastFallbackUtc");
        if (lastFallback.Length > 0)
        {
            details.Add("fallback " + lastFallback);
        }

        return details;
    }

    private static string RenderDns(JsonElement value)
        => value.ValueKind != JsonValueKind.Array
            ? Compact(value)
            : string.Join("; ", value.EnumerateArray().Select(adapter =>
                adapter.ValueKind == JsonValueKind.Object
                    ? GetStringProperty(adapter, "adapterName")
                      + Paren(
                          GetStringProperty(adapter, "mode")
                          + Suffix(Compact(adapter.TryGetProperty("servers", out var servers) ? servers : default))
                          + (TryGetBoolean(adapter, "gatewayBypassed") == true ? ", bypassed" : ""))
                    : Compact(adapter)));

    private static string RenderUpstream(JsonElement value)
        => value.ValueKind != JsonValueKind.Object
            ? Compact(value)
            : GetStringProperty(value, "host")
              + Paren(
                  GetStringProperty(value, "scheme")
                  + Suffix(GetStringProperty(value, "source")));

    private static string RenderVersions(JsonElement value)
        => value.ValueKind == JsonValueKind.Array
            ? string.Join("; ", value.EnumerateArray().Select(entry =>
                entry.ValueKind == JsonValueKind.Object
                    ? GetStringProperty(entry, "component") + Paren(VersionDetails(entry))
                    : Compact(entry)))
            : Compact(value);

    private static string VersionDetails(JsonElement entry)
    {
        var details = new List<string>();
        var approved = entry.TryGetProperty("approved", out var approvedValue) ? Verbose(approvedValue) : null;
        var installed = entry.TryGetProperty("installed", out var installedValue) ? Verbose(installedValue) : null;
        var match = entry.TryGetProperty("match", out var matchValue) ? Verbose(matchValue) : null;
        if (approved is not null)
        {
            details.Add("approved " + approved);
        }

        if (installed is not null)
        {
            details.Add("installed " + installed);
        }

        if (match is not null)
        {
            details.Add("match " + match);
        }

        return string.Join(", ", details);
    }

    private static string RenderLastUpdate(JsonElement value)
        => value.ValueKind != JsonValueKind.Object
            ? Compact(value)
            : GetStringProperty(value, "utc")
          + Paren(
              GetStringProperty(value, "fromVersion")
              + (GetStringProperty(value, "toVersion") is { Length: > 0 } to ? " → " + to : "")
              + Suffix(GetStringProperty(value, "outcome")));

    private static string RenderReadiness(JsonElement value)
        => value.ValueKind != JsonValueKind.Object
            ? Compact(value)
            : GetStringProperty(value, "state")
              + (value.TryGetProperty("reasons", out var reasons) && reasons.ValueKind == JsonValueKind.Array && reasons.GetArrayLength() > 0
                  ? Paren(string.Join("; ", reasons.EnumerateArray().Select(reason =>
                      reason.ValueKind == JsonValueKind.String ? reason.GetString() ?? "" : reason.GetRawText())))
                  : "");

    /// <summary>Human one-line summary of an arbitrary JSON shape — honest rendering of open shapes.</summary>
    internal static string Compact(JsonElement value)
    {
        try
        {
            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString() ?? "",
                JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => value.GetRawText(),
                JsonValueKind.Null or JsonValueKind.Undefined => string.Empty,
                JsonValueKind.Object => string.Join(", ", value.EnumerateObject().Select(property =>
                    property.Name + "=" + (property.Value.ValueKind switch
                    {
                        JsonValueKind.String => property.Value.GetString(),
                        JsonValueKind.Object or JsonValueKind.Array => "…",
                        _ => TrimQuotes(property.Value.GetRawText()),
                    }))),
                JsonValueKind.Array => string.Join("; ", value.EnumerateArray().Select(Compact)),
                _ => TrimQuotes(value.GetRawText()),
            };
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }

    // ---- small JSON helpers ------------------------------------------------------------------

    private static string GetStringProperty(JsonElement element, string property)
        => element.ValueKind == JsonValueKind.Object
           && element.TryGetProperty(property, out var propertyValue)
           && propertyValue.ValueKind == JsonValueKind.String
            ? propertyValue.GetString() ?? ""
            : "";

    private static bool? TryGetBoolean(JsonElement element, string property)
        => element.ValueKind == JsonValueKind.Object
           && element.TryGetProperty(property, out var propertyValue)
            ? propertyValue.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.String when bool.TryParse(propertyValue.GetString(), out var parsed) => parsed,
                _ => (bool?)null,
            }
            : null;

    private static string Verbose(JsonElement element)
        => element.ValueKind switch
        {
            JsonValueKind.String => element.GetString() ?? "",
            JsonValueKind.True => "yes",
            JsonValueKind.False => "no",
            _ => TrimQuotes(element.GetRawText()),
        };

    private static string TrimQuotes(string raw)
        => raw.Length >= 2 && raw[0] == '"' && raw[^1] == '"' ? raw[1..^1] : raw;

    private static string Suffix(string value) => string.IsNullOrWhiteSpace(value) ? "" : " " + value;

    private static string Paren(string value) => string.IsNullOrWhiteSpace(value) ? "" : " (" + value + ")";

    /// <summary>One dashboard row: a fixed observable record per REQ-004 field.</summary>
    public sealed class DashboardRow : ObservableObject
    {
        private string _title;
        private string _state = "unknown";
        private string _value = string.Empty;
        private string _reason = string.Empty;
        private bool _hasValue;
        private bool _isUnknown;
        private bool _isNotApplicable;

        public DashboardRow(string key, string title)
        {
            Key = key;
            _title = title;
        }

        public string Key { get; }

        public string Title { get => _title; set => SetProperty(ref _title, value); }

        /// <summary>Raw probe state as delivered ("known", "unknown", "notApplicable").</summary>
        public string State { get => _state; set => SetProperty(ref _state, value); }

        public string Value { get => _value; set => SetProperty(ref _value, value); }

        public string Reason { get => _reason; set => SetProperty(ref _reason, value); }

        public bool HasValue { get => _hasValue; set => SetProperty(ref _hasValue, value); }

        public bool IsUnknown { get => _isUnknown; set => SetProperty(ref _isUnknown, value); }

        public bool IsNotApplicable { get => _isNotApplicable; set => SetProperty(ref _isNotApplicable, value); }
    }
}
