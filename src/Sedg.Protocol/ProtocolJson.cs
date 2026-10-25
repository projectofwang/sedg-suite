using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sedg.Protocol;

/// <summary>JSONL serialization shared by app and broker.</summary>
public static class ProtocolJson
{
    public const int CurrentProtocolVersion = 1;

    internal static JsonSerializerOptions SerializerOptions { get; } = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            WriteIndented = false,
        };
        options.Converters.Add(new JsonStringEnumConverter<ProbeState>(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.Converters.Add(new JsonStringEnumConverter<ProtocolAction>(allowIntegerValues: false));
        options.Converters.Add(new JsonStringEnumConverter<ErrorCode>(allowIntegerValues: false));
        options.Converters.Add(new VersionMatrixJsonConverter());
        return options;
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, SerializerOptions);

    /// <summary>
    /// Deserializes one response line. A malformed or schema-invalid line is
    /// returned as a schema-valid error result; it never throws.
    /// </summary>
    public static ProtocolResponse? DeserializeLine(string line)
        => TryDeserializeLine(line, out var response, out var error) ? response : ErrorResponse(error);

    public static bool TryDeserializeLine(string line, out ProtocolResponse? response, out string? error)
    {
        response = null;
        error = null;

        if (string.IsNullOrWhiteSpace(line))
        {
            error = "The JSONL line is empty.";
            return false;
        }

        try
        {
            response = JsonSerializer.Deserialize<ProtocolResponse>(line, SerializerOptions);
        }
        catch (JsonException exception)
        {
            error = "Malformed JSONL line: " + exception.Message;
            return false;
        }
        catch (ArgumentException exception)
        {
            error = "Invalid JSONL line: " + exception.Message;
            return false;
        }
        catch (NotSupportedException exception)
        {
            error = "Unsupported JSONL line: " + exception.Message;
            return false;
        }

        if (response is null)
        {
            error = "The JSONL line did not contain a response object.";
            return false;
        }

        error = ValidateResponse(response);
        if (error is not null)
        {
            response = null;
            return false;
        }

        return true;
    }

    public static bool TryDeserializeRequest(string line, out ProtocolRequest? request, out string? error)
    {
        request = null;
        error = null;

        if (string.IsNullOrWhiteSpace(line))
        {
            error = "The JSONL line is empty.";
            return false;
        }

        try
        {
            request = JsonSerializer.Deserialize<ProtocolRequest>(line, SerializerOptions);
        }
        catch (JsonException exception)
        {
            error = "Malformed JSONL line: " + exception.Message;
            return false;
        }
        catch (ArgumentException exception)
        {
            error = "Invalid JSONL line: " + exception.Message;
            return false;
        }
        catch (NotSupportedException exception)
        {
            error = "Unsupported JSONL line: " + exception.Message;
            return false;
        }

        if (request is null)
        {
            error = "The JSONL line did not contain a request object.";
            return false;
        }

        if (!string.Equals(request.Type, "request", StringComparison.Ordinal))
        {
            error = "A request line must have type 'request'.";
            request = null;
            return false;
        }

        if (request.ProtocolVersion != CurrentProtocolVersion)
        {
            error = "Unsupported protocolVersion " + request.ProtocolVersion + ".";
            request = null;
            return false;
        }

        if (!ArgumentSchemas.Validate(request.Action, request.Args, out var argumentError))
        {
            error = argumentError ?? "The request arguments are invalid.";
            request = null;
            return false;
        }

        return true;
    }

    private static string? ValidateResponse(ProtocolResponse response)
    {
        switch (response.Type)
        {
            case "hello":
                if (response.ProtocolVersion is null)
                {
                    return "A hello line requires protocolVersion.";
                }

                if (string.IsNullOrWhiteSpace(response.EngineVersion))
                {
                    return "A hello line requires engineVersion.";
                }

                if (response.Pid is null or <= 0)
                {
                    return "A hello line requires a positive pid.";
                }

                return null;
            case "event":
                if (response.Seq is null)
                {
                    return "An event line requires seq.";
                }

                if (response.TsUtc is null)
                {
                    return "An event line requires tsUtc.";
                }

                if (string.IsNullOrEmpty(response.Phase))
                {
                    return "An event line requires phase.";
                }

                if (response.Message is null)
                {
                    return "An event line requires message.";
                }

                return null;
            case "progress":
                if (response.Seq is null)
                {
                    return "A progress line requires seq.";
                }

                if (response.TsUtc is null)
                {
                    return "A progress line requires tsUtc.";
                }

                if (string.IsNullOrEmpty(response.Phase))
                {
                    return "A progress line requires phase.";
                }

                if (response.BytesTransferred is < 0 || response.BytesTotal is < 0)
                {
                    return "A progress line cannot carry negative byte counts.";
                }

                return null;
            case "result":
                if (response.Ok is null)
                {
                    return "A result line requires ok.";
                }

                if (response.Code is null)
                {
                    return "A result line requires code.";
                }

                if (response.Message is null)
                {
                    return "A result line requires message.";
                }

                if (response.CurrentState is null)
                {
                    return "A result line requires currentState.";
                }

                if (response.RestoredState is null)
                {
                    return "A result line requires restoredState.";
                }

                if (response.NextStep is null)
                {
                    return "A result line requires nextStep.";
                }

                return null;
            default:
                return "Unknown response line type '" + response.Type + "'.";
        }
    }

    private static ProtocolResponse ErrorResponse(string? error) => new()
    {
        Type = "result",
        Ok = false,
        Code = ErrorCode.Protocol,
        Message = error ?? "The JSONL line is invalid.",
        CurrentState = "unknown",
        RestoredState = "unchanged",
        NextStep = "Send one valid JSONL line.",
    };
}

internal sealed class VersionMatrixJsonConverter : JsonConverter<VersionMatrix>
{
    public override VersionMatrix Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            throw new JsonException("versions must be an array of component version entries.");
        }

        var components = JsonSerializer.Deserialize<VersionEntry[]>(ref reader, options)
            ?? Array.Empty<VersionEntry>();
        return new VersionMatrix { Components = components };
    }

    public override void Write(Utf8JsonWriter writer, VersionMatrix value, JsonSerializerOptions options)
        => JsonSerializer.Serialize(writer, value.Components, options);
}
