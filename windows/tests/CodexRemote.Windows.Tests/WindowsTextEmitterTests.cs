using CodexRemote.Windows.Input;

namespace CodexRemote.Windows.Tests;

[TestClass]
public sealed class WindowsTextEmitterTests
{
    [TestMethod]
    public void UnicodeBatchesPreserveUtf16CodeUnitsAndKeyPairs()
    {
        WindowsTextEmitter.Native.Input[] events = WindowsTextEmitter.CreateUnicodeBatches("中A😀\n").SelectMany(batch => batch).ToArray();
        Assert.AreEqual(10, events.Length);
        char[] expected = "中A😀\n".ToCharArray();
        for (int index = 0; index < expected.Length; index++) {
            Assert.AreEqual((ushort)expected[index], events[index * 2].Union.Keyboard.Scan);
            Assert.AreEqual((ushort)expected[index], events[index * 2 + 1].Union.Keyboard.Scan);
            Assert.AreEqual(0x0004u, events[index * 2].Union.Keyboard.Flags);
            Assert.AreEqual(0x0006u, events[index * 2 + 1].Union.Keyboard.Flags);
        }
    }

    [TestMethod]
    public void LongTextIsSplitWithoutBreakingInputPairs()
    {
        WindowsTextEmitter.Native.Input[][] batches = WindowsTextEmitter.CreateUnicodeBatches(new string('x', 130)).ToArray();
        Assert.AreEqual(3, batches.Length); Assert.AreEqual(128, batches[0].Length); Assert.AreEqual(128, batches[1].Length); Assert.AreEqual(4, batches[2].Length);
    }
}
