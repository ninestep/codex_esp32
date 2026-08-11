namespace CodexRemote.Windows.Speech;

public sealed record DoubaoCredentials(string CookieHeader, string DeviceId, string WebId)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(CookieHeader) || !CookieHeader.Contains('=', StringComparison.Ordinal)) throw new InvalidDataException("A valid cookie header is required.");
        if (string.IsNullOrWhiteSpace(DeviceId)) throw new InvalidDataException("Device ID is required.");
        if (string.IsNullOrWhiteSpace(WebId)) throw new InvalidDataException("Web ID is required.");
    }

    public override string ToString() => "DoubaoCredentials(CookieHeader=<redacted>, DeviceId=<redacted>, WebId=<redacted>)";
}
