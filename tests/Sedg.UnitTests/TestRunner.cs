namespace Sedg.UnitTests;

using System.Reflection;

/// <summary>
/// Reflection-based discovery: every non-generic public static class of this assembly grows cases
/// from its [Test]-marked public static methods. Classes run in fully-qualified-name order and
/// methods in metadata (declaration) order, so a run is deterministic. Exit 0 iff every case passes.
/// </summary>
public static class TestRunner
{
    public static int RunAll()
    {
        var cases = Discover();
        var failures = new List<string>();
        var passed = 0;

        foreach (var (type, method, name) in cases)
        {
            Assert.CurrentCase = name;
            try
            {
                method.Invoke(null, null);
                passed++;
                Console.WriteLine("PASS " + name);
            }
            catch (Exception exception)
            {
                var failure = exception.InnerException ?? exception;
                failures.Add(name + ": " + failure.Message);
                Console.WriteLine("FAIL " + name + ": " + failure.Message);
            }
        }

        Console.WriteLine();
        Console.WriteLine(passed + " passed, " + failures.Count + " failed, " + cases.Count + " total");
        if (failures.Count > 0)
        {
            Console.WriteLine("Failing cases:");
            foreach (var failure in failures)
            {
                Console.WriteLine("  " + failure);
            }

            return 1;
        }

        return 0;
    }

    private static List<(Type Type, MethodInfo Method, string Name)> Discover()
    {
        var cases = new List<(Type, MethodInfo, string)>();
        foreach (var type in typeof(TestRunner).Assembly.GetTypes())
        {
            if (type.IsAbstract && type.IsSealed && type.IsPublic)
            {
                foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.Static).OrderBy(m => m.MetadataToken))
                {
                    if (method.GetCustomAttribute<TestAttribute>() is not null && method.GetParameters().Length == 0 && method.ReturnType == typeof(void))
                    {
                        cases.Add((type, method, type.Name + "." + method.Name));
                    }
                }
            }
        }

        cases.Sort((left, right) => string.CompareOrdinal(left.Item3, right.Item3));
        return cases;
    }
}
