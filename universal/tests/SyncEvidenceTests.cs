using System;

internal static class SyncEvidenceTests
{
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static int Main()
    {
        SyncEvidence evidence = new SyncEvidence();
        Assert(!evidence.RecordProgress(0, 0) && !evidence.Complete, "空进度不能证明传输完成");
        Assert(!evidence.RecordProgress(100, 99) && !evidence.Complete, "未完成的进度不能证明成功");
        Assert(!evidence.RecordProgress(100, 101) && !evidence.Complete, "异常进度不能证明成功");
        Assert(evidence.RecordProgress(100, 100) && evidence.Complete, "完整传输未被记录");
        Assert(!evidence.RecordProgress(100, 100), "重复回调不应重复触发状态变化");
        evidence.Reset();
        Assert(!evidence.Complete, "断开后验证状态未清除");
        Console.WriteLine("剪贴板传输证据测试通过。");
        return 0;
    }
}
