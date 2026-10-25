using System.IO;

namespace Sedg.Desktop.Services;

/// <summary>Resolves the single installed engine copy; refuses any path that is not the canonical engine.</summary>
public sealed class EngineLocator
{
    public const string InstallDirectory = @"serverless-edge-dns-gateway";

    private readonly string _enginePath;

    public EngineLocator()
        : this(CanonicalEnginePath())
    {
    }

    /// <summary>Test seam only: production code always resolves the canonical path.</summary>
    internal EngineLocator(string enginePath) => _enginePath = enginePath;

    public static string CanonicalEnginePath()
    {
        var systemDrive = Environment.GetEnvironmentVariable("SystemDrive");
        if (string.IsNullOrWhiteSpace(systemDrive))
        {
            systemDrive = "C:";
        }

        if (!systemDrive.EndsWith(@"\", StringComparison.Ordinal))
        {
            systemDrive += @"\";
        }

        return Path.Combine(systemDrive, InstallDirectory, "manager.ps1");
    }

    /// <summary>Returns the canonical engine path when it exists; never a substituted path.</summary>
    public string? Locate()
        => File.Exists(_enginePath) ? _enginePath : null;
}
