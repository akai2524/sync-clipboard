using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using MiSmartShareClrWrapper;

internal static class DeviceNamesTests
{
    const string Backend = @"C:\Program Files\MI\XiaomiPCManager\5.4.0.620";
    [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool SetDllDirectory(string path);
    static void Equal(string expected, string actual, string step)
    {
        if (expected != actual) throw new Exception(step + ": expected " + expected + ", got " + actual);
    }
    [STAThread] static int Main()
    {
        try {
            SetDllDirectory(Backend);
            AppDomain.CurrentDomain.AssemblyResolve += (s,e) => Assembly.LoadFrom(Path.Combine(Backend, new AssemblyName(e.Name).Name + ".dll"));
            Assembly.LoadFrom(Path.Combine(Backend, "MiSmartShareClrWrapper.dll"));
            Run(); Console.WriteLine("PASS: names, rename, connection preference, multiple candidates, clear, model fallback, sanitization"); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
    static void Run()
    {
        // Invoke the real adapters directly, without attaching to or initializing the service.
        Type type = typeof(DeviceNames).GetNestedType("ConnectionEvents", BindingFlags.NonPublic);
        ConnectionUIWrapper callbacks = (ConnectionUIWrapper)Activator.CreateInstance(type, true);
        Equal("小米手机", DeviceNames.Label, "empty");
        DeviceInfoWrapper first = new DeviceInfoWrapper { device_type=CDeviceTypeWrapper.kPhone, same_account=true, idhash="test-one", name="测试手机", model_name="测试型号" };
        callbacks.OnDeviceAdded(first); Equal("测试手机", DeviceNames.Label, "name over model");
        callbacks.OnDeviceNameUpdate("test-one", "新手机名称"); Equal("新手机名称", DeviceNames.Label, "rename event");
        DeviceInfoWrapper second = new DeviceInfoWrapper { device_type=CDeviceTypeWrapper.kPhone, same_account=true, idhash="test-two", name="另一台手机" };
        callbacks.OnDeviceAdded(second); Equal("发现 2 台手机", DeviceNames.Label, "ambiguous discoveries");
        callbacks.OnDeviceConnectResult(ConnectDeviceResultWrapper.kSuccess, second); Equal("另一台手机", DeviceNames.Label, "prefer connected");
        callbacks.OnDeviceDisconnected("test-two"); Equal("发现 2 台手机", DeviceNames.Label, "disconnect removes connection preference");
        callbacks.OnDeviceRemoved("test-two"); Equal("新手机名称", DeviceNames.Label, "remove one");
        callbacks.OnAllDeviceCleared(); Equal("小米手机", DeviceNames.Label, "clear avoids stale name");
        first.name=null; first.model_name="测试型号 Pro";
        callbacks.OnDeviceListGetResult(new[] {first}); Equal("测试型号 Pro", DeviceNames.Label, "model fallback and snapshot");
        callbacks.OnDeviceNameUpdate("test-one", "第一行\n第二行"); Equal("第一行 第二行", DeviceNames.Label, "sanitize control characters");
        callbacks.OnDeviceListGetResult(new DeviceInfoWrapper[0]); Equal("小米手机", DeviceNames.Label, "empty snapshot");
        first.same_account=false; callbacks.OnDeviceAdded(first); Equal("小米手机", DeviceNames.Label, "ignore unrelated discoveries");
        first.device_type=CDeviceTypeWrapper.kPad; first.same_account=true; first.idhash="test-pad";
        callbacks.OnDeviceAdded(first); Equal("小米手机", DeviceNames.Label, "do not call a tablet a phone");
    }
}
