$ErrorActionPreference = 'Stop'
if (-not ('SyncClipboardImageTest' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class SyncClipboardImageTest {
    [DllImport("kernel32")] static extern IntPtr GlobalAlloc(uint f,UIntPtr size);
    [DllImport("kernel32")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32")] static extern IntPtr GlobalFree(IntPtr h);
    [DllImport("user32")] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32")] static extern bool CloseClipboard();
    [DllImport("user32")] static extern bool EmptyClipboard();
    [DllImport("user32")] static extern IntPtr SetClipboardData(uint f,IntPtr h);
    public static void Copy() {
        const int size=96, stride=size*3, pixels=stride*size;
        byte[] dib=new byte[40+pixels];
        using(var stream=new MemoryStream(dib))using(var writer=new BinaryWriter(stream)) {
            writer.Write(40);writer.Write(size);writer.Write(size);writer.Write((short)1);writer.Write((short)24);
            writer.Write(0);writer.Write(pixels);writer.Write(0);writer.Write(0);writer.Write(0);writer.Write(0);
        }
        // DIB rows are bottom-up. Top-left red; top-right green;
        // bottom-left blue; bottom-right yellow. No user image is read.
        for(int y=0;y<size;y++)for(int x=0;x<size;x++) {
            int i=40+y*stride+x*3;
            bool top=y>=size/2,left=x<size/2;
            dib[i]=(byte)(!top&&left?255:0);
            dib[i+1]=(byte)(!left?255:0);
            dib[i+2]=(byte)((top&&left)||(!top&&!left)?255:0);
        }
        IntPtr h=GlobalAlloc(0x42,new UIntPtr((uint)dib.Length));
        if(h==IntPtr.Zero)throw new OutOfMemoryException();
        bool owned=true;
        try {
            IntPtr p=GlobalLock(h);if(p==IntPtr.Zero)throw new InvalidOperationException("无法锁定测试图片内存。");
            Marshal.Copy(dib,0,p,dib.Length);GlobalUnlock(h);
            if(!OpenClipboard(IntPtr.Zero))throw new InvalidOperationException("剪贴板忙，请稍后重试。");
            try{if(!EmptyClipboard()||SetClipboardData(8,h)==IntPtr.Zero)throw new InvalidOperationException("写入测试图片失败。");owned=false;}
            finally{CloseClipboard();}
        } finally {if(owned)GlobalFree(h);}
    }
}
'@
}
[SyncClipboardImageTest]::Copy()
Write-Output '已复制 96×96 红绿蓝黄四格测试图片。'
