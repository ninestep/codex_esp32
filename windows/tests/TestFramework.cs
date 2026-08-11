using System.Reflection;

[AttributeUsage(AttributeTargets.Class)]
public sealed class TestClassAttribute : Attribute;
[AttributeUsage(AttributeTargets.Method)]
public sealed class TestMethodAttribute : Attribute;

public static class Assert
{
    public static void IsTrue(bool condition) { if (!condition) throw new Exception("Expected true."); }
    public static void AreEqual<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, got {actual}."); }
    public static T ThrowsExactly<T>(Action action) where T : Exception { try { action(); } catch (T error) { return error; } throw new Exception($"Expected {typeof(T).Name}."); }
}

public static class CollectionAssert
{
    public static void AreEqual<T>(ICollection<T>? expected, ICollection<T>? actual)
    {
        if (expected is null || actual is null || !expected.SequenceEqual(actual)) throw new Exception("Collections differ.");
    }
}

public static class Program
{
    public static async Task<int> Main()
    {
        int passed = 0, failed = 0;
        foreach (Type type in Assembly.GetExecutingAssembly().GetTypes().Where(t => t.GetCustomAttribute<TestClassAttribute>() is not null)) {
            object instance = Activator.CreateInstance(type)!;
            foreach (MethodInfo method in type.GetMethods().Where(m => m.GetCustomAttribute<TestMethodAttribute>() is not null)) {
                try { if (method.Invoke(instance, null) is Task task) await task; Console.WriteLine($"PASS {type.Name}.{method.Name}"); passed++; }
                catch (Exception error) { Exception failure = error.InnerException ?? error; Console.Error.WriteLine($"FAIL {type.Name}.{method.Name}: {failure}"); failed++; }
            }
        }
        Console.WriteLine($"{passed} passed, {failed} failed");
        return failed == 0 ? 0 : 1;
    }
}
