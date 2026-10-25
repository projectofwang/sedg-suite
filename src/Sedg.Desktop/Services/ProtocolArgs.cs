using System.Text.Json.Nodes;
using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// Maps the design §8.1 app-boundary argument shape (IReadOnlyDictionary&lt;string,string&gt;) onto the
/// engine's wire JsonObject. Arrays are never flattened: setDns.servers becomes a JsonArray with one
/// entry per popped address (Task 2 review carry-over). Validation re-uses the shared ArgumentSchemas.
/// </summary>
public static class ProtocolArgs
{
    public static bool TryBuild(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        out JsonObject? wireArgs,
        out string? error)
    {
        wireArgs = null;
        try
        {
            var json = new JsonObject();
            switch (action)
            {
                case ProtocolAction.Install:
                    if (args.TryGetValue("mode", out var installMode))
                    {
                        json.Add("mode", JsonValue.Create(installMode));
                    }
                    break;

                case ProtocolAction.SetUpstream:
                    if (!args.TryGetValue("mode", out var upstreamMode))
                    {
                        error = "Field 'mode' is required ('resetDefaults' or 'custom').";
                        return false;
                    }

                    json.Add("mode", JsonValue.Create(upstreamMode));
                    if (upstreamMode == "custom")
                    {
                        if (!args.TryGetValue("upstreamUrl", out var upstreamUrl))
                        {
                            error = "Field 'upstreamUrl' is required when mode is 'custom'.";
                            return false;
                        }

                        json.Add("upstreamUrl", JsonValue.Create(upstreamUrl));
                    }
                    break;

                case ProtocolAction.SetDns:
                    if (!args.TryGetValue("servers", out var serversRaw))
                    {
                        error = "Field 'servers' is required.";
                        return false;
                    }

                    json.Add("servers", new JsonArray(SplitServers(serversRaw).Select(s => JsonValue.Create(s)).ToArray()));
                    break;

                case ProtocolAction.SetLanguage:
                    if (!args.TryGetValue("language", out var language))
                    {
                        error = "Field 'language' is required ('en' or 'vi').";
                        return false;
                    }

                    json.Add("language", JsonValue.Create(language));
                    break;

                default:
                    // status / update / pause / resume / restart / uninstall / restoreEngine / testCdnOptimization: {} per design §4.1
                    break;
            }

            if (!ArgumentSchemas.Validate(action, json, out var schemaError))
            {
                error = schemaError ?? "The request arguments are invalid.";
                return false;
            }

            wireArgs = json;
            error = null;
            return true;
        }
        catch (Exception exception)
        {
            error = "The arguments could not be mapped to the protocol: " + exception.Message;
            return false;
        }
    }

    /// <summary>Splits the entered server list on commas and whitespace, dropping empties and duplicates.</summary>
    public static List<string> SplitServers(string raw)
        => raw
            .Split(new[] { ',', ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.Ordinal)
            .ToList();
}
