# Codex Remote for Windows

Windows 10 22H2 (build 19045) or later x64 companion for the existing Codex Remote BLE v1 device. The WPF shell is compatible with the current host, while protocol and orchestration code remain UI-independent so tests never scan Bluetooth, open login UI, or inject input.

Build from the repository root:

```powershell
.\.dotnet\dotnet build windows\CodexRemote.Windows.sln -c Release
.\.dotnet\dotnet test windows\CodexRemote.Windows.sln -c Release
```

Hardware acceptance (BLE, WebView2 login, Doubao streaming ASR, and focused-window input) is tracked separately under `docs/verification/` and must not be inferred from a successful build.

Current Windows app version: `0.1.1`. GitHub Actions builds and runs all three deterministic Windows test runners on pull requests and `main`; `v*` tags also publish a framework-dependent `Windows-x64.zip` release asset. The target machine must have the .NET 10 Desktop Runtime installed.
