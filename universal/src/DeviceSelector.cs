using System;
using System.Collections.Generic;

internal enum DeviceAction { None, SelectOne, AskUser }

internal struct DeviceDecision
{
    internal DeviceAction Action;
    internal string Id;
}

// Tracks requests only in memory; the official service remains responsible for pairing.
internal sealed class DeviceSelector
{
    string requested;
    bool userSelected;
    string lastPrompt;

    internal DeviceDecision Evaluate(IEnumerable<string> values, bool loggedIn)
    {
        if (!loggedIn) { Reset(); return new DeviceDecision(); }
        SortedSet<string> ids = new SortedSet<string>(StringComparer.Ordinal);
        if (values != null) foreach (string value in values) if (!String.IsNullOrEmpty(value)) ids.Add(value);
        if (ids.Count == 0) { Reset(); return new DeviceDecision(); }
        if (userSelected && requested != null && ids.Contains(requested)) return new DeviceDecision();
        if (userSelected) { userSelected = false; requested = null; }
        if (ids.Count == 1) {
            string id = null; foreach (string item in ids) { id = item; break; }
            lastPrompt = null;
            if (String.Equals(requested, id, StringComparison.Ordinal)) return new DeviceDecision();
            requested = id;
            return new DeviceDecision { Action = DeviceAction.SelectOne, Id = id };
        }
        string key = String.Join("\n", new List<string>(ids).ToArray());
        if (String.Equals(lastPrompt, key, StringComparison.Ordinal)) return new DeviceDecision();
        lastPrompt = key;
        return new DeviceDecision { Action = DeviceAction.AskUser };
    }
    internal void UserSelected(string id) { requested = id; userSelected = !String.IsNullOrEmpty(id); }
    internal void Reset() { requested = null; userSelected = false; lastPrompt = null; }
}
