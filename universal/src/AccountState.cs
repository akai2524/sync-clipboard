using System;
using System.Text;

internal struct AccountSnapshot
{
    internal bool LoggedIn;
    internal string DisplayName;
}

// Account identifiers and avatars are deliberately not retained.
internal sealed class AccountState
{
    readonly object gate = new object();
    bool loggedIn;
    string displayName;

    internal void LoginSucceeded(string name)
    {
        lock (gate) { loggedIn = true; displayName = CleanName(name); }
    }
    internal void SignedOut()
    {
        lock (gate) { loggedIn = false; displayName = null; }
    }
    internal AccountSnapshot Snapshot()
    {
        lock (gate) { return new AccountSnapshot { LoggedIn = loggedIn, DisplayName = displayName }; }
    }
    static string CleanName(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return null;
        StringBuilder result = new StringBuilder();
        foreach (char c in value.Trim()) {
            result.Append(Char.IsControl(c) ? ' ' : c);
            if (result.Length >= 64) break;
        }
        if (result.Length > 0 && Char.IsHighSurrogate(result[result.Length - 1])) result.Length--;
        string name = result.ToString().Trim();
        return name.Length == 0 ? null : name;
    }
}
