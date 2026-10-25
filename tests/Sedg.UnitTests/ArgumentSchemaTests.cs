using System.Text.Json.Nodes;
using Sedg.Desktop.Services;
using Sedg.Protocol;

/// <summary>Per-action accept/reject table (Task 2 criterion 4, mirrored headless).</summary>
public static class ArgumentSchemaTests
{
    private static JsonObject Parse(string literal) => (JsonObject?)JsonObject.Parse(literal) ?? new JsonObject();

    [Test]
    public static void InstallAcceptsNoArgsAndClean()
    {
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.Install, new JsonObject(), out _));
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.Install, new JsonObject { ["mode"] = "clean" }, out _));
    }

    [Test]
    public static void InstallRejectsWrongMode()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.Install, new JsonObject { ["mode"] = "banana" }, out var error) && error is not null);

    [Test]
    public static void InstallRejectsUnknownField()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.Install, new JsonObject { ["junk"] = true }, out var error)
                       && error!.Contains("junk", StringComparison.Ordinal));

    [Test]
    public static void InstallRejectsNonStringMode()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.Install, new JsonObject { ["mode"] = 1_234 }, out var error) && error is not null);

    [Test]
    public static void SetUpstreamAcceptsResetDefaultsAndValidCustom()
    {
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetUpstream, new JsonObject { ["mode"] = "resetDefaults" }, out _));
        Assert.True(ArgumentSchemas.Validate(
            ProtocolAction.SetUpstream,
            new JsonObject { ["mode"] = "custom", ["upstreamUrl"] = "https://dns.example.com" },
            out _));
    }

    [Test]
    public static void SetUpstreamRejectsMissingRequiredMode()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetUpstream, new JsonObject { ["upstreamUrl"] = "https://x" }, out var error)
                       && error is not null);

    [Test]
    public static void SetUpstreamRejectsCustomWithoutUrl()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetUpstream, new JsonObject { ["mode"] = "custom" }, out var error)
                       && error is not null);

    [Test]
    public static void SetUpstreamRejectsBadUrl()
        => Assert.True(!ArgumentSchemas.Validate(
            ProtocolAction.SetUpstream,
            new JsonObject { ["mode"] = "custom", ["upstreamUrl"] = "junk" },
            out _));

    [Test]
    public static void SetUpstreamRejectsEmptyUrl()
        => Assert.True(!ArgumentSchemas.Validate(
            ProtocolAction.SetUpstream,
            new JsonObject { ["mode"] = "custom", ["upstreamUrl"] = "https://" },
            out _));

    [Test]
    public static void SetDnsAcceptsOneToFourAddresses()
    {
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":["8.8.8.8"]}"""), out _));
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":["8.8.8.8","8.8.4.4","1.1.1.1","1.0.0.1"]}"""), out _));
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":["8.8.8.8","2001:db8::1"]}"""), out _));
    }

    [Test]
    public static void SetDnsRejectsZeroAndFiveAddresses()
    {
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":[]}"""), out _));
        Assert.True(!ArgumentSchemas.Validate(
            ProtocolAction.SetDns,
            Parse("""{"servers":["8.8.8.8","8.8.4.4","1.1.1.1","1.0.0.1","9.9.9.9"]}"""),
            out _));
    }

    [Test]
    public static void SetDnsRejectsNonArrayAndUnparseableEntries()
    {
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":"8.8.8.8"}"""), out var shapeError)
                    && shapeError!.Contains("array", StringComparison.Ordinal));
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":["junk"]}"""), out _));
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetDns, Parse("""{"servers":[1]}"""), out _));
    }

    [Test]
    public static void SetDnsRejectsMissingServers()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetDns, new JsonObject(), out _));

    [Test]
    public static void SetLanguageAcceptsEnAndViOnly()
    {
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetLanguage, Parse("""{"language":"en"}"""), out _));
        Assert.True(ArgumentSchemas.Validate(ProtocolAction.SetLanguage, Parse("""{"language":"vi"}"""), out _));
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetLanguage, Parse("""{"language":"fr"}"""), out _));
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetLanguage, Parse("""{"language":""}"""), out _));
        Assert.True(!ArgumentSchemas.Validate(ProtocolAction.SetLanguage, new JsonObject(), out _));
    }

    [Test]
    public static void NoArgsActionsAcceptEmptyAndRejectUnknownFields()
    {
        foreach (var action in new[]
                 {
                     ProtocolAction.Status, ProtocolAction.Update, ProtocolAction.Pause, ProtocolAction.Resume,
                     ProtocolAction.Restart, ProtocolAction.Uninstall, ProtocolAction.Purge,
                     ProtocolAction.RestoreEngine, ProtocolAction.TestCdnOptimization,
                 })
        {
            Assert.True(ArgumentSchemas.Validate(action, new JsonObject(), out _));
            Assert.True(!ArgumentSchemas.Validate(action, new JsonObject { ["junk"] = 1 }, out var error)
                        && error!.Contains("junk", StringComparison.Ordinal));
        }
    }

    [Test]
    public static void NullArgsAreRejected()
        => Assert.True(!ArgumentSchemas.Validate(ProtocolAction.Status, null, out var error) && error is not null);

    [Test]
    public static void AppBoundaryArgsMapServersToAJsonArray()
    {
        Assert.True(ProtocolArgs.TryBuild(
            ProtocolAction.SetDns,
            new Dictionary<string, string> { ["servers"] = "8.8.8.8, 1.1.1.1" },
            out var wire,
            out _));
        Assert.Equal("""{"servers":["8.8.8.8","1.1.1.1"]}""", wire!.ToJsonString());
    }

    [Test]
    public static void AppBoundaryArgsDropDuplicateAndEmptyServerEntries()
    {
        Assert.True(ProtocolArgs.TryBuild(
            ProtocolAction.SetDns,
            new Dictionary<string, string> { ["servers"] = "8.8.8.8, 8.8.8.8" },
            out var wire,
            out _));
        Assert.Equal("""{"servers":["8.8.8.8"]}""", wire!.ToJsonString());
    }

    [Test]
    public static void AppBoundaryArgsRejectNonIpServerLists()
        => Assert.True(!ProtocolArgs.TryBuild(
            ProtocolAction.SetDns,
            new Dictionary<string, string> { ["servers"] = "junk" },
            out _,
            out _));

    [Test]
    public static void AppBoundaryArgsRequireUpstreamModeAndUrl()
    {
        Assert.True(!ProtocolArgs.TryBuild(ProtocolAction.SetUpstream, new Dictionary<string, string>(), out _, out _));
        Assert.True(!ProtocolArgs.TryBuild(
            ProtocolAction.SetUpstream,
            new Dictionary<string, string> { ["mode"] = "custom" },
            out _,
            out _));
        Assert.True(ProtocolArgs.TryBuild(
            ProtocolAction.SetUpstream,
            new Dictionary<string, string> { ["mode"] = "custom", ["upstreamUrl"] = "https://x.example" },
            out _,
            out _));
    }
}
