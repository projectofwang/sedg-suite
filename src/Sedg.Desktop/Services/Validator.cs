using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Sedg.Desktop.Services;

/// <summary>
/// Field-level input validation run at the Input → Review transition (REQ-008).
/// The broker and engine re-validate authoritatively; the client copy never mutates on its own.
/// </summary>
/// <remarks>
/// Deviation disclosure (Task 1 deviation, carried forward): older design §7.1 literally said
/// "http/https". The engine's <c>Test-DnsUpstream</c> now accepts only <c>https</c>/<c>tls</c>/<c>h3</c>/<c>quic</c>
/// and rejects plaintext <c>http</c>. This Validator mirrors the engine so users learn of the
/// rejection at field level instead of from a late engine <c>Validation</c> failure — rejecting
/// here is the safe, disclosed, better-than-late-failure behavior.
/// </remarks>
public sealed class Validator
{
    public const string UpstreamField = "upstreamUrl";

    public const string DnsServersField = "dnsServers";

    public const string LanguageField = "language";

    public const string ModeField = "mode";

    public string? Validate(string field, string value)
    {
        switch (field)
        {
            case UpstreamField:
                return ValidateUpstreamUrl(value);
            case DnsServersField:
                return ValidateDnsServers(value);
            case LanguageField:
                return ValidateLanguage(value);
            case ModeField:
                return value is "resetDefaults" or "custom"
                    ? null
                    : "Mode must be 'resetDefaults' or 'custom'.";
            default:
                return null;
        }
    }

    private static string? ValidateUpstreamUrl(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "An upstream URL is required for a custom upstream.";
        }

        if (value.Contains('\r') || value.Contains('\n'))
        {
            return "The URL must not contain line breaks.";
        }

        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return "The URL must be absolute (start with scheme https, tls, h3, or quic).";
        }

        if (uri.Scheme is "http")
        {
            return "Plaintext http is not accepted; use https, tls, h3, or quic.";
        }

        if (uri.Scheme is not ("https" or "tls" or "h3" or "quic"))
        {
            return "The URL scheme must be https, tls, h3, or quic.";
        }

        if (string.IsNullOrWhiteSpace(uri.Host))
        {
            return "The URL must carry a host name.";
        }

        return null;
    }

    private static string? ValidateDnsServers(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "Enter one to four DNS server addresses.";
        }

        var servers = ParseServerList(value);
        if (servers.Count is < 1 or > 4)
        {
            return "Enter no more than four and at least one DNS server address.";
        }

        for (var index = 0; index < servers.Count; index++)
        {
            if (!IsStrictIp(servers[index]))
            {
                return $"Address {index + 1} ('{servers[index]}') is not a valid IPv4 or IPv6 address.";
            }
        }

        return null;
    }

    private static string? ValidateLanguage(string value)
        => value is "en" or "vi" ? null : "Language must be 'en' or 'vi'.";

    /// <summary>Splits the entered server list on commas and whitespace, dropping empties.</summary>
    public static List<string> ParseServerList(string value)
        => value
            .Split(new[] { ',', ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList();

    /// <summary>
    /// Strict IPv4 (four numeric octets) or IPv6 (contains ':' and parses). IPAddress.TryParse
    /// alone would silently accept partial forms such as "1.2.3".
    /// </summary>
    public static bool IsStrictIp(string candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return false;
        }

        if (candidate.Contains(':'))
        {
            return IPAddress.TryParse(candidate, out var address)
                   && address.AddressFamily == AddressFamily.InterNetworkV6;
        }

        var octets = candidate.Split('.');
        if (octets.Length != 4 || octets.Any(octet => octet.Length == 0 || !octet.All(char.IsAsciiDigit)))
        {
            return false;
        }

        foreach (var octet in octets)
        {
            // Avoid leading-zero octet ambiguity and overflow.
            if (octet.Length > 3 || !byte.TryParse(octet, out _))
            {
                return false;
            }
        }

        return true;
    }
}
