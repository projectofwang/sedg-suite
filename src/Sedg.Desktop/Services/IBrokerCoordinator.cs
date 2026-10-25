using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// Session-persistent elevated broker (one UAC per session; REQ-002). All mutating actions route here;
/// <see cref="IEngineClient"/> serves status/setLanguage/testCdnOptimization (design §8.2).
/// The concrete <see cref="BrokerCoordinator"/> owns the app-side nonce issuance ledger, the pipe DACL,
/// and the elevated-client token check the Task 3 Tester found missing (T3.4 is satisfied app-side).
/// </summary>
public interface IBrokerCoordinator
{
    Task<BrokerResult> InvokeAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken);

    /// <summary>Raised on every broker state change so the status bar can render the reason.</summary>
    event EventHandler? StateChanged;

    /// <summary>Resx key of the status-bar line for the §5.4 states; single derivation point.</summary>
    string StatusBarKey { get; }

    /// <summary>False after a declined/failed elevation; exact text in <see cref="DeclineReason"/>.</summary>
    bool CanInvokeMutations { get; }

    string? DeclineReason { get; }

    /// <summary>User-initiated fresh elevation attempt (design §5.4); one at a time at any moment.</summary>
    void ResetDecline();
}
