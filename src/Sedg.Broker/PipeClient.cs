using System.IO.Pipes;
using System.Text;

namespace Sedg.Broker;

/// <summary>Named-pipe client: connect to \\.\pipe\Sedg.Broker.&lt;userSid&gt;.&lt;nonce&gt;, exchange one line at a time.</summary>
public sealed class PipeClient : IDisposable
{
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    public string PipeName { get; init; } = string.Empty;

    public void Connect(int timeoutMilliseconds)
    {
        if (string.IsNullOrWhiteSpace(PipeName))
        {
            throw new InvalidOperationException("The broker pipe name is required.");
        }

        _pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        _pipe.Connect(timeoutMilliseconds);
        _reader = new StreamReader(
            _pipe,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            detectEncodingFromByteOrderMarks: true,
            bufferSize: 4096,
            leaveOpen: true);
        _writer = new StreamWriter(
            _pipe,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            bufferSize: 4096,
            leaveOpen: true)
        {
            AutoFlush = true,
            NewLine = "\n",
        };
    }

    /// <summary>Writes one protocol line. The name follows the skeleton; the broker writes responses too.</summary>
    public void SendRequest(string requestJson)
    {
        if (_writer is null)
        {
            throw new InvalidOperationException("The broker pipe is not connected.");
        }

        _writer.WriteLine(requestJson);
        _writer.Flush();
    }

    public string ReadResponse()
    {
        if (_reader is null)
        {
            throw new InvalidOperationException("The broker pipe is not connected.");
        }

        var line = _reader.ReadLine();
        if (line is null)
        {
            throw new EndOfStreamException("The broker pipe closed.");
        }

        return line;
    }

    public void Dispose()
    {
        // A client that disconnects first can break the pipe; disposing is best effort so a normal
        // session still exits 0 instead of surfacing the broken pipe as an engine error.
        DisposeBestEffort(_writer);
        DisposeBestEffort(_reader);
        DisposeBestEffort(_pipe);
        _writer = null;
        _reader = null;
        _pipe = null;
    }

    private static void DisposeBestEffort(IDisposable? disposable)
    {
        try
        {
            disposable?.Dispose();
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }
}
