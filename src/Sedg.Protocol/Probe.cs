using System.Text.Json.Serialization;

namespace Sedg.Protocol;

/// <summary>
/// Tri-state status value: Known, Unknown(reason), NotApplicable.
/// The app never fabricates a value for an Unknown probe.
/// </summary>
public sealed class Probe<T>
{
    [JsonConstructor]
    private Probe(ProbeState state, T? value = default, string? reason = null)
    {
        switch (state)
        {
            case ProbeState.Known:
                if (value is null)
                {
                    throw new ArgumentException("A known probe requires a value.", nameof(value));
                }

                State = state;
                Value = value;
                Reason = null;
                break;
            case ProbeState.Unknown:
                if (string.IsNullOrWhiteSpace(reason))
                {
                    throw new ArgumentException("An unknown probe requires a non-empty reason.", nameof(reason));
                }

                State = state;
                Value = default;
                Reason = reason;
                break;
            case ProbeState.NotApplicable:
                State = state;
                Value = default;
                Reason = null;
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(state), state, "Unsupported probe state.");
        }
    }

    public ProbeState State { get; }

    public T? Value { get; }

    public string? Reason { get; }

    public static Probe<T> Known(T value) => new(ProbeState.Known, value);

    public static Probe<T> Unknown(string reason) => new(ProbeState.Unknown, default, reason);

    public static Probe<T> NotApplicable() => new(ProbeState.NotApplicable);
}

public enum ProbeState
{
    Known,
    Unknown,
    NotApplicable,
}
