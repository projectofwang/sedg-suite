using System.IO;
using System.Net.NetworkInformation;

namespace Sedg.Desktop.Services;

/// <summary>Pre-spawn checks: Windows 11 x64 via authoritative APIs, .NET runtime self-check, engine presence; disk/network soft (design §7.1).</summary>
public sealed class Preflight
{
    private const long MinimumFreeBytes = 512L * 1024 * 1024;
    private const int Windows11Build = 22000;

    private readonly EngineLocator _locator;
    private readonly LocalizationManager _localization;

    // Test seams (Task 5 runs on varied hosts); production uses the constructors below.
    private readonly Version? _osVersionOverride;
    private readonly bool? _is64BitOsOverride;
    private readonly bool? _is64BitProcessOverride;
    private readonly bool? _networkUpOverride;
    private readonly long? _freeBytesOverride;
    private readonly string? _editionOverride;
    private readonly bool _enginePathExistsOverride;

    public Preflight(EngineLocator locator, LocalizationManager localization)
        : this(locator, localization, null, null, null, null, null, null, false)
    {
    }

    /// <summary>Test seam only.</summary>
    internal Preflight(
        EngineLocator locator,
        LocalizationManager localization,
        Version? osVersionOverride,
        bool? is64BitOsOverride,
        bool? is64BitProcessOverride,
        bool? networkUpOverride,
        long? freeBytesOverride,
        string? editionOverride,
        bool enginePathExistsOverride)
    {
        _locator = locator;
        _localization = localization;
        _osVersionOverride = osVersionOverride;
        _is64BitOsOverride = is64BitOsOverride;
        _is64BitProcessOverride = is64BitProcessOverride;
        _networkUpOverride = networkUpOverride;
        _freeBytesOverride = freeBytesOverride;
        _editionOverride = editionOverride;
        _enginePathExistsOverride = enginePathExistsOverride;
    }

    public PreflightResult Run()
    {
        var blockers = new List<string>();
        var warnings = new List<string>();

        CheckOs(blockers);
        CheckArchitecture(blockers);
        CheckRuntime(blockers);
        CheckEngine(blockers);
        CheckDisk(warnings);
        CheckNetwork(warnings);
        CheckEdition(warnings);

        return new PreflightResult
        {
            CanProceed = blockers.Count == 0,
            Blockers = blockers.ToArray(),
            Warnings = warnings.ToArray(),
        };
    }

    private void CheckOs(List<string> blockers)
    {
        try
        {
            var version = _osVersionOverride ?? Environment.OSVersion.Version;
            if (version.Major != 10 || version.Build < Windows11Build)
            {
                blockers.Add(_localization.GetString("Preflight_UnsupportedOs"));
                return;
            }
        }
        catch (Exception)
        {
            // Fail closed: an unverifiable OS must not allow privileged mutation.
            blockers.Add(_localization.GetString("Preflight_OsVerificationFailed"));
        }
    }

    private void CheckArchitecture(List<string> blockers)
    {
        var isOs64 = _is64BitOsOverride ?? Environment.Is64BitOperatingSystem;
        var isProcess64 = _is64BitProcessOverride ?? Environment.Is64BitProcess;
        if (!isOs64 || !isProcess64)
        {
            blockers.Add(_localization.GetString("Preflight_RequiresX64"));
        }
    }

    private void CheckRuntime(List<string> blockers)
    {
        try
        {
            // Self-check: the manager runs on .NET 10; if built/published correctly this passes by construction.
            if (!System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription.StartsWith(".NET 10", StringComparison.Ordinal))
            {
                blockers.Add(_localization.GetString("Preflight_RuntimeMissing"));
            }
        }
        catch (Exception)
        {
            blockers.Add(_localization.GetString("Preflight_OsVerificationFailed"));
        }
    }

    private void CheckEngine(List<string> blockers)
    {
        try
        {
            var enginePresent = _enginePathExistsOverride || _locator.Locate() is not null;
            if (!enginePresent)
            {
                blockers.Add(_localization.GetString("Preflight_EngineMissing"));
            }
        }
        catch (Exception)
        {
            blockers.Add(_localization.GetString("Preflight_EngineCheckFailed"));
        }
    }

    private void CheckDisk(List<string> warnings)
    {
        try
        {
            if (_freeBytesOverride is long freeBytes)
            {
                if (freeBytes < MinimumFreeBytes)
                {
                    warnings.Add($"{_localization.GetString("Preflight_DiskLow")} ({freeBytes / (1024 * 1024)} MB).");
                }

                return;
            }

            var enginePath = EngineLocator.CanonicalEnginePath();
            var driveRoot = Path.GetPathRoot(Path.GetDirectoryName(enginePath) ?? enginePath);
            if (string.IsNullOrEmpty(driveRoot))
            {
                return;
            }

            var drive = new DriveInfo(driveRoot);
            if (drive.IsReady && drive.AvailableFreeSpace < MinimumFreeBytes)
            {
                warnings.Add($"{_localization.GetString("Preflight_DiskLow")} ({drive.AvailableFreeSpace / (1024 * 1024)} MB).");
            }
        }
        catch (Exception)
        {
            // Soft check: never blocks; an unverifiable disk state is honest, not a gate.
        }
    }

    private void CheckNetwork(List<string> warnings)
    {
        try
        {
            var networkUp = _networkUpOverride ?? NetworkInterface.GetAllNetworkInterfaces()
                .Any(n => n.OperationalStatus == OperationalStatus.Up
                          && n.NetworkInterfaceType != NetworkInterfaceType.Loopback);
            if (!networkUp)
            {
                warnings.Add(_localization.GetString("Preflight_Offline"));
            }
        }
        catch (Exception)
        {
            // Soft check.
        }
    }

    private void CheckEdition(List<string> warnings)
    {
        try
        {
            var edition = _editionOverride ?? ReadEditionId();
            if (!string.IsNullOrWhiteSpace(edition))
            {
                // Informational only: EditionID is a warning, never a hard gate (task behaviour 10).
                warnings.Add($"{_localization.GetString("Preflight_Edition")} {edition}");
            }
        }
        catch (Exception)
        {
            // Soft check.
        }
    }

    /// <summary>Reads EditionID from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion (read-only; never the legacy ProductName string).</summary>
    private static string? ReadEditionId()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
        return key?.GetValue("EditionID") as string;
    }
}

public sealed class PreflightResult
{
    public bool CanProceed { get; init; }

    public string[] Blockers { get; init; } = Array.Empty<string>();

    public string[] Warnings { get; init; } = Array.Empty<string>();
}
