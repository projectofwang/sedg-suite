namespace Sedg.Protocol;

/// <summary>Closed vocabulary of engine protocol actions (broker allow-list).</summary>
public enum ProtocolAction
{
    Status,
    Install,
    Update,
    Pause,
    Resume,
    Restart,
    Uninstall,
    Purge,
    SetUpstream,
    SetDns,
    RestoreEngine,
    SetLanguage,
    TestCdnOptimization,
}
