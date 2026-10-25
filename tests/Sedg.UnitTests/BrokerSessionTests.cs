using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using Sedg.Broker;
using Sedg.Protocol;

/// <summary>
/// End-to-end broker session at the named pipe, driven in-process: launch stamps, wire validation,
/// the in-flight MutexBusy gate, and operationId dedup. The executor seam answers EngineSpawn
/// without ever starting the engine or the pinned interpreter.
/// </summary>
public static class BrokerSessionTests
{
    /// <summary>One exchange: the test writes a line, the broker answers one line.</summary>
    private sealed class PipedServer : IDisposable
    {
        private NamedPipeServerStream? _server;
        private StreamReader? _reader;
        private StreamWriter? _writer;

        public string Name { private get; set; } = string.Empty;

        private StreamReader Reader => _reader ?? throw new InvalidOperationException("not connected");

        private StreamWriter Writer => _writer ?? throw new InvalidOperationException("not connected");

        /// <summary>
        /// Connects the server side. Returns false for a clean attempt miss: the bounded wait
        /// elapses, or the broker already exited without connecting (e.g. it lost the mutex race
        /// to the previous session). Only a non-timeout connect failure throws.
        /// </summary>
        public bool Connect(Task<int>? run = null)
        {
            _server = new NamedPipeServerStream(
                Name,
                PipeDirection.InOut,
                1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous);
            var connect = _server.WaitForConnectionAsync();
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!connect.IsCompleted && DateTime.UtcNow < deadline && run is not { IsCompleted: true })
            {
                Thread.Sleep(25);
            }

            if (!connect.IsCompleted || connect.IsFaulted)
            {
                return false;
            }

            connect.GetAwaiter().GetResult();
            _reader = new StreamReader(_server);
            _writer = new StreamWriter(_server) { AutoFlush = true, NewLine = "\n" };
            return true;
        }

        public void Write(string line) => Writer.WriteLine(line);

        public string Read() => Reader.ReadLine() ?? throw new EndOfStreamException("the broker closed the pipe");

        public void Dispose()
        {
            _writer?.Dispose();
            _reader?.Dispose();
            _server?.Dispose();
        }
    }

    private static (Task<int> Run, string PipeName) StartBroker(
        string nonce,
        DateTimeOffset issuedUtc,
        DateTimeOffset expiresUtc,
        Func<ActionExecutor>? executorFactory = null)
    {
        var sid = WindowsIdentity.GetCurrent().User?.Value ?? string.Empty;
        var run = Task.Run(() =>
            Sedg.Broker.Program.Run(
                new[]
                {
                    nonce,
                    issuedUtc.ToString("o", CultureInfo.InvariantCulture),
                    expiresUtc.ToString("o", CultureInfo.InvariantCulture),
                },
                executorFactory));
        return (run, "Sedg.Broker." + sid + "." + nonce);
    }

    /// <summary>A launch stamp inside the 120 s acceptance window.</summary>
    private static (DateTimeOffset Issued, DateTimeOffset Expires) FreshWindow()
        => (DateTimeOffset.UtcNow.AddSeconds(-1), DateTimeOffset.UtcNow.AddSeconds(60));

    /// <summary>A freshly consumed launch nonce distinct from every other session's.</summary>
    private static string NewLaunchNonce()
        => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    private static (DateTimeOffset Issued, DateTimeOffset Expires) StaleWindow()
        => (DateTimeOffset.UtcNow.AddSeconds(-200), DateTimeOffset.UtcNow.AddSeconds(60));

    [Test]
    public static void WrongLaunchArgumentsFailBeforeThePipe()
    {
        var exitCode = Sedg.Broker.Program.Run(new[] { "5ccf6e9d33cb261a5ccf6e9d33cb261a" }, executorFactory: null);
        Assert.True(exitCode != 0, "wrong launch argument count must fail closed with a non-zero exit");
    }

    [Test]
    public static void MalformedWireLinesGetSynchronousSchemaErrors()
    {
        var (issued, expires) = FreshWindow();
        var (runTask, pipeName) = StartBroker(NewLaunchNonce(), issued, expires, MissingExecutor());
        using var server = new PipedServer { Name = pipeName };
        try
        {
            Assert.True(server.Connect(runTask), "the broker connected to the pipe");

            server.Write("{}");
            var noAction = Parse(server.Read());
            Assert.False(noAction.Ok!.Value);
            Assert.Equal(ErrorCode.BrokerSchema, noAction.Code!.Value);
            Assert.True(
                noAction.Message!.Contains("no action", StringComparison.Ordinal),
                noAction.Message);

            // An action-bearing but schema-breaking line passes the HasActionProperty pre-check and
            // must land on the deserialize path's protocol-request error.
            server.Write("""{"action":"status"}""");
            var malformed = Parse(server.Read());
            Assert.False(malformed.Ok!.Value);
            Assert.Equal(ErrorCode.BrokerSchema, malformed.Code!.Value);
            Assert.True(
                malformed.Message!.Contains("not a valid protocol request", StringComparison.Ordinal),
                malformed.Message);

            server.Dispose();
            Assert.True(Await(runTask, 20_000) == 0, "a session that only answered errors exits 0");
        }
        finally
        {
            server.Dispose();
        }
    }

    [Test]
    public static void AStaleIssueStampIsRejectedBeforeThePipe()
    {
        // The launch stamp is consumed before the mutex and the pipe: a stale issued time fails
        // the process with BrokerNonce and no pipe is ever opened for a client to reach.
        var (issued, expires) = StaleWindow();
        var exitCode = Sedg.Broker.Program.Run(
            new[]
            {
                NewLaunchNonce(),
                issued.ToString("o", CultureInfo.InvariantCulture),
                expires.ToString("o", CultureInfo.InvariantCulture),
            },
            executorFactory: null);
        Assert.Equal((int)ErrorCode.BrokerNonce, exitCode);
    }

    [Test]
    public static void AValidRequestRunsThroughThePinAndFailsClosedAtTheMissingEngine()
    {
        var (issued, expires) = FreshWindow();
        ProcessStartInfo? captured = null;
        Func<ActionExecutor> captor = () =>
            new ActionExecutor(
                EnginePathValidator.EnginePath,
                validateEnginePath: false,
                startProcess: startInfo =>
                {
                    captured = startInfo;
                    return null;
                });

        var nonce = NewLaunchNonce();
        var (runTask, pipeName) = StartBroker(nonce, issued, expires, captor);
        using var server = new PipedServer { Name = pipeName };
        try
        {
            Assert.True(server.Connect(runTask), "the broker connected to the pipe");

            server.Write(NewWireRequest(nonce, issued, expires, Guid.NewGuid().ToString("D")));
            var terminal = Parse(server.Read());
            Assert.False(terminal.Ok!.Value);
            Assert.Equal(ErrorCode.EngineSpawn, terminal.Code!.Value);
            Assert.True(
                terminal.Message!.Contains("could not be started", StringComparison.Ordinal),
                terminal.Message);

            Assert.NotNull(captured);
            Assert.True(
                captured!.FileName.EndsWith("\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", StringComparison.OrdinalIgnoreCase),
                captured.FileName + " is not the pinned interpreter");
            Assert.Equal("-File", captured.ArgumentList[3]);
            server.Dispose();
            Assert.True(Await(runTask, 20_000) == 0);
        }
        finally
        {
            server.Dispose();
        }
    }

    [Test]
    public static void TheSecondInFlightRequestMeetsTheBusyGate()
    {
        using var started = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();

        // Hold the first operation in the executor so the second request deterministically meets the
        // gate. The startProcess seam never starts the engine; returning null yields EngineSpawn.
        Func<ActionExecutor> gated = () => new ActionExecutor(
            EnginePathValidator.EnginePath,
            validateEnginePath: false,
            startProcess: _ =>
            {
                started.Set();
                release.Wait(TimeSpan.FromSeconds(10));
                return null;
            });

        var (issued, expires) = FreshWindow();
        var nonce = NewLaunchNonce();
        var (runTask, pipeName) = StartBroker(nonce, issued, expires, gated);
        using var server = new PipedServer { Name = pipeName };
        try
        {
            Assert.True(server.Connect(runTask), "the broker connected to the pipe");
            server.Write(NewWireRequest(nonce, issued, expires, Guid.NewGuid().ToString("D")));
            Assert.True(started.Wait(TimeSpan.FromSeconds(5)), "the first operation reached the executor");

            server.Write(NewWireRequest(nonce, issued, expires, Guid.NewGuid().ToString("D")));

            // The busy answer comes from the session loop while the first operation is still held;
            // it can arrive before the first terminal, so read only the busy response here.
            var busy = Parse(server.Read());
            Assert.Equal(ErrorCode.MutexBusy, busy.Code!.Value);
            Assert.False(busy.Ok!.Value);
            Assert.True(
                busy.Message!.Contains("already running", StringComparison.Ordinal),
                busy.Message);
        }
        finally
        {
            release.Set();
            server.Dispose();
        }

        var exitCode = Await(runTask, 20_000);
        Assert.True(
            exitCode == 0,
            "the session that answered the busy gate exits 0 (actual " + exitCode + ")");
    }

    [Test]
    public static void DuplicateOperationIdsAreRejectedAfterTheTerminal()
    {
        var (issued, expires) = FreshWindow();
        var nonce = NewLaunchNonce();
        var (runTask, pipeName) = StartBroker(nonce, issued, expires, MissingExecutor());
        using var server = new PipedServer { Name = pipeName };
        try
        {
            Assert.True(server.Connect(runTask), "the broker connected to the pipe");

            const string operationId = "7d40c65a-6d67-4ab4-9654-0bd1500561b1";
            server.Write(NewWireRequest(nonce, issued, expires, operationId));
            var first = Parse(server.Read());
            Assert.Equal(ErrorCode.EngineSpawn, first.Code!.Value);

            // The dedup set persists for the session; a busy answer just means the in-flight flag
            // had not cleared, so retrying the identical request converges on the dedup error.
            for (var attempt = 0; attempt < 50; attempt++)
            {
                server.Write(NewWireRequest(nonce, issued, expires, operationId));
                var duplicate = Parse(server.Read());
                if (duplicate.Code == ErrorCode.MutexBusy)
                {
                    continue;
                }

                Assert.Equal(ErrorCode.BrokerSchema, duplicate.Code!.Value);
                Assert.True(
                    duplicate.Message!.Contains("already been authorized", StringComparison.Ordinal),
                    duplicate.Message);
                server.Dispose();
                var exitCode = Await(runTask, 20_000);
                Assert.True(
                    exitCode == 0,
                    "the session that reported the dedup error exits 0 (actual " + exitCode + ")");
                return;
            }

            Assert.Fail("the dedup error never surfaced", "BrokerSchema", "MutexBusy");
        }
        finally
        {
            server.Dispose();
        }
    }

    private static Func<ActionExecutor> MissingExecutor()
        => () => new ActionExecutor(
            EnginePathValidator.EnginePath,
            validateEnginePath: false,
            startProcess: _ => null);

    /// <summary>A valid, stamped request built by the shared protocol serializer.</summary>
    private static string NewWireRequest(
        string nonce,
        DateTimeOffset issuedUtc,
        DateTimeOffset expiresUtc,
        string operationId)
        => ProtocolJson.Serialize(new ProtocolRequest
        {
            Action = ProtocolAction.Status,
            OperationId = operationId,
            Args = new System.Text.Json.Nodes.JsonObject(),
            Nonce = nonce,
            IssuedUtc = issuedUtc,
            ExpiresUtc = expiresUtc,
        });

    private static ProtocolResponse Parse(string line)
    {
        Assert.True(ProtocolJson.TryDeserializeLine(line, out var response, out var error));
        Assert.NotNull(response);
        return response!;
    }

    private static int Await(Task<int> run, int milliseconds)
    {
        if (run.Wait(milliseconds))
        {
            return run.Result;
        }

        return int.MinValue;
    }
}
