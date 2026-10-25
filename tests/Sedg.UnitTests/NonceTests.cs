using Sedg.Broker;

/// <summary>Nonce freshness, the +/-120 s window, malformed nonces, and single use (validator layer).</summary>
public static class NonceTests
{
    private static readonly string HexNonce = "5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a";

    private static bool TryValidate(string? nonce, DateTimeOffset issued, DateTimeOffset expires, out string? error)
    {
        var validator = new NonceValidator();
        return validator.IsValid(nonce, issued, expires, out error);
    }

    [Test]
    public static void FreshWellFormedNonceIsValid()
    {
        var now = DateTimeOffset.UtcNow;
        Assert.True(TryValidate(HexNonce, now.AddSeconds(-10), now.AddSeconds(110), out var error), error);
    }

    [Test]
    public static void IssuedMoreThanOneHundredTwentySecondsInTheFutureIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        Assert.True(!TryValidate(HexNonce, now.AddSeconds(121), now.AddSeconds(130), out var error));
        Assert.True(error!.Contains("future", StringComparison.Ordinal));
    }

    [Test]
    public static void IssuedMoreThanOneHundredTwentySecondsInThePastIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(!validator.TryConsume(HexNonce, now.AddSeconds(-121), now.AddSeconds(-110), out var error));
        Assert.True(error!.Contains("past", StringComparison.Ordinal));
    }

    [Test]
    public static void ExpiryBeyondTheWindowIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(!validator.TryConsume(HexNonce, now.AddSeconds(-10), now.AddSeconds(121), out _));
    }

    [Test]
    public static void ExpiryBeforeIssueIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(!validator.TryConsume(HexNonce, now, now, out var error), error!);
        Assert.True(error!.Contains("after", StringComparison.Ordinal));
    }

    [Test]
    public static void IssueTimeOneHundredTwentyFiveSecondsOldIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(!validator.TryConsume(HexNonce, now.AddSeconds(-125), now.AddSeconds(-121), out var error));
        Assert.True(error!.Contains("past", StringComparison.Ordinal));
    }

    /// <summary>32 bytes encode to 43 base64url characters (one padding '=' trimmed).</summary>
    private static string Base64UrlNonce()
    {
        var bytes = new byte[32];
        for (var index = 0; index < bytes.Length; index++)
        {
            bytes[index] = (byte)(index * 7 + 3);
        }

        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    [Test]
    public static void BaseSixtyFourUrlNoncesAreAccepted()
    {
        var now = DateTimeOffset.UtcNow;
        var nonce = Base64UrlNonce();
        Assert.Equal(43, nonce.Length);
        Assert.True(TryValidate(nonce, now.AddSeconds(-10), now.AddSeconds(110), out var error), error);
    }

    [Test]
    public static void WrongLengthAndNonHexCharactersAreRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var candidates = new List<string?>
        {
            string.Empty,
            "  ",
            "short",
            HexNonce[..63],          // 63 chars
            HexNonce + "ab",         // 66 chars
            "g" + HexNonce[1..],     // 64 chars with a non-hex character
            Base64UrlNonce() + "x",  // 44 chars without the padding the format requires
        };
        foreach (var candidate in candidates)
        {
            Assert.True(!TryValidate(candidate, now.AddSeconds(-10), now.AddSeconds(110), out _), candidate);
        }
    }

    [Test]
    public static void FreshNonceConsumesExactlyOnce()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(validator.TryConsume(HexNonce, now.AddSeconds(-10), now.AddSeconds(110), out var firstError), firstError);
        Assert.True(!validator.TryConsume(HexNonce, now.AddSeconds(-10), now.AddSeconds(110), out var secondError));
        Assert.True(secondError!.Contains("already used", StringComparison.Ordinal));
    }

    [Test]
    public static void DistinctNoncesEachConsumeOnce()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(validator.TryConsume(HexNonce, now.AddSeconds(-10), now.AddSeconds(110), out _));
        const string second = "cccc6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a";
        Assert.True(validator.TryConsume(second, now.AddSeconds(-10), now.AddSeconds(110), out _));
        Assert.True(!validator.TryConsume(second, now.AddSeconds(-10), now.AddSeconds(110), out var error));
        Assert.True(error!.Contains("already used", StringComparison.Ordinal));
    }

    [Test]
    public static void AbsentNonceIsRejected()
    {
        var now = DateTimeOffset.UtcNow;
        var validator = new NonceValidator();
        Assert.True(!validator.TryConsume(null, now.AddSeconds(-10), now.AddSeconds(110), out _));
        Assert.True(!validator.TryConsume(string.Empty, now.AddSeconds(-10), now.AddSeconds(110), out _));
    }
}
