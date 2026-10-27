using System;
using System.Collections.Generic;
using System.Reflection;
using MiSmartShareClrWrapper;

// Reuse Xiaomi's existing device notifications. Never scan, pair, or connect here.
internal static class DeviceNames
{
    sealed class Phone
    {
        internal string Name;
        internal bool SameAccount, Connected;
    }
    static readonly object gate = new object();
    static readonly Dictionary<string, Phone> phones = new Dictionary<string, Phone>(StringComparer.Ordinal);
    // Keep the callback objects alive without resolving native types before backend setup.
    static object connection, info;
    static Action changed;
    static string label = "小米手机", source = "等待小米互联设备信息";
    internal static string Label { get { lock (gate) return label; } }
    internal static string Source { get { lock (gate) return source; } }

    internal static void Attach(Assembly unused, Action onChanged)
    {
        changed = onChanged;
        connection = new ConnectionEvents(); info = new InfoEvents();
        ConnectionClrWrapper.GetInstance().AddUI((ConnectionUIWrapper)connection);
        DeviceInfoBusinessCLRWrapper.GetInstance().SetDeviceInfoUICLRWrapperPtr((DeviceInfoUICLRWrapper)info);
    }
    internal static void Request() { ConnectionClrWrapper.GetInstance().HandleGetDeviceList(); }
    static string Clean(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        name = name.Trim();
        char[] chars = name.ToCharArray();
        for (int i = 0; i < chars.Length; i++) if (char.IsControl(chars[i])) chars[i] = ' ';
        string result = new string(chars).Trim();
        return result.Length == 0 ? null : result.Substring(0, Math.Min(128, result.Length));
    }
    static void Refresh()
    {
        // Prefer confirmed connections. A lone discovered phone is labelled as discovered,
        // not as connected; multiple candidates are never arbitrarily assigned to the UI.
        Phone selected = null; int count = 0, connectedCount = 0;
        foreach (Phone phone in phones.Values) if (phone.SameAccount || phone.Connected) {
            count++; if (phone.Connected) { connectedCount++; selected = phone; }
        }
        if (connectedCount == 0 && count == 1) foreach (Phone phone in phones.Values) if (phone.SameAccount) selected = phone;
        string next = connectedCount > 1 ? "多台手机已连接" : selected != null ? selected.Name : count > 1 ? "发现 " + count + " 台手机" : "小米手机";
        string nextSource = connectedCount > 0 ? "小米互联报告连接状态；不代表剪贴板传输已确认" : count > 0 ? "小米互联发现的同账号手机；未确认连接" : "等待小米互联设备信息";
        if (next == label && nextSource == source) return;
        label = next; source = nextSource;
        if (changed != null) changed();
    }
    static void Device(DeviceInfoWrapper value, bool connected, bool add)
    {
        try { lock (gate) {
            if (value.device_type != CDeviceTypeWrapper.kPhone || string.IsNullOrEmpty(value.idhash)) return;
            Phone phone;
            if (!phones.TryGetValue(value.idhash, out phone)) {
                if (!add) return;
                phone = new Phone(); phones.Add(value.idhash, phone);
            }
            phone.Name = Clean(value.name) ?? Clean(value.model_name) ?? phone.Name ?? "小米手机";
            phone.SameAccount = value.same_account; phone.Connected |= connected; Refresh();
        } } catch { }
    }
    static void Remove(string id, bool disconnect)
    {
        try { lock (gate) {
            Phone phone;
            if (id != null && phones.TryGetValue(id, out phone)) {
                if (disconnect) phone.Connected = false; else phones.Remove(id);
                Refresh();
            }
        } } catch { }
    }
    sealed class ConnectionEvents : ConnectionUIWrapper
    {
        public void OnHidePopDialog() { }
        public void OnDeviceListGetResult(IEnumerable<DeviceInfoWrapper> devices)
        {
            try { lock (gate) {
                // A complete snapshot replaces stale discoveries while retaining known links.
                Dictionary<string, bool> links = new Dictionary<string, bool>();
                foreach (KeyValuePair<string, Phone> item in phones) if (item.Value.Connected) links[item.Key] = true;
                phones.Clear();
                if (devices != null) foreach (DeviceInfoWrapper value in devices) Device(value, value.idhash != null && links.ContainsKey(value.idhash), true);
                Refresh();
            } } catch { }
        }
        public void OnDeviceAdded(DeviceInfoWrapper value) { Device(value, false, true); }
        public void OnDeviceRemoved(string id) { Remove(id, false); }
        public void OnAllDeviceCleared() { try { lock (gate) { phones.Clear(); Refresh(); } } catch { } }
        public void OnDeviceCleared(bool idm) { OnAllDeviceCleared(); }
        public void OnIDMDeviceClearedExcept(string id)
        {
            try { lock (gate) { Phone keep; phones.TryGetValue(id ?? "", out keep); phones.Clear(); if (keep != null) phones[id] = keep; Refresh(); } } catch { }
        }
        public void OnDeviceDisplayedFeatureUpdate(string id, DisplayFeatureTypeWrapper feature, bool available) { }
        public void OnDeviceNameUpdate(string id, string name)
        {
            try { lock (gate) { Phone phone; string clean = Clean(name); if (id != null && clean != null && phones.TryGetValue(id, out phone)) { phone.Name = clean; Refresh(); } } } catch { }
        }
        public void OnDeviceToBeConfirm() { }
        public void OnDeviceConnectResult(ConnectDeviceResultWrapper result, DeviceInfoWrapper value)
        {
            if (result == ConnectDeviceResultWrapper.kSuccess) Device(value, true, true);
        }
        public void OnConnectRejected() { }
        public void OnDeviceDisconnected(string id) { Remove(id, true); }
    }
    sealed class InfoEvents : DeviceInfoUICLRWrapper
    {
        public void OnGetDeviceInfoResult(DeviceInfoWrapper value) { Device(value, false, false); }
        public void OnCurrentDeviceInfo(DeviceInfoWrapper value) { Device(value, false, false); }
        public void OnDisplayDeviceModelImage(string image) { }
        public void OnGetPhoneBatteryLevelResult(byte level, byte power, string id) { }
        public void OnPhoneLockStateChange(bool locked) { }
        public void OnGetPhoneInfoResult(string info) { }
        public void OnUpdateActiveApp(ActiveAppInfoWrapper value) { }
        public void OnShowNFCUsage(string id, bool show) { }
        public void OnUpdateBatteryLevel() { }
    }
}
