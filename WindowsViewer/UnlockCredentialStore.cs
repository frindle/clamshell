using System.Runtime.InteropServices;
using System.Text;

namespace Clamshell;

/// <summary>The Mac account for "Unlock disk", kept only when the user ticks
/// "Save on this device": in Windows Credential Manager, which protects it with the
/// signed-in user's DPAPI key. The user name is the credential's user field, the
/// password its blob. The password is never logged.</summary>
internal static class UnlockCredentialStore
{
    private const string Target = "Clamshell/UnlockDisk";
    private const uint TypeGeneric = 1;
    private const uint PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static void Save(string username, string password)
    {
        var blob = Encoding.Unicode.GetBytes(password);
        var handle = GCHandle.Alloc(blob, GCHandleType.Pinned);
        try
        {
            var cred = new CREDENTIAL
            {
                Type = TypeGeneric, TargetName = Target, UserName = username,
                CredentialBlobSize = (uint)blob.Length, CredentialBlob = handle.AddrOfPinnedObject(),
                Persist = PersistLocalMachine,
            };
            if (!CredWrite(ref cred, 0)) throw new InvalidOperationException("Credential Manager refused the save.");
        }
        finally { Array.Clear(blob); handle.Free(); }
    }

    public static (string Username, string Password)? Load()
    {
        if (!CredRead(Target, TypeGeneric, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            var blob = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, blob, 0, blob.Length);
            var password = Encoding.Unicode.GetString(blob);
            Array.Clear(blob);
            return (cred.UserName, password);
        }
        finally { CredFree(ptr); }
    }

    public static void Forget() => CredDelete(Target, TypeGeneric, 0);
}
