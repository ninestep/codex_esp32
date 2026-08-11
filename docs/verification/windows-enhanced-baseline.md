# Windows Enhanced Mode Baseline

Date: 2026-08-11

## Automated environment evidence

- Host and minimum product baseline: Windows 10 22H2, build 19045, x64. Newer supported Windows x64 releases remain in scope.
- Repository-local SDK: .NET SDK 10.0.302, runtime 10.0.10.
- UI baseline: .NET 10 WPF. WinUI 3 / Windows App SDK 1.8 and 2.3 both compiled but crashed in `Microsoft.UI.Xaml.dll` on this build-19045 graphics stack before business code ran, so the shell was moved to WPF while preserving the platform/core layers.
- Windows App Runtime 1.8 x64 packages are registered, but are no longer required by the WPF shell. WebView2 runtime, Bluetooth adapter/driver, Developer Mode, MSIX signing, ChatGPT/Codex process integrity, and custom GATT visibility remain hardware/manual checks.

## Completed automated checks

- `CodexRemote.Protocol` and `CodexRemote.Core` compile as platform-neutral `net10.0` assemblies.
- Repository-local deterministic tests cover envelope CRC, fragments, ADPCM validation, sequence-gap silence padding, final text emission, and layout validation.
- The full solution builds in Release with 0 warnings and 0 errors. Protocol (4), Core (2), and Windows (9) runners pass: 15 tests total.
- `CodexRemote.WindowsApp.exe` opens a targetable `Codex Remote 设置` window on Windows 10 build 19045 after the WPF migration.

## Manual exit-gate checklist

- [ ] Record `winver`, Bluetooth adapter, and driver versions on the current Windows 10 22H2 x64 host.
- [ ] Confirm the paired ESP32 exposes both HOGP and all custom BLE v1 characteristics.
- [ ] Record ChatGPT/Codex version, process name, and integrity level.
- [ ] Confirm WebView2 Runtime if the final login flow embeds browser content.
- [ ] Confirm Developer Mode and the selected MSIX signing identity.

No BLE, ASR, input-injection, packaging, or physical-device success is inferred from the automated build.
