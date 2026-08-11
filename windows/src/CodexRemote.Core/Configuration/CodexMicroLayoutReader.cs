namespace CodexRemote.Core.Configuration;

public sealed class CodexMicroLayoutReader : ICodexMicroLayoutReader
{
    private static readonly string[] ControlKeys = ["slot1", "slot2", "slot3", "slot4", "slot5", "slot6"];
    private static readonly string[] DirectionKeys = ["up", "right", "down", "left"];

    public MicroControlLayout Read(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Codex configuration was not found.", path);
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        bool inSection = false;
        foreach (string raw in File.ReadLines(path)) {
            string line = raw.Trim();
            if (line.StartsWith('[')) { inSection = line == "[desktop.codex-micro-layout]"; continue; }
            if (!inSection || line.Length == 0 || line.StartsWith('#')) continue;
            int equals = line.IndexOf('=');
            if (equals <= 0) throw new FormatException("Invalid Codex Micro layout entry.");
            string value = line[(equals + 1)..].Trim();
            if (value.Length < 2 || value[0] != '"' || value[^1] != '"') throw new FormatException("Layout values must be quoted strings.");
            values[line[..equals].Trim()] = value[1..^1];
        }
        string Required(string key) => values.TryGetValue(key, out string? value) && value.Length is > 0 and <= 48 ? value : throw new FormatException($"Missing or invalid layout key: {key}");
        return new(ControlKeys.Select(Required).ToArray(), Required("encoderMode"), DirectionKeys.Select(Required).ToArray());
    }
}
