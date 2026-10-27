param([string]$ExpectedText, [switch]$ResolveImage)
$ErrorActionPreference = 'Stop'
if (-not ('SyncClipboardContentCheck' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyncClipboardContentCheck {
    [DllImport("user32")] public static extern bool IsClipboardFormatAvailable(uint f);
    [DllImport("user32")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32")] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32")] static extern bool CloseClipboard();
    [DllImport("user32")] static extern IntPtr GetClipboardData(uint f);
    [DllImport("kernel32")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32")] static extern UIntPtr GlobalSize(IntPtr h);
    public static string ImageInfo() {
        if(!OpenClipboard(IntPtr.Zero))throw new InvalidOperationException("剪贴板忙，请稍后重试。");
        try {
            IntPtr h=GetClipboardData(8);if(h==IntPtr.Zero)h=GetClipboardData(17);
            if(h==IntPtr.Zero)return "DIB_UNAVAILABLE";
            ulong bytes=GlobalSize(h).ToUInt64();
            IntPtr p=GlobalLock(h);if(p==IntPtr.Zero)return "DIB_LOCK_FAILED";
            try {
                int header=Marshal.ReadInt32(p),width=0,height=0;
                if(bytes>=40 && header>=40){width=Marshal.ReadInt32(p,4);height=Marshal.ReadInt32(p,8);}
                else if(bytes>=12 && header==12){width=(ushort)Marshal.ReadInt16(p,4);height=(ushort)Marshal.ReadInt16(p,6);}
                return "width="+width+" height="+Math.Abs(height)+" dib_bytes="+bytes;
            }finally{GlobalUnlock(h);}
        }finally{CloseClipboard();}
    }
    public static bool Matches(string expected) {
        if (!OpenClipboard(IntPtr.Zero)) throw new InvalidOperationException("剪贴板忙，请稍后重试。");
        try {
            IntPtr h=GetClipboardData(13);
            if(h==IntPtr.Zero)return false;
            IntPtr p=GlobalLock(h);
            if(p==IntPtr.Zero)return false;
            try{return string.Equals(Marshal.PtrToStringUni(p),expected,StringComparison.Ordinal);}
            finally{GlobalUnlock(h);}
        } finally{CloseClipboard();}
    }
}
'@
}
$taskHasImage = [SyncClipboardContentCheck]::IsClipboardFormatAvailable(2) -or [SyncClipboardContentCheck]::IsClipboardFormatAvailable(8) -or [SyncClipboardContentCheck]::IsClipboardFormatAvailable(17)
$taskMatch = $null
if ($PSBoundParameters.ContainsKey('ExpectedText')) { $taskMatch = [SyncClipboardContentCheck]::Matches($ExpectedText) }
$taskImageInfo = $null
if ($ResolveImage) { $taskImageInfo = [SyncClipboardContentCheck]::ImageInfo() }
[pscustomobject]@{
    Sequence = [SyncClipboardContentCheck]::GetClipboardSequenceNumber()
    TextAvailable = [SyncClipboardContentCheck]::IsClipboardFormatAvailable(13)
    ImageAvailable = $taskHasImage
    ExpectedTextMatches = $taskMatch
    ImageData = $taskImageInfo
}
