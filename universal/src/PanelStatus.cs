internal static class PanelStatus
{
    internal static string Label(bool preview, bool ready, bool serviceProblem, bool loggedIn, bool verified)
    {
        if (preview) return "界面预览";
        if (!ready) return "正在启动";
        if (serviceProblem) return "互联服务需要检查";
        if (!loggedIn) return "等待登录小米账号";
        return "服务已启动";
    }
}
