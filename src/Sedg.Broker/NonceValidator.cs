using System.Security.Cryptography;

namespace Sedg.Broker;

/// <summary>Validates nonce presence/format and issuedUtc/expiresUtc window (+/-120 s).</summary>
public sealed class NonceValidator
{
    private static readonly TimeSpan Window = TimeSpan.FromSeconds(120);
    private readonly HashSet<string> _consumed = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public bool IsValid(string? nonce, DateTimeOffset issuedUtc, DateTimeOffset expiresUtc, out string? error)
    {
        if (!TryDecode(nonce, out _))
        {
            error = "The broker nonce must be a 256-bit URL-safe hex or base64url value.";
            return false;
        }

        if (expiresUtc <= issuedUtc)
        {
            error = "The nonce expiry must be after its issue time.";
            return false;
        }

        var now = DateTimeOffset.UtcNow;
        if (issuedUtc > now + Window)
        {
            error = "The nonce issue time is more than 120 s in the future.";
            return false;
        }

        if (issuedUtc < now - Window)
        {
            error = "The nonce issue time is more than 120 s in the past.";
            return false;
        }

        if (expiresUtc > now + Window)
        {
            error = "The nonce expiry is more than 120 s in the future.";
            return false;
        }

        if (expiresUtc < now - Window)
        {
            error = "The nonce expired more than 120 s ago.";
            return false;
        }

        error = null;
        return true;
    }

    /// <summary>Validates and consumes a nonce for a handshake; a second call with the same nonce fails.</summary>
    public bool TryConsume(string? nonce, DateTimeOffset issuedUtc, DateTimeOffset expiresUtc, out string? error)
    {
        if (!IsValid(nonce, issuedUtc, expiresUtc, out error))
        {
            return false;
        }

        if (!TryDecode(nonce, out var bytes))
        {
            error = "The broker nonce is invalid.";
            return false;
        }

        var key = Convert.ToHexString(bytes);
        lock (_gate)
        {
            if (!_consumed.Add(key))
            {
                error = "The broker nonce was already used.";
                return false;
            }
        }

        error = null;
        return true;
    }

    internal static bool NonceEquals(string? left, string? right)
    {
        if (!TryDecode(left, out var leftBytes) || !TryDecode(right, out var rightBytes))
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    internal static bool TryDecode(string? nonce, out byte[] bytes)
    {
        bytes = Array.Empty<byte>();
        if (string.IsNullOrWhiteSpace(nonce))
        {
            return false;
        }

        if (nonce.Length == 64)
        {
            foreach (var character in nonce)
            {
                if (!Uri.IsHexDigit(character))
                {
                    return false;
                }
            }

            bytes = Convert.FromHexString(nonce);
            return bytes.Length == 32;
        }

        if (nonce.Length is 43 or 44)
        {
            var padded = nonce;
            if (nonce.Length == 44)
            {
                if (nonce[43] != '=')
                {
                    return false;
                }

                padded = nonce[..43];
            }

            foreach (var character in padded)
            {
                if (!char.IsAsciiLetterOrDigit(character) && character is not ('-' or '_'))
                {
                    return false;
                }
            }

            var base64 = padded.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(base64.Length + ((4 - (base64.Length % 4)) % 4), '=');
            try
            {
                bytes = Convert.FromBase64String(base64);
            }
            catch (FormatException)
            {
                return false;
            }

            return bytes.Length == 32;
        }

        return false;
    }
}
