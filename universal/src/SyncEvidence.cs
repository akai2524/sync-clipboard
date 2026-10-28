internal sealed class SyncEvidence
{
    readonly object gate = new object();
    bool complete;

    internal bool RecordProgress(ulong total, ulong transferred)
    {
        if (total == 0 || transferred != total) return false;
        lock (gate) {
            if (complete) return false;
            complete = true;
            return true;
        }
    }
    internal bool Complete { get { lock (gate) return complete; } }
    internal void Reset() { lock (gate) complete = false; }
}
