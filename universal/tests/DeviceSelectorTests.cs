using System;

internal static class DeviceSelectorTests
{
    static void Expect(DeviceDecision value, DeviceAction action, string id)
    {
        if (value.Action != action || value.Id != id) throw new Exception("设备选择决策不符合预期：" + action);
    }
    static int Main()
    {
        DeviceSelector selector = new DeviceSelector();
        Expect(selector.Evaluate(new[] { "a" }, false), DeviceAction.None, null);
        Expect(selector.Evaluate(new[] { "a", "a" }, true), DeviceAction.SelectOne, "a");
        Expect(selector.Evaluate(new[] { "a" }, true), DeviceAction.None, null);
        Expect(selector.Evaluate(new[] { "a", "b" }, true), DeviceAction.AskUser, null);
        Expect(selector.Evaluate(new[] { "b", "a" }, true), DeviceAction.None, null);
        selector.UserSelected("b");
        Expect(selector.Evaluate(new[] { "a", "b", "c" }, true), DeviceAction.None, null);
        Expect(selector.Evaluate(new[] { "a", "c" }, true), DeviceAction.AskUser, null);
        Expect(selector.Evaluate(new string[0], true), DeviceAction.None, null);
        Expect(selector.Evaluate(new[] { "a" }, true), DeviceAction.SelectOne, "a");
        Expect(selector.Evaluate(new[] { "a" }, false), DeviceAction.None, null);
        Expect(selector.Evaluate(new[] { "a" }, true), DeviceAction.SelectOne, "a");
        Console.WriteLine("自动发现与设备选择测试通过。");
        return 0;
    }
}
