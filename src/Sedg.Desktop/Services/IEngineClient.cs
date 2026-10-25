using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>One-shot engine process in protocol mode (app-spawned, unelevated actions).</summary>
/// <remarks>
/// Contract: <see cref="RunAsync"/> returns when the run reaches its own terminal (a result line, a
/// transport fault, or process exit) — NOT when the UI cancels. App-side cancellation only stops the
/// UI from waiting (design §5.3); the caller keeps awaiting the task so the engine's terminal lands
/// in <see cref="AppLog"/> exactly once. Carries the Task 2 review carry-over: the result type keeps
/// raw <see cref="EngineRunResult.Data"/>; nothing is forced into a snapshot.
/// </remarks>
public interface IEngineClient
{
    Task<EngineRunResult> RunAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken);
}
