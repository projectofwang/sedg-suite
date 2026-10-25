namespace Sedg.Protocol;

/// <summary>
/// Structured status returned by the engine status action.
/// Every field REQ-004 names has an explicit probe; no generic bucket substitutes for them.
/// </summary>
public sealed class StatusSnapshot
{
    // REQ-004 field 1: install presence
    public Probe<InstallPresence> InstallPresence { get; init; } = Probe<InstallPresence>.NotApplicable();

    // REQ-004 field 2: both services (dnsproxy-service, winws-service)
    public Probe<ServiceSummary[]> Services { get; init; } = Probe<ServiceSummary[]>.NotApplicable();

    // REQ-004 field 3: watchdog state + last fallback (REQ-020, BR-10)
    public Probe<WatchdogSummary> Watchdog { get; init; } = Probe<WatchdogSummary>.NotApplicable();

    // REQ-004 field 4: DNS mode per adapter
    public Probe<AdapterDns[]> DnsPerAdapter { get; init; } = Probe<AdapterDns[]>.NotApplicable();

    // REQ-004 field 5: upstream host
    public Probe<UpstreamSummary> Upstream { get; init; } = Probe<UpstreamSummary>.NotApplicable();

    // REQ-004 field 6: installed vs approved versions
    public Probe<VersionMatrix> Versions { get; init; } = Probe<VersionMatrix>.NotApplicable();

    // REQ-004 field 7: last update
    public Probe<UpdateRecord> LastUpdate { get; init; } = Probe<UpdateRecord>.NotApplicable();

    // REQ-004 field 8: readiness (computed only from the probes above; unknown => "unknown", never fabricated ready)
    public Probe<Readiness> Readiness { get; init; } = Probe<Readiness>.NotApplicable();

    public List<PhaseInfo> Phases { get; init; } = new();

    public DateTimeOffset ObservedUtc { get; init; }
}

public sealed class InstallPresence
{
    public bool Installed { get; init; }

    public string InstallPath { get; init; } = string.Empty;

    public DateTimeOffset? InstallUtc { get; init; }
}

public sealed class ServiceSummary
{
    public string Name { get; init; } = string.Empty;

    public string Status { get; init; } = string.Empty;

    public string StartType { get; init; } = string.Empty;

    public DateTimeOffset? LastChangeUtc { get; init; }
}

public sealed class WatchdogSummary
{
    public string TaskName { get; init; } = string.Empty;

    public bool Enabled { get; init; }

    public DateTimeOffset? LastRunUtc { get; init; }

    public string? LastOutcome { get; init; }

    public DateTimeOffset? LastFallbackUtc { get; init; }

    public string? LastFallbackReason { get; init; }

    public bool FailClosed { get; init; }
}

public sealed class AdapterDns
{
    public string AdapterName { get; init; } = string.Empty;

    public string Mode { get; init; } = string.Empty;

    public string[] Servers { get; init; } = Array.Empty<string>();

    public bool GatewayBypassed { get; init; }
}

public sealed class UpstreamSummary
{
    public string Host { get; init; } = string.Empty;

    public string Scheme { get; init; } = string.Empty;

    public string Source { get; init; } = string.Empty;

    public bool CredentialsRedacted { get; init; }
}

/// <summary>
/// Per-component installed/approved matrix. The engine writes the matrix as a
/// JSON array, so <see cref="Components"/> is the wire representation.
/// </summary>
public sealed class VersionMatrix
{
    public VersionEntry[] Components { get; init; } = Array.Empty<VersionEntry>();
}

public sealed class VersionEntry
{
    public string Component { get; init; } = string.Empty;

    public string? Installed { get; init; }

    public string? Approved { get; init; }

    public string Match { get; init; } = string.Empty;
}

public sealed class UpdateRecord
{
    public DateTimeOffset Utc { get; init; }

    public string? FromVersion { get; init; }

    public string? ToVersion { get; init; }

    public string Outcome { get; init; } = string.Empty;

    public string ReportedBy { get; init; } = string.Empty;
}

public sealed class Readiness
{
    public string State { get; init; } = string.Empty;

    public string[] Reasons { get; init; } = Array.Empty<string>();
}

/// <summary>Phase id is an OPEN token; unknown ids render generically in the app.</summary>
public sealed class PhaseInfo
{
    public string Id { get; init; } = string.Empty;

    public string Label { get; init; } = string.Empty;

    public string State { get; init; } = string.Empty;
}
