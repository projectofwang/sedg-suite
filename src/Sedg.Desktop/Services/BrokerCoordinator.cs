using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Sedg.Protocol;

namespace Sedg.Desktop.Services;

/// <summary>
/// Session-persistent elevated broker (design §3.1/§3.4, REQ-002): one UAC per session on the first
/// mutating request; the nonce rides the broker command line, requests travel over the pipe. The app
/// is the issuer of the nonce (single-use, replay-rejecting ledger — never a pipe for a nonce this
/// instance did not issue), enforces app-side operationId dedup, applies a user-scoped pipe DACL, and
/// verifies the connecting client PID's token is elevated before the handshake completes. T3.4 from
/// the Task 3 review is satisfied here. The broker's stdout/stderr are never read.
/// </summary>
public sealed class BrokerCoordinator : IBrokerCoordinator
{
    private const int ConnectionWaitMilliseconds = 120_000;
    private const int NonceValiditySeconds = 60;

    private const int ProcessQueryLimitedInformation = 0x1000;
    private const int TokenQuery = 0x0008;
    private const int TokenElevationClass = 20;

    /// <summary>
    /// The mutating actions this app exposes. Purge and RestoreEngine stay reserved (REQ-016 is
    /// deferred; the UI exposes no control for them) so the coordinator can never be driven into them.
    /// </summary>
    private static readonly IReadOnlySet<ProtocolAction> BrokerActions = new HashSet<ProtocolAction>
    {
        ProtocolAction.Install,
        ProtocolAction.Update,
        ProtocolAction.Pause,
        ProtocolAction.Resume,
        ProtocolAction.Restart,
        ProtocolAction.Uninstall,
        ProtocolAction.SetUpstream,
        ProtocolAction.SetDns,
    };

    private enum BrokerState
    {
        NotStarted,
        AwaitingUac,
        Ready,
        Declined,
    }

    private sealed class NonceLedger(string nonce, DateTimeOffset issuedUtc)
    {
        public string Nonce { get; } = nonce;

        public DateTimeOffset IssuedUtc { get; } = issuedUtc;

        public DateTimeOffset ExpiresUtc { get; } = issuedUtc.AddSeconds(NonceValiditySeconds);
    }

    private sealed class ActiveRequest
    {
        public ActiveRequest(ProtocolAction action, Guid operationId, IProgress<ProtocolResponse> progress)
        {
            Action = action;
            OperationId = operationId;
            Progress = progress;
            Terminal = new TaskCompletionSource<ProtocolResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        public ProtocolAction Action { get; }

        public Guid OperationId { get; }

        public IProgress<ProtocolResponse> Progress { get; }

        public TaskCompletionSource<ProtocolResponse> Terminal { get; }

        public volatile bool UiActive = true;

        /// <summary>Registration stamp; feeds the log-only late-completion record (§5.3).</summary>
        public DateTimeOffset StartedUtc;
    }

    private readonly AppLog _appLog;
    private readonly LocalizationManager _localization;
    private readonly string _brokerPath;
    private readonly Func<ProcessStartInfo, Process?> _launch;
    private readonly string _userSid;

    private readonly SemaphoreSlim _slot = new(1, 1);
    private readonly object _gate = new();
    private readonly HashSet<string> _issuedNonces = new(StringComparer.Ordinal);
    private readonly HashSet<string> _consumedNonces = new(StringComparer.Ordinal);
    private readonly HashSet<Guid> _seenOperationIds = new();

    private BrokerState _state = BrokerState.NotStarted;
    private string? _declineReason;
    private NonceLedger? _sessionLedger;
    private NamedPipeServerStream? _server;
    private StreamWriter? _writer;
    private StreamReader? _reader;
    private ActiveRequest? _active;
    private TaskCompletionSource<bool> _readyTask = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _launchCount;

    public BrokerCoordinator(AppLog appLog, LocalizationManager localization)
        : this(appLog, localization, brokerPath: null, launch: null)
    {
    }

    /// <summary>Test seam only: production resolves Sedg.Broker.exe next to the app and launches it via runas.</summary>
    internal BrokerCoordinator(
        AppLog appLog,
        LocalizationManager localization,
        string? brokerPath,
        Func<ProcessStartInfo, Process?>? launch)
    {
        _appLog = appLog;
        _localization = localization;
        _brokerPath = brokerPath ?? Path.Combine(AppContext.BaseDirectory, "Sedg.Broker.exe");
        _launch = launch ?? (startInfo => Process.Start(startInfo));
        _userSid = ResolveUserSid();
    }

    public event EventHandler? StateChanged;

    public bool CanInvokeMutations
    {
        get
        {
            lock (_gate)
            {
                return _state != BrokerState.Declined;
            }
        }
    }

    /// <summary>Resx key of the status-bar line for the §5.4 states; single derivation point.</summary>
    public string StatusBarKey
    {
        get
        {
            lock (_gate)
            {
                return _state switch
                {
                    BrokerState.NotStarted => "Status_Broker_Idle",
                    BrokerState.AwaitingUac => "Status_Broker_Launching",
                    BrokerState.Ready => "Status_Broker_Ready",
                    _ => "Status_Broker_Declined",
                };
            }
        }
    }

    public string? DeclineReason
    {
        get
        {
            lock (_gate)
            {
                return _declineReason;
            }
        }
    }

    /// <summary>Number of broker launches this session (UV evidence: one elevation per Ready cycle).</summary>
    internal int LaunchCount => Volatile.Read(ref _launchCount);

    internal bool WasNonceIssued(string nonce)
    {
        lock (_gate)
        {
            return _issuedNonces.Contains(nonce);
        }
    }

    internal bool WasNonceConsumed(string nonce)
    {
        lock (_gate)
        {
            return _issuedNonces.Contains(nonce) && _consumedNonces.Contains(nonce);
        }
    }

    /// <summary>User-initiated fresh elevation attempt (design §5.4): clears the declined state so the
    /// next mutating request begins a new session with a fresh nonce.</summary>
    public void ResetDecline()
    {
        lock (_gate)
        {
            if (_state != BrokerState.Declined)
            {
                return;
            }

            _state = BrokerState.NotStarted;
            _declineReason = null;
        }

        RaiseStateChanged();
    }

    public async Task<BrokerResult> InvokeAsync(
        ProtocolAction action,
        IReadOnlyDictionary<string, string> args,
        IProgress<ProtocolResponse> progress,
        CancellationToken cancellationToken)
    {
        if (!BrokerActions.Contains(action))
        {
            return Error(ErrorCode.BrokerSchema, "Broker_NotABrokerAction");
        }

        if (!ProtocolArgs.TryBuild(action, args, out var wireArgs, out var argumentError))
        {
            _appLog.Write("warn", $"{action} broker arguments failed the app-side mapping: {argumentError}");
            return Error(ErrorCode.Validation, "Engine_ArgumentMapping", detail: argumentError);
        }

        lock (_gate)
        {
            if (_state == BrokerState.Declined)
            {
                // A declined UAC stays read-only for the session (design §5.4); an explicit reset
                // re-enables one fresh attempt.
                return Error(ErrorCode.BrokerDenied, "Broker_Declined", detail: _declineReason);
            }
        }

        // The library does not validate operationId: app-side dedup accepts each identifier exactly
        // once, so a repeat is a replay and is rejected before any launch.
        var operationId = Guid.NewGuid();
        if (!_seenOperationIds.Add(operationId))
        {
            _appLog.Write("warn", $"Broker request operationId {operationId} was rejected as a replay.");
            return Error(ErrorCode.BrokerSchema, "Broker_OperationReplay");
        }

        try
        {
            await _slot.WaitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return CancelledResult(_localization.GetString("Broker_Cancelled"));
        }

        // One session request at a time. A slot-holding cancelled request keeps the slot until its
        // true engine result arrives — that arrival, not the UI's cancel, is what frees the slot.
        var sent = false;
        try
        {
            if (!await AwaitSessionReadyAsync())
            {
                return Error(ErrorCode.BrokerDenied, "Broker_Declined", detail: DeclineReason);
            }

            NonceLedger? ledger;
            lock (_gate)
            {
                ledger = _sessionLedger;
            }

            if (ledger is null)
            {
                _appLog.Write("warn", "The broker handshake nonce is missing for a ready session.");
                return Error(ErrorCode.BrokerDenied, "Broker_Declined", detail: _localization.GetString("Broker_Declined"));
            }

            var active = new ActiveRequest(action, operationId, progress);
            active.StartedUtc = DateTimeOffset.UtcNow;
            lock (_gate)
            {
                _active = active;
            }

            try
            {
                WriteRequestLine(ProtocolJson.Serialize(new ProtocolRequest
                {
                    Action = action,
                    OperationId = operationId.ToString("D"),
                    Args = wireArgs,
                    // The envelope echoes the handshake nonce; the per-request issued/expiry window is
                    // fresh so it always sits inside the broker's ±120 s validity check.
                    Nonce = ledger.Nonce,
                    IssuedUtc = DateTimeOffset.UtcNow,
                    ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(NonceValiditySeconds),
                }));
                sent = true;
            }
            catch (Exception exception)
            {
                _appLog.Write("warn", $"The broker request line could not be written: {exception.Message}");
                // The line never reached the pipe; drop the registration so a late response cannot
                // misattribute itself to a future operation.
                lock (_gate)
                {
                    if (ReferenceEquals(_active, active))
                    {
                        _active = null;
                    }
                }

                return Error(ErrorCode.Protocol, "Broker_ConnectionLost");
            }

            _appLog.Write("info", $"Broker request {action} (operation {operationId}).");

            var terminalTask = active.Terminal.Task;
            var completed = await Task.WhenAny(terminalTask, Task.Delay(Timeout.Infinite, cancellationToken));
            if (completed != terminalTask)
            {
                // App-side cancel stops waiting (design §5.3); the engine keeps running and the true
                // result lands log-only, never rendered as a success of the cancelled wait.
                active.UiActive = false;
                return CancelledResult(_localization.GetString("Broker_Cancelled"));
            }

            return ToBrokerResult(await terminalTask);
        }
        finally
        {
            if (!sent)
            {
                _slot.Release();
            }
        }
    }

    /// <summary>Waits until the session reaches Ready; false on a declined start. While the state is
    /// NotStarted a session begins; while AwaitingUac the caller waits on that start's completion task.</summary>
    private async Task<bool> AwaitSessionReadyAsync()
    {
        Task<bool> ready;
        lock (_gate)
        {
            if (_state == BrokerState.Ready)
            {
                return true;
            }

            if (_state == BrokerState.Declined)
            {
                return false;
            }

            if (_state == BrokerState.NotStarted)
            {
                BeginSessionLocked();
            }

            ready = _readyTask.Task;
        }

        return await ready;
    }

    /// <summary>Prepares the session under the gate: nonce ledger, pipe server with DACL, and the
    /// launch arguments; the launched pipeline (UAC, connect, handshake, request loop) runs off the lock.</summary>
    private void BeginSessionLocked()
    {
        try
        {
            var nonceBytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
            var nonce = Convert.ToHexString(nonceBytes).ToLowerInvariant(); // 256-bit hex bearer token
            var now = DateTimeOffset.UtcNow;
            var ledger = new NonceLedger(nonce, now);
            _issuedNonces.Add(nonce);
            _sessionLedger = ledger;

            var pipeName = PipeBaseName() + "." + _userSid + "." + nonce;
            _server = CreateServerWithDacl(pipeName);

            var startInfo = new ProcessStartInfo
            {
                FileName = _brokerPath,
                Arguments = $"{nonce} {now:o} {ledger.ExpiresUtc:o}",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
                CreateNoWindow = true,
                LoadUserProfile = false,
            };

            _launchCount++;
            _readyTask = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _state = BrokerState.AwaitingUac;
            var server = _server;
            _ = Task.Run(() => SessionPipelineAsync(server, ledger, startInfo));
            RaiseStateChanged();
        }
        catch (Exception exception)
        {
            // Prepare failures are deviations, not declines by the user; they still end the wait.
            _appLog.Write("warn", "The broker session could not be prepared: " + exception.Message);
            _state = BrokerState.Declined;
            _declineReason = "The broker session could not be prepared: " + exception.Message;
            _sessionLedger = null;
            _readyTask = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _readyTask.TrySetResult(false);
        }
    }

    private async Task SessionPipelineAsync(NamedPipeServerStream server, NonceLedger ledger, ProcessStartInfo startInfo)
    {
        // 1. The elevated launch; the UAC dialog resolves inside this call. A user decline throws.
        Process? process;
        try
        {
            process = _launch(startInfo);
        }
        catch (Exception exception)
        {
            DeclineNow(_localization.GetString("Broker_Declined") + " — " + exception.Message, server);
            return;
        }

        if (process is null)
        {
            DeclineNow(_localization.GetString("Broker_Declined"), server);
            return;
        }

        // 2. The client must connect within the bootstrap window; cancel becomes a decline.
        try
        {
            using var handshakeCts = new CancellationTokenSource(ConnectionWaitMilliseconds);
            await server.WaitForConnectionAsync(handshakeCts.Token);
        }
        catch (OperationCanceledException)
        {
            DeclineNow(_localization.GetString("Broker_NoConnect"), server);
            return;
        }
        catch (Exception exception)
        {
            DeclineNow(exception.Message, server);
            return;
        }

        // 3. The client token must be elevated (design §3.1) — the Task 3 Tester gap closed app-side.
        // A non-elevated peer is dropped before a single byte is written.
        var clientPid = GetClientPidSafe(server);
        if (clientPid <= 0 || !IsProcessElevated(clientPid))
        {
            _appLog.Write("warn", $"The broker client pid {clientPid} failed the elevated-token check; the connection was dropped without sending.");
            DeclineNow(_localization.GetString("Broker_NotElevated"), server);
            return;
        }

        // 4. Single-use handshake nonce (T3.4): a nonce is consumed exactly once by this instance.
        bool replayed;
        lock (_gate)
        {
            replayed = !_consumedNonces.Add(ledger.Nonce);
        }

        if (replayed)
        {
            _appLog.Write("warn", "A replayed handshake nonce was rejected.");
            DeclineNow(_localization.GetString("Broker_ReplayRejected"), server);
            return;
        }

        // 5. Handshake complete: JSONL both ways, UTF-8 without BOM; the reader detects a BOM in case
        // the peer writes one. The session nonce stays valid for every later request envelope.
        var writer = new StreamWriter(server, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), bufferSize: 4096, leaveOpen: true)
        {
            AutoFlush = true,
            NewLine = "\n",
        };
        var reader = new StreamReader(
            server,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            detectEncodingFromByteOrderMarks: true,
            bufferSize: 4096,
            leaveOpen: true);

        bool attached;
        lock (_gate)
        {
            if (ReferenceEquals(_server, server))
            {
                _writer = writer;
                _reader = reader;
                _state = BrokerState.Ready;
                attached = true;
            }
            else
            {
                attached = false;
            }
        }

        if (!attached)
        {
            // The session was replaced before it could GoLive; dispose quietly.
            DisposeQuietly(writer);
            DisposeQuietly(reader);
            DisposeQuietly(server);
            return;
        }

        _readyTask.TrySetResult(true);
        RaiseStateChanged();

        RunReaderLoop(server, reader, writer);
    }

    private void RunReaderLoop(NamedPipeServerStream server, StreamReader reader, StreamWriter writer)
    {
        try
        {
            while (reader.ReadLine() is { } line)
            {
                line = StripBomPrefix(line);
                if (!ProtocolJson.TryDeserializeLine(line, out var response, out var lineError) || response is null)
                {
                    _appLog.Write("warn", "The broker wrote an invalid JSONL line: " + (lineError ?? "unknown."));
                    continue;
                }

                if (string.Equals(response.Type, "result", StringComparison.Ordinal))
                {
                    CompleteActive(response);
                    continue;
                }

                // event/progress lines surface only while the request is still wanted by the UI.
                ActiveRequest? active;
                lock (_gate)
                {
                    active = _active;
                }

                if (active is { UiActive: true })
                {
                    active.Progress.Report(response);
                }
            }
        }
        catch (Exception exception)
        {
            _appLog.Write("info", "The broker session ended: " + exception.Message);
        }
        finally
        {
            EndSession(server, writer, reader);
        }
    }

    private void CompleteActive(ProtocolResponse terminal)
    {
        ActiveRequest? active;
        lock (_gate)
        {
            active = _active;
            _active = null;
        }

        if (active is null)
        {
            _appLog.Write("warn", "A broker result line arrived without an active request.");
            return;
        }

        active.Terminal.TrySetResult(terminal);
        // The slot frees here: this arrival IS the true result being consumed, even for a request the
        // UI already cancelled waiting on.
        try
        {
            _slot.Release();
        }
        catch (SemaphoreFullException)
        {
            // A session-failure path already released.
        }

        if (!active.UiActive)
        {
            // The UI stopped waiting but the request kept executing; the true terminal lands in the
            // operation log under the transport id (design §5.3 log-only completion).
            var actionName = active.Action.ToString();
            _appLog.WriteOperation(
                active.OperationId.ToString("D"),
                char.ToLowerInvariant(actionName[0]) + actionName[1..],
                active.StartedUtc,
                DateTimeOffset.UtcNow,
                terminal.Ok ?? false,
                (terminal.Code ?? ErrorCode.EngineGeneric).ToString(),
                terminal.Message,
                terminal.TranscriptPath,
                lateCompletion: true);
        }
    }

    /// <summary>Tears down one session's artifacts, resets to NotStarted so a later request begins a
    /// fresh session (new elevation), and faults an in-flight request with a transport result.</summary>
    private void EndSession(NamedPipeServerStream server, StreamWriter writer, StreamReader reader)
    {
        var isCurrent = false;
        ActiveRequest? faulted = null;
        lock (_gate)
        {
            if (ReferenceEquals(_server, server))
            {
                _writer = null;
                _reader = null;
                _server = null;
                _sessionLedger = null;
                if (_state is BrokerState.Ready or BrokerState.AwaitingUac)
                {
                    _state = BrokerState.NotStarted;
                }

                isCurrent = true;
            }

            faulted = _active;
            _active = null;
        }

        DisposeQuietly(writer);
        DisposeQuietly(reader);
        if (isCurrent)
        {
            DisposeQuietly(server);
            _readyTask.TrySetResult(false);
        }

        if (faulted is not null)
        {
            FaultActive(faulted);
        }

        if (isCurrent)
        {
            RaiseStateChanged();
        }
    }

    private void DeclineNow(string reason, NamedPipeServerStream? server)
    {
        _appLog.Write("warn", "Broker declined: " + reason);
        var wasCurrent = false;
        ActiveRequest? faulted = null;
        StreamWriter? writer = null;
        StreamReader? reader = null;
        lock (_gate)
        {
            if (_state != BrokerState.Declined)
            {
                _state = BrokerState.Declined;
                _declineReason = reason;
            }

            _sessionLedger = null;
            faulted = _active;
            _active = null;
            if (server is not null && ReferenceEquals(_server, server))
            {
                writer = _writer;
                _writer = null;
                reader = _reader;
                _reader = null;
                _server = null;
                wasCurrent = true;
            }
        }

        DisposeQuietly(writer);
        DisposeQuietly(reader);
        if (wasCurrent)
        {
            DisposeQuietly(server);
        }

        if (faulted is not null)
        {
            FaultActive(faulted);
        }

        _readyTask.TrySetResult(false);
        RaiseStateChanged();
    }

    private void FaultActive(ActiveRequest active)
    {
        var fault = new ProtocolResponse
        {
            Type = "result",
            Ok = false,
            Code = ErrorCode.Protocol,
            Message = _localization.GetString("Broker_ConnectionLost"),
            CurrentState = "unknown",
            RestoredState = "notRequired",
            NextStep = _localization.GetString("Engine_NextStep_InspectLog"),
        };

        if (active.Terminal.TrySetResult(fault))
        {
            try
            {
                _slot.Release();
            }
            catch (SemaphoreFullException)
            {
            }
        }
    }

    private void WriteRequestLine(string requestJson)
    {
        StreamWriter? writer;
        lock (_gate)
        {
            writer = _writer;
        }

        if (writer is null)
        {
            throw new InvalidOperationException("The broker session writer is not connected.");
        }

        writer.WriteLine(requestJson);
    }

    private BrokerResult ToBrokerResult(ProtocolResponse terminal)
        => new()
        {
            Ok = terminal.Ok ?? false,
            Code = terminal.Code ?? ErrorCode.EngineGeneric,
            Message = terminal.Message ?? string.Empty,
            CurrentState = terminal.CurrentState ?? string.Empty,
            RestoredState = terminal.RestoredState ?? string.Empty,
            NextStep = terminal.NextStep ?? string.Empty,
            Data = terminal.Data, // raw payload preserved (CDN/operation data); never snapshot-forced
            ExitCode = null, // the session broker is persistent; no child exit code is available in-flight
            StderrTail = null, // never read broker stdout/stderr (design §3.1/§3.5)
            LogPath = terminal.TranscriptPath,
        };

    private BrokerResult CancelledResult(string message)
        => new()
        {
            Ok = false,
            Code = ErrorCode.Cancelled,
            Message = message,
            CurrentState = "unchanged",
            RestoredState = "notRequired",
            NextStep = _localization.GetString("Engine_NextStep_InspectLog"),
            Cancelled = true,
        };

    private BrokerResult Error(ErrorCode code, string key, string? detail = null)
    {
        var message = _localization.GetString(key);
        if (!string.IsNullOrEmpty(detail))
        {
            message += " (" + detail + ")";
        }

        return new BrokerResult
        {
            Ok = false,
            Code = code,
            Message = message,
            CurrentState = "unchanged",
            RestoredState = "notRequired",
            NextStep = _localization.GetString("Broker_NextStep_RetryElevation"),
        };
    }

    private string PipeBaseName() => "Sedg.Broker";

    private NamedPipeServerStream CreateServerWithDacl(string pipeName)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(_userSid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-18"), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-32-544"), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return NamedPipeServerStreamAcl.Create(
            pipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            inBufferSize: 0,
            outBufferSize: 0,
            security);
    }

    private static string ResolveUserSid()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User?.Value ?? string.Empty;
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }

    internal static string StripBomPrefix(string line)
        => line.Length > 0 && line[0] == '\uFEFF' ? line[1..] : line;

    private int GetClientPidSafe(NamedPipeServerStream server)
    {
        try
        {
            // The managed surface for this is inconsistent across TFMs; kernel32 is authoritative (§3.4).
            return GetNamedPipeClientProcessIdSafe(server.SafePipeHandle.DangerousGetHandle());
        }
        catch (Exception)
        {
            return 0;
        }
    }

    private static int GetNamedPipeClientProcessIdSafe(IntPtr pipeHandle)
    {
        if (GetNamedPipeClientProcessId(pipeHandle, out var clientPid))
        {
            return checked((int)clientPid);
        }

        return 0;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(IntPtr pipeHandle, out uint clientProcessId);

    /// <summary>OpenProcess(QUERY_LIMITED) → OpenProcessToken(QUERY) → GetTokenInformation(TokenElevation):
    /// authoritative, platform-only, and it never grants the connection.</summary>
    internal static bool IsProcessElevated(int clientPid)
    {
        if (clientPid <= 0 || !OperatingSystem.IsWindows())
        {
            return false;
        }

        var process = OpenProcess(ProcessQueryLimitedInformation, false, clientPid);
        if (process == IntPtr.Zero)
        {
            return false;
        }

        var token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(process, TokenQuery, out token))
            {
                return false;
            }

            if (!GetTokenInformation(token, TokenElevationClass, out var elevation, sizeof(int), out var returned)
                || returned < sizeof(int))
            {
                return false;
            }

            return elevation != 0;
        }
        finally
        {
            if (token != IntPtr.Zero)
            {
                CloseHandle(token);
            }

            CloseHandle(process);
        }
    }

    private void RaiseStateChanged()
    {
        try
        {
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception)
        {
            // Listener failures must never break session machinery.
        }
    }

    private static void DisposeQuietly(IDisposable? disposable)
    {
        if (disposable is null)
        {
            return;
        }

        try
        {
            disposable.Dispose();
        }
        catch (Exception)
        {
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inheritHandle, int processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, int desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr tokenHandle, int infoClass, out int info, int length, out int returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
