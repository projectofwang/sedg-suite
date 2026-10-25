using Sedg.Desktop.Services;

/// <summary>The Input to Review gate mirrors the engine: schemes, DNS addresses, and enum values.</summary>
public static class ValidatorTests
{
    private static readonly Validator Validator = new();

    [Test]
    public static void UpstreamUrlTable()
    {
        foreach (var url in new[]
                 {
                     "https://example.com",
                     "https://cdn.example.com:8443/path",
                     "tls://upstream.example.net",
                     "h3://upstream.example.net",
                     "quic://upstream.example.net",
                 })
        {
            Field(Validator.UpstreamField, url, shouldPass: true);
        }

        foreach (var url in new[]
                 {
                     string.Empty,
                     "   ",
                     "junk",
                     "example.com/path",
                     "http://example.com", // plaintext http is refused at field level.
                     "ftp://example.com",
                     "https:",
                     "https://" + "\r\n" + "more.example.com", // line breaks are refuse-at-entry.
                 })
        {
            Field(Validator.UpstreamField, url, shouldPass: false);
        }
    }

    [Test]
    public static void DnsServersTable()
    {
        foreach (var list in new[]
                 {
                     "1.1.1.1",
                     "1.1.1.1, 8.8.8.8",
                     "2606:4700:4700::1111",
                     "1.1.1.1 2606:4700:4700::1111",
                     "1.1.1.1,8.8.8.8,9.9.9.9,149.112.112.112",
                 })
        {
            Field(Validator.DnsServersField, list, shouldPass: true);
        }

        foreach (var list in new[]
                 {
                     string.Empty,
                     "1.2.3", // partial IPv4 triad.
                     "999.1.1.1", // octet overflow.
                     "1..2.3", // empty octet.
                     "example.com",
                     "1.1.1.1; 8.8.8.8", // semicolons are not separators.
                     "1.1.1.1, 8.8.8.8, 9.9.9.9, 149.112.112.112, 9.9.9.10", // five is too many.
                 })
        {
            Field(Validator.DnsServersField, list, shouldPass: false);
        }
    }

    [Test]
    public static void LanguageEnumTable()
    {
        Field(Validator.LanguageField, "en", shouldPass: true);
        Field(Validator.LanguageField, "vi", shouldPass: true);
        foreach (var language in new[] { string.Empty, "EN", "en-US", "fr" })
        {
            Field(Validator.LanguageField, language, shouldPass: false);
        }
    }

    [Test]
    public static void ModeEnumTable()
    {
        Field(Validator.ModeField, "resetDefaults", shouldPass: true);
        Field(Validator.ModeField, "custom", shouldPass: true);
        Field(Validator.ModeField, "clean", shouldPass: false);
        Field(Validator.ModeField, string.Empty, shouldPass: false);
        Field(Validator.ModeField, "  custom  ", shouldPass: false);
    }

    [Test]
    public static void UnknownFieldsPassThroughToTheEngine()
    {
        Assert.Null(Validator.Validate("not-a-known-field", "anything"));
    }

    [Test]
    public static void ServerListParsingAndStrictIp()
    {
        var parsed = Validator.ParseServerList("a,\tb c\n d");
        Assert.Equal(new[] { "a", "b", "c", "d" }, parsed);

        var empty = Validator.ParseServerList(" , ");
        Assert.Equal(0, empty.Count);

        foreach (var address in new[] { "1.1.1.1", "149.112.112.112", "::1", "2606:4700:4700::1111" })
        {
            Assert.True(Validator.IsStrictIp(address), address + " must parse strictly");
        }

        foreach (var address in new[] { "1.2.3", "256.2.3.4", "1..2.3", "x:x", "not-an-ip" })
        {
            Assert.False(Validator.IsStrictIp(address), address + " must not parse");
        }
    }

    private static void Field(string field, string value, bool shouldPass)
    {
        var error = Validator.Validate(field, value);
        Assert.Equal(shouldPass, error is null);
    }
}
