using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Sedg.Desktop.Services;
using Sedg.Protocol;

namespace Sedg.UnitTests;

/// <summary>
/// Regression for the published 1.2.5 defect: the engine client resumed on the calling (UI) thread
/// and then blocked that thread on the stderr read, whose own continuation needed the same thread.
/// A chatty engine on stderr therefore froze the window instead of returning a status.
/// </summary>
public static class EngineProcessClientTests
{
    private const int FloodLines = 2000;

    [Test]
    public static void ChattyStderrDoesNotDeadlockTheCallingThread()
    {
        var directory = Support.NewTempDirectory();
        try
        {
            // The locator only proves the engine exists; the seam below runs the mock instead.
            var enginePath = Path.Combine(directory, "manager.ps1");
            File.WriteAllText(enginePath, "# mock engine placeholder" + Environment.NewLine);

            var mockPath = Path.Combine(directory, "mock-engine.ps1");
            File.WriteAllText(mockPath, MockEngineScript, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            var client = new EngineProcessClient(
                new EngineLocator(enginePath),
                Support.NewAppLog(directory),
                Support.NewLocalization(directory),
                startProcess: _ => StartMockEngine(mockPath));

            var context = new SingleThreadPump();
            EngineRunResult? result = null;
            Exception? failure = null;
            using var finished = new ManualResetEventSlim(false);
            var caller = new Thread(() =>
            {
                SynchronizationContext.SetSynchronizationContext(context);
                try
                {
                    var run = client.RunAsync(
                        ProtocolAction.Status,
                        new Dictionary<string, string>(),
                        new SilentProgress(),
                        CancellationToken.None);

                    while (!run.IsCompleted)
                    {
                        context.PumpOne(TimeSpan.FromMilliseconds(50));
                    }

                    result = run.GetAwaiter().GetResult();
                }
                catch (Exception exception)
                {
                    failure = exception;
                }
                finally
                {
                    finished.Set();
                }
            })
            {
                IsBackground = true,
                Name = "engine-client-caller-thread",
            };

            caller.Start();

            // A single-threaded context cannot observe its own deadlock, so the budget is measured
            // from outside: the caller thread stays blocked inside the client, this thread times out.
            if (!finished.Wait(TimeSpan.FromSeconds(10)))
            {
                throw new TestFailedException(
                    "RunAsync did not return within 10 s while the caller's thread was still needed to "
                    + "finish reading stderr: the client resumed on the caller's synchronization context "
                    + "and then blocked it.");
            }

            if (failure is not null)
            {
                throw new TestFailedException("RunAsync threw instead of returning an outcome: " + failure);
            }

            Assert.NotNull(result);
            var outcome = result!;
            Assert.True(outcome.Ok, "The terminal result was not accepted: " + outcome.Message);
            Assert.Equal(ErrorCode.None, outcome.Code);
            Assert.Equal("status ok", outcome.Message);
            Assert.Equal(0, outcome.ExitCode ?? -1);

            // The flood must have been drained, not skipped: the bounded tail is the end of it.
            var tail = outcome.StderrTail ?? string.Empty;
            Assert.Equal(512, tail.Length);
            Assert.True(
                tail.Contains("diag line " + (FloodLines - 1) + " ", StringComparison.Ordinal),
                "The stderr tail does not end with the last flooded line: " + tail);
        }
        finally
        {
            try
            {
                Directory.Delete(directory, recursive: true);
            }
            catch (IOException)
            {
                // Best effort: a leaked mock handle must not fail the case.
            }
        }
    }

    private static Process? StartMockEngine(string mockPath)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = EngineProcessClient.ResolvedPowerShellPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        foreach (var argument in new[]
                 {
                     "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", mockPath,
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }

        return Process.Start(startInfo);
    }

    /// <summary>The caller's thread stays the only thread allowed to run continuations.</summary>
    private sealed class SingleThreadPump : SynchronizationContext
    {
        private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();

        public override void Post(SendOrPostCallback d, object? state) => _queue.Add((d, state));

        public override void Send(SendOrPostCallback d, object? state)
            => throw new NotSupportedException("The test pump never runs synchronously from another thread.");

        public void PumpOne(TimeSpan timeout)
        {
            if (_queue.TryTake(out var work, timeout))
            {
                work.Callback(work.State);
            }
        }
    }

    private sealed class SilentProgress : IProgress<ProtocolResponse>
    {
        public void Report(ProtocolResponse value)
        {
            // The case asserts the terminal outcome, not the stream.
        }
    }

    // Pure ASCII: the engine family is read on code pages that mangle anything else.
    private const string MockEngineScript = """
        $ErrorActionPreference = 'Stop'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
        $out.AutoFlush = $true
        $err = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8)
        $err.AutoFlush = $true
        $null = [Console]::In.ReadLine()
        $out.WriteLine('{"type":"hello","protocolVersion":1,"pid":4242,"engineVersion":"mock-1.0"}')
        for ($i = 0; $i -lt 2000; $i++) {
            $err.WriteLine('diag line ' + $i + ' ' + ('x' * 40))
        }
        $out.WriteLine('{"type":"event","seq":1,"tsUtc":"2026-01-01T00:00:00Z","phase":"status","message":"working"}')
        $out.WriteLine('{"type":"result","ok":true,"code":"None","message":"status ok","currentState":"installed","restoredState":"unchanged","nextStep":"none","data":{"observedUtc":"2026-01-01T00:00:00Z","phases":[]}}')
        $out.Flush()
        $err.Flush()
        """;
}
