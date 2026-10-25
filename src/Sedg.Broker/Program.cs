using System.Globalization;
using System.Security.Principal;
using System.Text.Json;
using Sedg.Protocol;

namespace Sedg.Broker;

/// <summary>
/// Elevated session-persistent operations proxy: one UAC per app session (REQ-002),
/// nonce on argv at handshake, requests over the pipe; one operation identity authorized per request.
/// </summary>
public static class Program
{
    private const int PipeConnectTimeoutMilliseconds = 120_000;

    public static int Main(string[] args)
    {
        try
        {
            return Run(args, executorFactory: null);
        }
        catch (Exception exception)
        {
            WriteDiagnostic(exception.Message);
            return (int)ErrorCode.EngineGeneric;
        }
    }

    /// <summary>Test seam only: production Main never supplies an executor factory.</summary>
    internal static int Run(string[] args, Func<ActionExecutor>? executorFactory)
    {
        if (!TryParseArguments(args, out var nonce, out var issuedUtc, out var expiresUtc, out var argumentError))
        {
            return Fail(ErrorCode.BrokerNonce, argumentError);
        }

        var nonceValidator = new NonceValidator();
        if (!nonceValidator.TryConsume(nonce, issuedUtc, expiresUtc, out var nonceError))
        {
            return Fail(ErrorCode.BrokerNonce, nonceError);
        }

        var mutex = new BrokerMutex();
        if (!mutex.TryEnter())
        {
            return Fail(ErrorCode.MutexBusy, "Another broker instance is already running for this session.");
        }

        try
        {
            string? sid;
            try
            {
                sid = WindowsIdentity.GetCurrent().User?.Value;
            }
            catch (Exception exception)
            {
                return Fail(ErrorCode.BrokerDenied, "The user SID could not be resolved: " + exception.Message);
            }

            if (string.IsNullOrEmpty(sid))
            {
                return Fail(ErrorCode.BrokerDenied, "The user SID could not be resolved.");
            }

            var executor = executorFactory?.Invoke() ?? new ActionExecutor();
            using var pipe = new PipeClient { PipeName = "Sedg.Broker." + sid + "." + nonce };
            try
            {
                pipe.Connect(PipeConnectTimeoutMilliseconds);
            }
            catch (Exception exception)
            {
                return Fail(ErrorCode.BrokerDenied, "The app pipe could not be connected: " + exception.Message);
            }

            return RunSession(pipe, new RequestValidator(nonce), executor);
        }
        catch (Exception exception)
        {
            WriteDiagnostic(exception.Message);
            return (int)ErrorCode.EngineGeneric;
        }
        finally
        {
            mutex.Exit();
        }
    }

    private static int RunSession(PipeClient pipe, RequestValidator validator, ActionExecutor executor)
    {
        var writeLock = new object();
        var authorized = new HashSet<Guid>();
        var operationInFlight = 0;
        Task? operation = null;

        while (true)
        {
            string line;
            try
            {
                line = pipe.ReadResponse();
            }
            catch (Exception exception) when (exception is EndOfStreamException or IOException or ObjectDisposedException)
            {
                break;
            }

            try
            {
                if (!HasActionProperty(line))
                {
                    if (!TryWrite(pipe, writeLock, BrokerResults.Error(ErrorCode.BrokerSchema, "The request has no action.")))
                    {
                        break;
                    }

                    continue;
                }

                if (!ProtocolJson.TryDeserializeRequest(line, out var request, out var parseError) || request is null)
                {
                    var message = "The request is not a valid protocol request: "
                                  + (parseError ?? "the line is invalid.");
                    if (!TryWrite(pipe, writeLock, BrokerResults.Error(ErrorCode.BrokerSchema, message)))
                    {
                        break;
                    }

                    continue;
                }

                if (!validator.Validate(request, out var sanitized, out var code, out var validationError)
                    || sanitized is null)
                {
                    var message = validationError ?? "The request was rejected.";
                    if (!TryWrite(pipe, writeLock, BrokerResults.Error(code, message)))
                    {
                        break;
                    }

                    continue;
                }

                if (Interlocked.CompareExchange(ref operationInFlight, 1, 0) != 0)
                {
                    if (!TryWrite(
                            pipe,
                            writeLock,
                            BrokerResults.Error(
                                ErrorCode.MutexBusy,
                                "Another operation is already running on this broker session.")))
                    {
                        break;
                    }

                    continue;
                }

                if (!Guid.TryParse(sanitized.OperationId, out var operationId) || !authorized.Add(operationId))
                {
                    Volatile.Write(ref operationInFlight, 0);
                    if (!TryWrite(
                            pipe,
                            writeLock,
                            BrokerResults.Error(
                                ErrorCode.BrokerSchema,
                                "The operationId has already been authorized in this session.")))
                    {
                        break;
                    }

                    continue;
                }

                operation = Task.Run(() =>
                {
                    try
                    {
                        var progress = new CallbackProgress(response => TryWrite(pipe, writeLock, response));
                        var result = executor.Execute(sanitized, progress);
                        TryWrite(pipe, writeLock, result);
                    }
                    catch (Exception exception)
                    {
                        TryWrite(
                            pipe,
                            writeLock,
                            BrokerResults.Error(ErrorCode.EngineGeneric, exception.Message, currentState: "unknown"));
                    }
                    finally
                    {
                        Volatile.Write(ref operationInFlight, 0);
                    }
                });
            }
            catch (Exception exception)
            {
                if (!TryWrite(
                        pipe,
                        writeLock,
                        BrokerResults.Error(ErrorCode.EngineGeneric, exception.Message, currentState: "unknown")))
                {
                    break;
                }
            }
        }

        if (operation is not null)
        {
            try
            {
                operation.GetAwaiter().GetResult();
            }
            catch (Exception exception)
            {
                WriteDiagnostic(exception.Message);
            }
        }

        return 0;
    }

    private static bool TryParseArguments(
        string[] args,
        out string nonce,
        out DateTimeOffset issuedUtc,
        out DateTimeOffset expiresUtc,
        out string? error)
    {
        nonce = string.Empty;
        issuedUtc = default;
        expiresUtc = default;

        if (args is null || args.Length != 3)
        {
            error = "Expected the launch arguments <nonce> <issuedUtc> <expiresUtc>.";
            return false;
        }

        nonce = args[0];
        if (string.IsNullOrWhiteSpace(nonce))
        {
            error = "The broker nonce is absent.";
            return false;
        }

        if (!DateTimeOffset.TryParse(
                args[1],
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind | DateTimeStyles.AssumeUniversal,
                out issuedUtc)
            || !DateTimeOffset.TryParse(
                args[2],
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind | DateTimeStyles.AssumeUniversal,
                out expiresUtc))
        {
            error = "The broker issue/expiry timestamps are malformed.";
            return false;
        }

        error = null;
        return true;
    }

    private static bool HasActionProperty(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            return document.RootElement.ValueKind == JsonValueKind.Object
                   && document.RootElement.TryGetProperty("action", out _);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryWrite(PipeClient pipe, object writeLock, ProtocolResponse response)
    {
        try
        {
            lock (writeLock)
            {
                pipe.SendRequest(ProtocolJson.Serialize(response));
            }

            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static int Fail(ErrorCode code, string? message)
    {
        WriteDiagnostic(message ?? code.ToString());
        return (int)code;
    }

    private static void WriteDiagnostic(string message)
        => Console.Error.WriteLine("Sedg.Broker: " + message);

    private sealed class CallbackProgress(Action<ProtocolResponse> report) : IProgress<ProtocolResponse>
    {
        public void Report(ProtocolResponse value) => report(value);
    }
}

internal static class BrokerResults
{
    public static ProtocolResponse Error(
        ErrorCode code,
        string message,
        string currentState = "unchanged",
        string nextStep = "Retry with a valid request or inspect the broker diagnostics.")
        => new()
        {
            Type = "result",
            Ok = false,
            Code = code,
            Message = message,
            CurrentState = currentState,
            RestoredState = "notRequired",
            NextStep = nextStep,
        };
}
