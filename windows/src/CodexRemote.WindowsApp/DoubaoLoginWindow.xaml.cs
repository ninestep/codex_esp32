using System.Text.Json;
using System.IO;
using System.Windows;
using CodexRemote.Windows.Speech;

namespace CodexRemote.WindowsApp;

public partial class DoubaoLoginWindow : Window
{
    private readonly DoubaoCredentialStore store;

    public DoubaoLoginWindow(DoubaoCredentialStore store)
    {
        this.store = store;
        InitializeComponent();
        Loaded += LoginWindowLoaded;
    }

    private async void LoginWindowLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            Status.Text = "正在打开豆包登录页…";
            await Browser.EnsureCoreWebView2Async();
            Browser.CoreWebView2.Settings.UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36";
            Browser.CoreWebView2.NavigationCompleted += (_, args) =>
            {
                Status.Text = args.IsSuccess ? "请在网页中完成登录，然后点击右侧按钮。" : $"豆包页面加载失败：{args.WebErrorStatus}";
            };
            Browser.CoreWebView2.Navigate("https://www.doubao.com/chat/");
        }
        catch (Exception error)
        {
            Status.Text = $"无法初始化登录页面：{error.Message}";
        }
    }

    private async void CompleteLoginClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            Status.Text = "正在检查登录状态…";
            await Browser.EnsureCoreWebView2Async();
            var cookies = await Browser.CoreWebView2.CookieManager.GetCookiesAsync("https://www.doubao.com/");
            string cookieHeader = string.Join("; ", cookies.Where(cookie => cookie.Domain.EndsWith("doubao.com", StringComparison.OrdinalIgnoreCase)).Select(cookie => $"{cookie.Name}={cookie.Value}"));
            string deviceId = await ReadIdentifierAsync("samantha_web_web_id");
            string webId = await ReadIdentifierAsync("__tea_cache_tokens_497858");
            if (string.IsNullOrWhiteSpace(deviceId)) throw new InvalidDataException("未找到 Device ID，请确认豆包账号已登录并进入聊天页面。");
            if (string.IsNullOrWhiteSpace(webId)) throw new InvalidDataException("未找到 Web ID，请刷新豆包页面后重试。");
            var value = new DoubaoCredentials(cookieHeader, deviceId, webId);
            value.Validate();
            await store.SaveAsync(value, CancellationToken.None);
            DialogResult = true;
        }
        catch (Exception error)
        {
            Status.Text = $"未检测到有效登录：{error.Message}";
        }
    }

    private async Task<string> ReadIdentifierAsync(string key)
    {
        string scriptResult = await Browser.ExecuteScriptAsync($"localStorage.getItem('{key}')");
        string? raw = JsonSerializer.Deserialize<string?>(scriptResult);
        if (string.IsNullOrWhiteSpace(raw)) return string.Empty;
        try
        {
            using JsonDocument document = JsonDocument.Parse(raw);
            return FindIdentifier(document.RootElement);
        }
        catch (JsonException)
        {
            return raw.Trim();
        }
    }

    private static string FindIdentifier(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.String) return element.GetString()?.Trim() ?? string.Empty;
        if (element.ValueKind == JsonValueKind.Number) return element.GetRawText();
        if (element.ValueKind == JsonValueKind.Object)
        {
            if (element.TryGetProperty("web_id", out JsonElement webId))
            {
                string direct = FindIdentifier(webId);
                if (!string.IsNullOrWhiteSpace(direct)) return direct;
            }
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (property.Value.ValueKind is not (JsonValueKind.Object or JsonValueKind.Array)) continue;
                string nested = FindIdentifier(property.Value);
                if (!string.IsNullOrWhiteSpace(nested)) return nested;
            }
        }
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in element.EnumerateArray())
            {
                if (item.ValueKind is not (JsonValueKind.Object or JsonValueKind.Array)) continue;
                string nested = FindIdentifier(item);
                if (!string.IsNullOrWhiteSpace(nested)) return nested;
            }
        }
        return string.Empty;
    }
}
