using System.ComponentModel;
using System.Runtime.InteropServices;
using CodexRemote.Core;

namespace CodexRemote.Windows.Input;

public sealed record ForegroundTarget(nint WindowHandle, uint ProcessId, string ProcessName);

public sealed class WindowsTextEmitter : ITextEmitter
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventUnicode = 0x0004;
    private const uint KeyEventKeyUp = 0x0002;
    private const int MaximumEventsPerBatch = 128;

    public object CaptureTarget()
    {
        nint window = Native.GetForegroundWindow();
        if (window == 0 || !Native.IsWindow(window)) throw new InvalidOperationException("No valid foreground window is available.");
        Native.GetWindowThreadProcessId(window, out uint processId);
        string name;
        try { name = System.Diagnostics.Process.GetProcessById(checked((int)processId)).ProcessName; }
        catch { name = "unknown"; }
        return new ForegroundTarget(window, processId, name);
    }

    public ValueTask<TextEmissionResult> EmitAsync(object target, string text, CancellationToken cancellationToken)
    {
        if (target is not ForegroundTarget locked) return ValueTask.FromResult(new TextEmissionResult(false, "Invalid target."));
        if (!Native.IsWindow(locked.WindowHandle)) return ValueTask.FromResult(new TextEmissionResult(false, "The PTT target window has closed."));
        if (Native.IsIconic(locked.WindowHandle)) return ValueTask.FromResult(new TextEmissionResult(false, "The PTT target window is minimized."));
        if (Native.GetForegroundWindow() != locked.WindowHandle) return ValueTask.FromResult(new TextEmissionResult(false, "Focus changed after PTT began; text was retained."));
        if (string.IsNullOrEmpty(text)) return ValueTask.FromResult(new TextEmissionResult(true));

        try {
            foreach (Native.Input[] batch in CreateUnicodeBatches(text)) {
                cancellationToken.ThrowIfCancellationRequested();
                uint sent = Native.SendInput((uint)batch.Length, batch, Marshal.SizeOf<Native.Input>());
                if (sent != batch.Length) {
                    int error = Marshal.GetLastPInvokeError();
                    string detail = error == 0 ? "Input was blocked, possibly by UIPI integrity levels." : new Win32Exception(error).Message;
                    return ValueTask.FromResult(new TextEmissionResult(false, detail));
                }
            }
            return ValueTask.FromResult(new TextEmissionResult(true));
        } catch (Exception error) when (error is not OperationCanceledException) {
            return ValueTask.FromResult(new TextEmissionResult(false, error.Message));
        }
    }

    internal static IEnumerable<Native.Input[]> CreateUnicodeBatches(string text)
    {
        var events = new List<Native.Input>(MaximumEventsPerBatch);
        foreach (char codeUnit in text) {
            events.Add(Native.Input.Unicode(codeUnit, keyUp: false));
            events.Add(Native.Input.Unicode(codeUnit, keyUp: true));
            if (events.Count == MaximumEventsPerBatch) { yield return events.ToArray(); events.Clear(); }
        }
        if (events.Count > 0) yield return events.ToArray();
    }

    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct Input
        {
            internal uint Type;
            internal InputUnion Union;
            internal static Input Unicode(char value, bool keyUp) => new() { Type = InputKeyboard, Union = new() { Keyboard = new() { Scan = value, Flags = KeyEventUnicode | (keyUp ? KeyEventKeyUp : 0) } } };
        }
        [StructLayout(LayoutKind.Explicit)] internal struct InputUnion { [FieldOffset(0)] internal KeyboardInput Keyboard; [FieldOffset(0)] internal MouseInput Mouse; [FieldOffset(0)] internal HardwareInput Hardware; }
        [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput { internal ushort VirtualKey; internal ushort Scan; internal uint Flags; internal uint Time; internal nuint ExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] internal struct MouseInput { internal int X; internal int Y; internal uint MouseData; internal uint Flags; internal uint Time; internal nuint ExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] internal struct HardwareInput { internal uint Message; internal ushort ParameterLow; internal ushort ParameterHigh; }
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(nint window);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsIconic(nint window);
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
        [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, [In] Input[] inputs, int size);
    }
}
