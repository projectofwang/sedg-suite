using Sedg.Desktop.Services;
using Sedg.Protocol;

/// <summary>EN/VI parity, error-code titles, and settings.json language persistence.</summary>
public static class LocalizationTests
{
    /// <summary>Localization bound to the real Sedg.Desktop resource assembly, not the harness's.</summary>
    private static LocalizationManager NewRealLocalization(string settingsDirectory)
        => new(settingsDirectory, typeof(Validator).Assembly);

    [Test]
    public static void EnAndViParityHolds()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var localization = NewRealLocalization(tempDirectory);
            Assert.Equal(0, localization.VerifyParity().Count);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void EveryErrorCodeHasANonEmptyTitleInBothLanguages()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var localization = NewRealLocalization(tempDirectory);
            var codes = 0;
            foreach (var code in Enum.GetValues<ErrorCode>())
            {
                if (code == ErrorCode.None)
                {
                    continue;
                }

                codes++;
                var key = LocalizationManager.ErrorTitleKey(code);
                foreach (var language in new[] { "en", "vi" })
                {
                    var title = localization.GetString(key, language);
                    Assert.True(title.Length > 0, key + " (" + language + ") is empty");
                    Assert.True(
                        title != "<" + key + ">",
                        key + " (" + language + ") is missing from the resources");
                }
            }

            Assert.True(codes >= 20, "the closed error vocabulary has at least 20 members");
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void LanguagePersistsToSettingsJsonAcrossReread()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var localization = Support.NewLocalization(tempDirectory + "\\loc");
            Assert.True(localization.IsLanguageUnset);
            Assert.True(!File.Exists(localization.SettingsFilePath));

            localization.SetLanguage("vi");
            Assert.Equal("vi", localization.CurrentLanguage);
            Assert.True(File.Exists(localization.SettingsFilePath));
            Assert.True(
                File.ReadAllText(localization.SettingsFilePath).Contains("vi", StringComparison.Ordinal),
                "settings.json must record the chosen language");

            var reloaded = Support.NewLocalization(tempDirectory + "\\loc");
            Assert.Equal("vi", reloaded.CurrentLanguage);
            Assert.False(reloaded.IsLanguageUnset);

            reloaded.SetLanguage("en");
            var reloadedAgain = Support.NewLocalization(tempDirectory + "\\loc");
            Assert.Equal("en", reloadedAgain.CurrentLanguage);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void UnsupportedLanguagesAreRejected()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var localization = Support.NewLocalization(tempDirectory + "\\loc");
            foreach (var language in new[] { "fr", string.Empty, "english", "EN" })
            {
                var thrown = Assert.Throws<ArgumentOutOfRangeException>(
                    () => localization.SetLanguage(language));
                Assert.True(thrown.Message.Contains("en", StringComparison.Ordinal), thrown.Message);
            }

            Assert.True(localization.IsLanguageUnset, "a rejected language must not persist");
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }
}
