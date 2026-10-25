using Sedg.Desktop.Services;
using Sedg.Protocol;

/// <summary>Local log hygiene: redaction before write, one operations line per terminal, rotation, swallow.</summary>
public static class AppLogTests
{
    private const string HexNonce = "5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a5ccf6e9d33cb261a";

    [Test]
    public static void RedactionCoversNoncesPipeTailsAndUrlUserinfo()
    {
        Assert.Equal("signed=***", AppLog.Redact("signed=" + HexNonce));
        Assert.Equal(
            "Sedg.Broker.S-1-5-21.***",
            AppLog.Redact("Sedg.Broker.S-1-5-21." + HexNonce));
        Assert.Equal(
            "upstream https://***@edge.example.net/path is set",
            AppLog.Redact("upstream https://user:s3cret@edge.example.net/path is set"));
        Assert.Equal("harmless text stays readable", AppLog.Redact("harmless text stays readable"));
        Assert.Equal(string.Empty, AppLog.Redact(string.Empty));
        Assert.Equal(string.Empty, AppLog.Redact(null));
    }

    [Test]
    public static void WriteEmitsOneTimestampedAndRedactedLine()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var appLog = Support.NewAppLog(tempDirectory);
            appLog.Write("warn", "the broker nonce " + HexNonce + " was rejected");

            var logPath = Path.Combine(appLog.LogDirectory, "app-20260101.log");
            Assert.True(File.Exists(logPath), "the daily app log must exist");
            var line = File.ReadAllText(logPath).TrimEnd('\r', '\n');
            Assert.False(line.Contains(HexNonce, StringComparison.Ordinal), "a nonce must never reach disk");
            Assert.True(line.Contains("the broker nonce *** was rejected", StringComparison.Ordinal), line);
            Assert.True(line.Contains("[warn]", StringComparison.Ordinal), line);
            Assert.True(line.Contains("2026-01-01 12:00:00", StringComparison.Ordinal), line);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void OneOperationsLineRecordsEachTerminal()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var appLog = Support.NewAppLog(tempDirectory);
            var started = new DateTimeOffset(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

            appLog.WriteOperation(
                "op-1", "status", started, started, ok: true, "None",
                "finished with nonce " + HexNonce, transcriptPath: null);
            appLog.WriteOperation(
                "op-1", "restart", started.AddSeconds(30), started.AddSeconds(40), ok: false,
                "EngineSpawn", "spawn failed", transcriptPath: "C:\\transcripts\\t.txt",
                lateCompletion: true);

            var lines = File.ReadAllLines(appLog.OperationsLogPath);
            Assert.Equal(2, lines.Length);
            Assert.True(lines[0].Contains("\"operationId\":\"op-1\"", StringComparison.Ordinal), lines[0]);
            Assert.True(lines[0].Contains("\"action\":\"status\"", StringComparison.Ordinal), lines[0]);
            Assert.False(lines[0].Contains(HexNonce, StringComparison.Ordinal), lines[0]);
            Assert.True(
                lines[0].Contains("finished with nonce ***", StringComparison.Ordinal),
                lines[0]);
            Assert.True(lines[0].Contains("\"lateCompletion\":false", StringComparison.Ordinal), lines[0]);
            Assert.True(lines[1].Contains("\"lateCompletion\":true", StringComparison.Ordinal), lines[1]);
            Assert.True(lines[1].Contains("\"ok\":false", StringComparison.Ordinal), lines[1]);
            Assert.True(lines[1].Contains("2026-01-01T12:00:40", StringComparison.Ordinal), lines[1]);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void RotationKeepsAtMostFiveRotatedFiles()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var appLog = Support.NewAppLog(tempDirectory);
            Directory.CreateDirectory(appLog.LogDirectory);
            var currentPath = Path.Combine(appLog.LogDirectory, "app-20260101.log");
            var oldestRotated = Path.Combine(appLog.LogDirectory, "app-20260101-5.log");

            // A full log plus an already-full rotation history: rotation must delete the -5 slot,
            // move the old current to -1, and open a fresh daily file for the new line.
            var oldCurrent = new string('x', 10_499_980) + "old-current-marker";
            File.WriteAllText(currentPath, oldCurrent);
            File.WriteAllText(oldestRotated, "stale-but-full history");

            appLog.Write("info", "new line");

            Assert.True(File.Exists(currentPath), "a fresh daily file opens after rotation");
            Assert.True(File.Exists(Path.Combine(appLog.LogDirectory, "app-20260101-1.log")), "the old log rotates to -1");
            Assert.True(!File.Exists(oldestRotated), "the fifth rotation slot is deleted, never grown");

            var fresh = File.ReadAllText(currentPath);
            Assert.True(fresh.Contains("new line", StringComparison.Ordinal), fresh);
            var rotated = File.ReadAllText(Path.Combine(appLog.LogDirectory, "app-20260101-1.log"));
            Assert.True(rotated.Contains("old-current-marker", StringComparison.Ordinal), "the old current content survives the shift to -1");
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    [Test]
    public static void ALoggingFailureNeverBreaksTheOperation()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var blockerPath = Path.Combine(tempDirectory, "blocker");
            File.WriteAllText(blockerPath, "a file occupies the would-be directory path");

            // The base path is a file, so every internal write fails; a failure must be swallowed.
            var appLog = new AppLog(blockerPath, () => DateTimeOffset.Parse(
                "2026-01-01T12:00:00Z", CultureInfo.InvariantCulture));
            appLog.Write("info", "never lands");
            appLog.WriteOperation(
                "op-2", "status", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, ok: true,
                "None", "logged nowhere", transcriptPath: null);

            Assert.True(true);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }
}
