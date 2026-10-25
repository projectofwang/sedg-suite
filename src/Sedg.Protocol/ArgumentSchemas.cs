using System.Net;
using System.Text.Json.Nodes;

namespace Sedg.Protocol;

/// <summary>Per-action argument validation rules (fixed schemas; unknown fields rejected).</summary>
public static class ArgumentSchemas
{
    public static bool Validate(ProtocolAction action, JsonObject? args, out string? error)
    {
        error = null;
        if (args is null)
        {
            error = "args must be a JSON object.";
            return false;
        }

        return action switch
        {
            ProtocolAction.Install => ValidateInstall(args, out error),
            ProtocolAction.SetUpstream => ValidateSetUpstream(args, out error),
            ProtocolAction.SetDns => ValidateSetDns(args, out error),
            ProtocolAction.SetLanguage => ValidateSetLanguage(args, out error),
            ProtocolAction.Status
                or ProtocolAction.Update
                or ProtocolAction.Pause
                or ProtocolAction.Resume
                or ProtocolAction.Restart
                or ProtocolAction.Uninstall
                or ProtocolAction.Purge
                or ProtocolAction.RestoreEngine
                or ProtocolAction.TestCdnOptimization => ValidateNoArgs(action, args, out error),
            _ => Fail("Unknown protocol action.", out error),
        };
    }

    private static bool ValidateNoArgs(ProtocolAction action, JsonObject args, out string? error)
    {
        foreach (var property in args)
        {
            return Fail($"Unknown field '{property.Key}' for action '{action}'.", out error);
        }

        error = null;
        return true;
    }

    private static bool ValidateInstall(JsonObject args, out string? error)
    {
        foreach (var property in args)
        {
            if (property.Key != "mode")
            {
                return Fail($"Unknown field '{property.Key}' for action 'Install'.", out error);
            }
        }

        if (args.TryGetPropertyValue("mode", out var modeNode))
        {
            if (!TryGetString(modeNode, out var mode) || mode != "clean")
            {
                return Fail("Field 'mode' must be 'clean' when provided.", out error);
            }
        }

        error = null;
        return true;
    }

    private static bool ValidateSetUpstream(JsonObject args, out string? error)
    {
        foreach (var property in args)
        {
            if (property.Key is not ("mode" or "upstreamUrl"))
            {
                return Fail($"Unknown field '{property.Key}' for action 'SetUpstream'.", out error);
            }
        }

        if (!args.TryGetPropertyValue("mode", out var modeNode) || !TryGetString(modeNode, out var mode))
        {
            return Fail("Field 'mode' is required and must be 'resetDefaults' or 'custom'.", out error);
        }

        if (mode is not ("resetDefaults" or "custom"))
        {
            return Fail("Field 'mode' must be 'resetDefaults' or 'custom'.", out error);
        }

        var hasUrl = args.TryGetPropertyValue("upstreamUrl", out var urlNode);
        if (hasUrl && urlNode is not null && !TryGetString(urlNode, out _))
        {
            return Fail("Field 'upstreamUrl' must be a string.", out error);
        }

        if (mode == "custom")
        {
            if (!hasUrl || !TryGetString(urlNode, out var url))
            {
                return Fail("Field 'upstreamUrl' is required when mode is 'custom'.", out error);
            }

            if (!IsValidUpstreamUrl(url))
            {
                return Fail("Field 'upstreamUrl' must be an absolute https/tls/h3/quic URL with a host.", out error);
            }
        }

        error = null;
        return true;
    }

    private static bool ValidateSetDns(JsonObject args, out string? error)
    {
        foreach (var property in args)
        {
            if (property.Key != "servers")
            {
                return Fail($"Unknown field '{property.Key}' for action 'SetDns'.", out error);
            }
        }

        if (!args.TryGetPropertyValue("servers", out var serversNode) || serversNode is not JsonArray servers)
        {
            return Fail("Field 'servers' is required and must be an array.", out error);
        }

        if (servers.Count is < 1 or > 4)
        {
            return Fail("Field 'servers' must contain 1 to 4 addresses.", out error);
        }

        for (var index = 0; index < servers.Count; index++)
        {
            if (!TryGetString(servers[index], out var address) || !IPAddress.TryParse(address.Trim(), out _))
            {
                return Fail($"Field 'servers[{index}]' is not a parseable IPv4/IPv6 address.", out error);
            }
        }

        error = null;
        return true;
    }

    private static bool ValidateSetLanguage(JsonObject args, out string? error)
    {
        foreach (var property in args)
        {
            if (property.Key != "language")
            {
                return Fail($"Unknown field '{property.Key}' for action 'SetLanguage'.", out error);
            }
        }

        if (!args.TryGetPropertyValue("language", out var languageNode)
            || !TryGetString(languageNode, out var language)
            || language is not ("en" or "vi"))
        {
            return Fail("Field 'language' must be 'en' or 'vi'.", out error);
        }

        error = null;
        return true;
    }

    private static bool TryGetString(JsonNode? node, out string value)
    {
        if (node is JsonValue jsonValue
            && jsonValue.TryGetValue<string>(out var text)
            && text is not null)
        {
            value = text;
            return true;
        }

        value = string.Empty;
        return false;
    }

    private static bool IsValidUpstreamUrl(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Contains('\r') || value.Contains('\n'))
        {
            return false;
        }

        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && uri.Scheme is "https" or "tls" or "h3" or "quic"
            && !string.IsNullOrWhiteSpace(uri.Host);
    }

    private static bool Fail(string message, out string? error)
    {
        error = message;
        return false;
    }
}
