using System.IO;
using System.Text.RegularExpressions;

namespace Sedg.Desktop.Services;

/// <summary>
/// Local-only structured log with redaction and size-capped rotation (BCL only).
/// Never writes to the engine install tree; a logging failure never breaks an operation (design §6.2/§7.5).
/// </summary>
public sealed partial class AppLog
{
    private const long MaxLogBytes = 10 * 1024 * 1024;
    private const int MaxRotations = 5;

    private readonly string _baseDirectory;
    private readonly Func<DateTimeOffset>? _clock;
    private readonly object _gate = new();

    public AppLog()
        : this(baseDirectory: null, clock: null)
    {
    }

    /// <summary>Test seam only: production code uses %LOCALAPPDATA%\SedgManager.</summary>
    internal AppLog(string? baseDirectory, Func<DateTimeOffset>? clock)
    {
        _baseDirectory = baseDirectory
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SedgManager");
        _clock = clock;
    }

    public string BaseDirectory => _baseDirectory;

    public string LogDirectory => Path.Combine(_baseDirectory, "logs");

    public string OperationsLogPath => Path.Combine(_baseDirectory, "operations.jsonl");

    public void Write(string level, string message)
    {
        try
        {
            var writeTime = _clock?.Invoke() ?? DateTimeOffset.Now;
            lock (_gate)
            {
                Directory.CreateDirectory(LogDirectory);
                var path = Path.Combine(LogDirectory, $"app-{writeTime:yyyyMMdd}.log");
                RotateIfFull(path);
                var line = $"{writeTime:yyyy-MM-dd HH:mm:ss.fffzzz} [{JsonEscape(level)}] {Redact(message)}"
                           + Environment.NewLine;
                File.AppendAllText(path, line);
            }
        }
        catch (Exception)
        {
            // Swallowed by design: a logging failure must never break an operation.
        }
    }

    /// <summary>Writes one timestamped operation record line to operations.jsonl (one line per record; replayed/late terminal records reuse operationId).</summary>
    public void WriteOperation(
        string operationId,
        string action,
        DateTimeOffset startedUtc,
        DateTimeOffset endedUtc,
        bool ok,
        string code,
        string? message,
        string? transcriptPath,
        bool lateCompletion = false)
    {
        try
        {
            var record = System.Text.Json.JsonSerializer.Serialize(
                new OperationRecord(
                    JsonEscape(operationId),
                    JsonEscape(action),
                    startedUtc.ToString("o", System.Globalization.CultureInfo.InvariantCulture),
                    endedUtc.ToString("o", System.Globalization.CultureInfo.InvariantCulture),
                    ok,
                    JsonEscape(code),
                    Redact(message),
                    transcriptPath is null ? null : Redact(transcriptPath),
                    lateCompletion));
            lock (_gate)
            {
                Directory.CreateDirectory(_baseDirectory);
                File.AppendAllText(OperationsLogPath, record + Environment.NewLine);
            }
        }
        catch (Exception)
        {
            // Swallowed by design.
        }
    }

    /// <summary>Reads the non-empty operations.jsonl lines that carry the operation id, for the Copy details affordance.</summary>
    public string? ReadOperationLines(string operationId)
    {
        try
        {
            if (!File.Exists(OperationsLogPath))
            {
                return null;
            }

            var lines = File.ReadLines(OperationsLogPath)
                .Where(line => line.Contains(JsonEscape(operationId), StringComparison.Ordinal))
                .ToList();
            return lines.Count == 0 ? null : string.Join(Environment.NewLine, lines);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string JsonEscape(string value) => value.Replace("\\", "\\\\").Replace("\"", "\\\"");

    /// <summary>Rotates app-yyyyMMdd.log at the 10 MB cap across at most five rotations; failures are swallowed.</summary>
    private void RotateIfFull(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < MaxLogBytes)
            {
                return;
            }

            var oldest = path[..^".log".Length] + "-" + MaxRotations + ".log";
            File.Delete(oldest);
            for (var index = MaxRotations - 1; index >= 1; index--)
            {
                var from = path[..^".log".Length] + "-" + index + ".log";
                var to = path[..^".log".Length] + "-" + (index + 1) + ".log";
                if (File.Exists(from))
                {
                    File.Move(from, to, overwrite: true);
                }
            }

            File.Move(path, path[..^".log".Length] + "-1.log", overwrite: true);
        }
        catch (Exception)
        {
            // Swallowed by design.
        }
    }

    /// <summary>
    /// Redacts nonce-shaped values, pipe-name tails, and URL userinfo before anything is written (BR-14).
    /// </summary>
    internal static string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        var redacted = text;

        // URL userinfo: scheme://user:pass@... -> scheme://***@...
        redacted = UserInfoRegex().Replace(redacted, "$1***@");

        // 256-bit nonces and pipe-name tails: every 64-hex run is a nonce-shaped secret.
        redacted = NonceRegex().Replace(redacted, "***");

        return redacted;
    }

    [GeneratedRegex(@"([a-zA-Z][a-zA-Z0-9+.\-]*://)[^\s/]*@")]
    private static partial Regex UserInfoRegex();

    [GeneratedRegex(@"[0-9a-fA-F]{64}")]
    private static partial Regex NonceRegex();

    /// <summary>Opens a file in Explorer (select) or a directory in Explorer; failures are swallowed. Service-owned so view models never spawn processes.</summary>
    public void OpenInExplorer(string path)
    {
        try
        {
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                return;
            }

            if (File.Exists(path))
            {
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = $"/select,\"{path}\"",
                        UseShellExecute = true,
                    });
            }
            else
            {
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = $"\"{path}\"",
                        UseShellExecute = true,
                    });
            }
        }
        catch (Exception)
        {
            // Swallowed by design.
        }
    }

    public void CopyToClipboard(string? text)
    {
        try
        {
            if (string.IsNullOrEmpty(text))
            {
                return;
            }

            System.Windows.Clipboard.SetText(text);
        }
        catch (Exception)
        {
            // Clipboard can be locked by another process; never break the operation.
        }
    }

    public sealed record OperationRecord(
        string operationId,
        string action,
        string startedUtc,
        string endedUtc,
        bool ok,
        string code,
        string? message,
        string? transcriptPath,
        bool lateCompletion);
}
