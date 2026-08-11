using CodexRemote.Windows.Speech;

namespace CodexRemote.Windows.Tests;

[TestClass]
public sealed class DoubaoRecognitionResultStateTests
{
    [TestMethod]
    public void LaterResultReplacesCandidateAndFinishReturnsCompleteText()
    {
        var state = new DoubaoRecognitionResultState(); state.ReceiveResult("这是前半段"); state.ReceiveResult("这是前半段和后半段");
        Assert.AreEqual("这是前半段和后半段", state.ReceiveFinish()); Assert.IsTrue(state.DidReceiveServerFinish);
    }

    [TestMethod]
    public void EndpointContainsRequiredIdentifiersButNeverCookie()
    {
        var credentials = new DoubaoCredentials("session=top-secret", "device id", "web id");
        string endpoint = DoubaoRecognitionSession.BuildEndpoint(credentials).AbsoluteUri;
        Assert.IsTrue(endpoint.Contains("device_id=device%20id", StringComparison.Ordinal));
        Assert.IsTrue(endpoint.Contains("web_id=web%20id", StringComparison.Ordinal));
        Assert.IsTrue(!endpoint.Contains("top-secret", StringComparison.Ordinal));
    }
}
