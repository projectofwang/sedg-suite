global using System.Diagnostics;
global using System.Globalization;
global using System.IO;
global using Sedg.UnitTests;

namespace Sedg.UnitTests;

using System.Collections;

/// <summary>Marks a public static parameterless void method as one test case.</summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class TestAttribute : Attribute
{
}

/// <summary>Thrown by an assertion that failed; the runner reports the case name plus expected/actual.</summary>
public sealed class TestFailedException : Exception
{
    public TestFailedException(string message)
        : base(message)
    {
    }
}

/// <summary>Minimal assertion helper: every failure names the case, the expected, and the actual value.</summary>
public static class Assert
{
    /// <summary>The case the runner currently executes; set before each invocation.</summary>
    public static string CurrentCase { get; internal set; } = string.Empty;

    public static void Equal<T>(T expected, T actual)
    {
        if (expected is IEnumerable enumerable && actual is IEnumerable && expected is not string)
        {
            var expectedItems = enumerable.Cast<object?>().ToArray();
            var actualItems = ((IEnumerable)actual).Cast<object?>().ToArray();
            if (expectedItems.SequenceEqual(actualItems))
            {
                return;
            }

            Fail("sequence contents differ", Render(expectedItems), Render(actualItems));
            return;
        }

        if (EqualityComparer<T>.Default.Equals(expected, actual))
        {
            return;
        }

        Fail("values differ", Render(expected), Render(actual));
    }

    public static void Equal<T>(IEnumerable<T> expected, IEnumerable<T> actual)
    {
        var expectedArray = expected.ToArray();
        var actualArray = actual.ToArray();
        if (expectedArray.SequenceEqual(actualArray))
        {
            return;
        }

        Fail("sequence contents differ", Render(expectedArray), Render(actualArray));
    }

    public static void Equal(string? expected, string? actual)
    {
        if (string.Equals(expected, actual, StringComparison.Ordinal))
        {
            return;
        }

        Fail("strings differ", expected, actual);
    }

    public static void Equal<T>(T expected, T actual, IEqualityComparer<T> comparer)
    {
        if (comparer is not null && comparer.Equals(expected, actual))
        {
            return;
        }

        Fail("values differ", Render(expected), Render(actual));
    }

    public static void True(bool condition)
    {
        if (condition)
        {
            return;
        }

        Fail("condition is not true", "True", "False");
    }

    /// <summary>Same assertion with a named reason surfaced on failure.</summary>
    public static void True(bool condition, string? reason)
    {
        if (condition)
        {
            return;
        }

        Fail(reason, "True", "False");
    }

    public static void False(bool condition)
    {
        if (!condition)
        {
            return;
        }

        Fail("condition is not false", "False", "True");
    }

    /// <summary>Same assertion with a named reason surfaced on failure.</summary>
    public static void False(bool condition, string? reason)
    {
        if (!condition)
        {
            return;
        }

        Fail(reason, "False", "True");
    }

    public static void Null(object? value)
    {
        if (value is null)
        {
            return;
        }

        Fail("value is not null", "null", Render(value));
    }

    public static void NotNull(object? value)
    {
        if (value is not null)
        {
            return;
        }

        Fail("value is null", "not null", "null");
    }

    public static TException Throws<TException>(Action action) where TException : Exception
    {
        try
        {
            action();
        }
        catch (Exception exception) when (exception is TException)
        {
            return (TException)exception;
        }
        catch (Exception exception)
        {
            Fail("a different exception was thrown", typeof(TException).Name, exception.GetType().Name);
        }

        Fail("the expected exception was not thrown", typeof(TException).Name, "no exception");
        return default!;
    }

    public static void Fail(string? reason, string? expected = null, string? actual = null)
    {
        var suffix = expected is null && actual is null
            ? string.Empty
            : " | expected: " + (expected ?? "null") + " | actual: " + (actual ?? "null");
        throw new TestFailedException("[" + CurrentCase + "] " + reason + suffix);
    }

    private static string Render(object? value)
        => value is null ? "null" : value.ToString() ?? "unknown";
}
