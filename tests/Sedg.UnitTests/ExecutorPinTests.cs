using System.Diagnostics;
using Sedg.Broker;
using Sedg.Desktop.Services;
using Sedg.Protocol;

/// <summary>
/// The gateway engine is one copy at one path, run through one pinned interpreter; path validation
/// proves the pin without executing anything (fakes never spawn a real process).
/// </summary>
public static class ExecutorPinTests
{
    [Test]
    public static void EnginePathIsTheHardcodedCanonicalCopy()
    {
        Assert.Equal("C:\\serverless-edge-dns-gateway\\manager.ps1", EnginePathValidator.EnginePath);
        Assert.Equal("serverless-edge-dns-gateway", EngineLocator.InstallDirectory);

        var canonical = EngineLocator.CanonicalEnginePath();
        Assert.True(
            canonical.EndsWith("\\serverless-edge-dns-gateway\\manager.ps1", StringComparison.Ordinal),
            canonical + " is not the canonical engine location");
        Assert.True(Path.IsPathFullyQualified(canonical));
    }

    [Test]
    public static void TheEngineRunsThroughPinnedPowerShellOnly()
    {
        ProcessStartInfo? captured = null;
        var executor = new ActionExecutor(
            EnginePathValidator.EnginePath,
            validateEnginePath: false,
            startProcess: startInfo =>
            {
                captured = startInfo;
                return null; // Fake launch: no engine, no interpreter, no machine mutation.
            });

        var request = new ProtocolRequest
        {
            Action = ProtocolAction.Status,
            OperationId = Guid.NewGuid().ToString("D"),
            Args = new System.Text.Json.Nodes.JsonObject(),
        };
        var response = executor.Execute(request, progress: null);

        var startInfo = captured;
        Assert.NotNull(startInfo);
        Assert.False(startInfo!.UseShellExecute);
        Assert.True(
            Path.GetFileName(startInfo.FileName).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase),
            startInfo.FileName + " is not the pinned interpreter");
        Assert.True(
            startInfo.FileName.EndsWith("\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", StringComparison.OrdinalIgnoreCase),
            startInfo.FileName + " is not the System32 pinned interpreter");

        var arguments = startInfo.ArgumentList.ToArray();
        string[] pinned =
        {
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            EnginePathValidator.EnginePath,
            "-Protocol",
            "jsonl",
        };
        Assert.Equal(pinned, arguments);
        Assert.Equal(Path.GetDirectoryName(EnginePathValidator.EnginePath), startInfo.WorkingDirectory);

        // The fake never started the engine, so the response is the answered spawn error and no input
        // line ever reached a child process.
        Assert.False(response.Ok!.Value);
        Assert.Equal(ErrorCode.EngineSpawn, response.Code);
        Assert.True(
            response.Message!.Contains("could not be started", StringComparison.Ordinal),
            response.Message);
    }

    [Test]
    public static void PathValidationRejectsUserOwnedAndMissingLocations()
    {
        var tempDirectory = Support.NewTempDirectory();
        try
        {
            var userOwned = Path.Combine(tempDirectory, "manager.ps1");
            File.WriteAllText(userOwned, "param() exit\n");

            Assert.False(new EnginePathValidator(userOwned).Validate(out var aclError));
            Assert.NotNull(aclError);

            var missing = Path.Combine(tempDirectory, "absent", "manager.ps1");
            Assert.False(new EnginePathValidator(missing).Validate(out var missingError));
            Assert.True(
                missingError!.Contains("not found", StringComparison.Ordinal),
                missingError);
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }
}
