using System;

internal static class PanelStatusTests
{
    static void Expect(string actual, string expected) { if (actual != expected) throw new Exception("面板状态显示错误"); }
    static int Main()
    {
        Expect(PanelStatus.Label(true, false, false, false, false), "界面预览");
        Expect(PanelStatus.Label(false, false, false, false, false), "正在启动");
        Expect(PanelStatus.Label(false, true, true, true, true), "互联服务需要检查");
        Expect(PanelStatus.Label(false, true, false, false, false), "等待登录小米账号");
        Expect(PanelStatus.Label(false, true, false, true, false), "服务已启动");
        Expect(PanelStatus.Label(false, true, false, true, true), "服务已启动");
        Console.WriteLine("面板状态显示测试通过。");
        return 0;
    }
}
