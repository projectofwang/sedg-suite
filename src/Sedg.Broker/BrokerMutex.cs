using System.Runtime.InteropServices;
using System.Security.Principal;

namespace Sedg.Broker;

/// <summary>Serializes broker operations via mutex Local\Sedg.Broker (user + Administrators).</summary>
public sealed class BrokerMutex
{
    private const string MutexName = @"Local\Sedg.Broker";
    private const int ErrorAlreadyExists = 183;
    private IntPtr _handle;

    public bool TryEnter()
    {
        if (_handle != IntPtr.Zero)
        {
            return false;
        }

        string? sid;
        try
        {
            sid = WindowsIdentity.GetCurrent().User?.Value;
        }
        catch (Exception)
        {
            return false;
        }

        if (string.IsNullOrEmpty(sid))
        {
            return false;
        }

        var sddl = "D:(A;;GA;;;BA)(A;;GA;;;" + sid + ")";
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out var descriptor, IntPtr.Zero))
        {
            return false;
        }

        try
        {
            var attributes = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                SecurityDescriptor = descriptor,
                InheritHandle = 0,
            };

            var handle = CreateMutexW(ref attributes, initialOwner: false, MutexName);
            if (handle == IntPtr.Zero)
            {
                return false;
            }

            if (Marshal.GetLastWin32Error() == ErrorAlreadyExists)
            {
                CloseHandle(handle);
                return false;
            }

            _handle = handle;
            return true;
        }
        finally
        {
            LocalFree(descriptor);
        }
    }

    public void Exit()
    {
        if (_handle == IntPtr.Zero)
        {
            return;
        }

        CloseHandle(_handle);
        _handle = IntPtr.Zero;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string stringSecurityDescriptor,
        uint stringSdRevision,
        out IntPtr securityDescriptor,
        IntPtr securityDescriptorSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateMutexW(
        ref SecurityAttributes mutexAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool initialOwner,
        string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}
