using System.IO;
using System.Security;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Sedg.Broker;

/// <summary>Hardcodes C:\serverless-edge-dns-gateway\manager.ps1 and validates ACL/ownership before use.</summary>
public sealed class EnginePathValidator
{
    public const string EnginePath = @"C:\serverless-edge-dns-gateway\manager.ps1";

    private const string SystemSid = "S-1-5-18";
    private const string AdministratorsSid = "S-1-5-32-544";
    private const string TrustedInstallerSid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

    private const FileSystemRights WriteRights =
        FileSystemRights.WriteData
        | FileSystemRights.AppendData
        | FileSystemRights.WriteExtendedAttributes
        | FileSystemRights.WriteAttributes
        | FileSystemRights.Delete
        | FileSystemRights.DeleteSubdirectoriesAndFiles
        | FileSystemRights.ChangePermissions
        | FileSystemRights.TakeOwnership
        | (FileSystemRights)0x40000000 // GENERIC_WRITE, in case an ACE carries the generic bit
        | (FileSystemRights)0x10000000; // GENERIC_ALL

    private readonly string _enginePath;

    public EnginePathValidator() : this(EnginePath)
    {
    }

    internal EnginePathValidator(string enginePath) => _enginePath = enginePath;

    public bool Validate(out string? error)
    {
        try
        {
            if (!Path.IsPathFullyQualified(_enginePath))
            {
                error = "The engine path is not absolute.";
                return false;
            }

            if (!File.Exists(_enginePath))
            {
                error = "The engine was not found at " + _enginePath + ".";
                return false;
            }

            if ((File.GetAttributes(_enginePath) & FileAttributes.ReparsePoint) != 0)
            {
                error = "The engine file is a reparse point.";
                return false;
            }

            for (var directory = Directory.GetParent(_enginePath); directory is not null; directory = directory.Parent)
            {
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    error = "The engine path traverses a reparse point at " + directory.FullName + ".";
                    return false;
                }
            }

            if (!ValidateAcl(_enginePath, "engine file", out error))
            {
                return false;
            }

            var parent = Directory.GetParent(_enginePath);
            if (parent is null)
            {
                error = "The engine has no parent directory.";
                return false;
            }

            if (!ValidateAcl(parent.FullName, "engine directory", out error))
            {
                return false;
            }

            error = null;
            return true;
        }
        catch (Exception exception) when (exception is IOException
                                              or UnauthorizedAccessException
                                              or SecurityException
                                              or ArgumentException
                                              or NotSupportedException)
        {
            error = "The engine path could not be validated: " + exception.Message;
            return false;
        }
    }

    private static bool ValidateAcl(string path, string label, out string? error)
    {
        FileSystemSecurity security = Directory.Exists(path)
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access)
            : new FileInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);

        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !IsTrusted(owner))
        {
            error = "The " + label + " is not owned by SYSTEM, Administrators, or TrustedInstaller.";
            return false;
        }

        var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        if (raw.DiscretionaryAcl is null)
        {
            error = "The " + label + " has no discretionary ACL.";
            return false;
        }

        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     targetType: typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow
                || (rule.FileSystemRights & WriteRights) == 0)
            {
                continue;
            }

            if (rule.IdentityReference is SecurityIdentifier sid && IsTrusted(sid))
            {
                continue;
            }

            error = "The " + label + " grants write access to untrusted principal '"
                    + rule.IdentityReference.Value + "'.";
            return false;
        }

        error = null;
        return true;
    }

    private static bool IsTrusted(SecurityIdentifier sid)
        => sid.Value is SystemSid or AdministratorsSid or TrustedInstallerSid;
}
