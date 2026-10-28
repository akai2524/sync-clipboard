$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LightClipServiceSecurity {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
    private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
    private static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
    private static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
    private static extern bool QueryServiceObjectSecurity(IntPtr service, uint info, IntPtr buffer, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
    private static extern bool SetServiceObjectSecurity(IntPtr service, uint info, IntPtr descriptor);

    private static IntPtr Open(string name, uint access, out IntPtr manager) {
        manager = OpenSCManagerW(null, null, 1);
        if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr service = OpenServiceW(manager, name, access);
        if (service == IntPtr.Zero) {
            int code = Marshal.GetLastWin32Error(); CloseServiceHandle(manager); manager = IntPtr.Zero;
            throw new Win32Exception(code);
        }
        return service;
    }
    public static int CheckStop(string name) {
        IntPtr manager = IntPtr.Zero;
        try { IntPtr service = Open(name, 32, out manager); CloseServiceHandle(service); return 0; }
        catch (Win32Exception error) { return error.NativeErrorCode; }
        finally { if (manager != IntPtr.Zero) CloseServiceHandle(manager); }
    }
    public static byte[] ReadDacl(string name) {
        IntPtr manager; IntPtr service = Open(name, 0x20000, out manager);
        try {
            uint needed = 0; IntPtr dummy = Marshal.AllocHGlobal(1);
            try {
                bool first = QueryServiceObjectSecurity(service, 4, dummy, 0, out needed);
                int error = Marshal.GetLastWin32Error();
                if ((!first && error != 122) || needed == 0 || needed > 65536) throw new Win32Exception(error);
            } finally { Marshal.FreeHGlobal(dummy); }
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            try {
                uint written;
                if (!QueryServiceObjectSecurity(service, 4, buffer, needed, out written)) throw new Win32Exception(Marshal.GetLastWin32Error());
                byte[] bytes = new byte[needed]; Marshal.Copy(buffer, bytes, 0, bytes.Length); return bytes;
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { CloseServiceHandle(service); CloseServiceHandle(manager); }
    }
    public static void WriteDacl(string name, byte[] descriptor) {
        if (descriptor == null || descriptor.Length == 0 || descriptor.Length > 65536) throw new ArgumentException("Invalid descriptor");
        IntPtr manager; IntPtr service = Open(name, 0x40000, out manager);
        try {
            IntPtr buffer = Marshal.AllocHGlobal(descriptor.Length);
            try {
                Marshal.Copy(descriptor, 0, buffer, descriptor.Length);
                if (!SetServiceObjectSecurity(service, 4, buffer)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { CloseServiceHandle(service); CloseServiceHandle(manager); }
    }
}
'@

function Get-StopEnabledDescriptor([byte[]]$Original, [string]$UserSid) {
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Original, 0)
    $acl = $descriptor.DiscretionaryAcl
    if ($null -eq $acl) { throw '服务权限结构不符合预期，未修改权限。' }
    $changed = 0
    for ($i = $acl.Count - 1; $i -ge 0; $i--) {
        $ace = $acl[$i]
        if ($ace -is [Security.AccessControl.CommonAce] -and
            $ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied -and
            (([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -eq 0) -and
            $ace.SecurityIdentifier.Value -eq 'S-1-1-0' -and ($ace.AccessMask -band 32) -ne 0) {
            $mask = $ace.AccessMask -band (-bnot 32)
            $acl.RemoveAce($i)
            if ($mask -ne 0) {
                $newAce = [Security.AccessControl.CommonAce]::new($ace.AceFlags, $ace.AceQualifier, $mask, $ace.SecurityIdentifier, $ace.IsCallback, $ace.GetOpaque())
                $acl.InsertAce($i, $newAce)
            }
            $changed++
        }
    }
    if ($changed -eq 0) { throw '未发现可确认的停止权限限制，未修改服务权限。' }
    $position = 0
    for ($i = 0; $i -lt $acl.Count; $i++) {
        $ace = $acl[$i]
        if ($ace -is [Security.AccessControl.QualifiedAce] -and $ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied -and
            (([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -eq 0)) { $position = $i + 1 }
    }
    $identity = [Security.Principal.SecurityIdentifier]::new($UserSid)
    $allow = [Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None, [Security.AccessControl.AceQualifier]::AccessAllowed, 32, $identity, $false, $null)
    $acl.InsertAce($position, $allow)
    $bytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes, 0)
    return ,$bytes
}

function Get-DaclText([byte[]]$Descriptor) {
    return ([Security.AccessControl.RawSecurityDescriptor]::new($Descriptor, 0)).GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
}

function Invoke-TemporaryServiceDacl([string]$Snapshot, [byte[]]$Original, [byte[]]$Temporary, [scriptblock]$Set, [scriptblock]$Read, [scriptblock]$Action) {
    $stream = New-Object IO.FileStream($Snapshot, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($Original, 0, $Original.Length); $stream.Flush() } finally { $stream.Dispose() }
    try {
        & $Set $Temporary
        & $Action
    } finally {
        try {
            & $Set $Original
            $restored = & $Read
            if ((Get-DaclText $restored) -ne (Get-DaclText $Original)) { throw '服务权限校验不一致。' }
            Remove-Item -LiteralPath $Snapshot -Force -ErrorAction Stop
        } catch { throw '服务权限恢复未完成，已保留权限恢复记录；请重新运行清理工具并提供提示。' }
    }
}
