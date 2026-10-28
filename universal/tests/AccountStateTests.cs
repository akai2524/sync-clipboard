using System;

internal static class AccountStateTests
{
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static int Main()
    {
        AccountState account = new AccountState();
        Assert(!account.Snapshot().LoggedIn, "初始账号状态错误");
        account.LoginSucceeded("  小米用户\r\n测试  ");
        AccountSnapshot current = account.Snapshot();
        Assert(current.LoggedIn && current.DisplayName == "小米用户  测试", "登录昵称没有正确处理");
        account.LoginSucceeded(null);
        current = account.Snapshot();
        Assert(current.LoggedIn && current.DisplayName == null, "缺少昵称时应保留登录状态");
        account.LoginSucceeded(new string('a', 100));
        Assert(account.Snapshot().DisplayName.Length == 64, "长昵称未限制显示长度");
        account.SignedOut();
        current = account.Snapshot();
        Assert(!current.LoggedIn && current.DisplayName == null, "退出登录后未清除昵称");
        Console.WriteLine("账号显示状态测试通过。");
        return 0;
    }
}
