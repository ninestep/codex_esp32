# Windows App 增强模式开发计划

**状态：** 待实施

**目标平台：** Windows 11 22H2+，首发 x64；ARM64 在 x64 真机闭环后评估

**当前基线：** ESP32 现有固件、BLE v1、Codex Micro HOGP 和 macOS 增强模式

## 1. 目标

新增 Codex Remote Windows Companion App，复用现有设备和协议，实现以下闭环：

```text
ESP32 ES7210 -> IMA-ADPCM -> 自定义 BLE GATT
    -> Windows Companion -> 豆包 WebSocket ASR
    -> Unicode 文本 -> 当前目标输入框
```

Windows 版本需要提供：

- 自动发现、连接和重连 Codex Remote 设备。
- 显示连接状态、设备信息和电量。
- 接收 PTT 开始、音频帧和 PTT 结束消息。
- 解码 IMA-ADPCM，并把 16 kHz 单声道 PCM 流式发送给豆包 ASR。
- 将最终识别文本注入用户开始 PTT 时锁定的目标窗口，不自动发送。
- 从 `%USERPROFILE%\.codex\config.toml` 读取六键、旋钮和摇杆配置并同步到设备。
- 提供托盘菜单、设置窗口、登录状态和语音水波纹动画。

## 2. 本期范围

### 2.1 包含

- Windows 增强模式 Companion App。
- 现有 BLE v1 的 C# 等价实现和兼容测试。
- Windows BLE GATT central。
- 豆包网页登录、凭据保护和 WebSocket ASR。
- Windows Unicode 文本注入。
- 托盘、设置、诊断日志、打包和 Windows CI。
- 实体 ESP32 + Windows + ChatGPT/Codex 输入框端到端验收。

### 2.2 不包含

- 修改 BLE v1 UUID、消息布局或固件行为。
- 把 ESP32 麦克风注册成 Windows 系统虚拟麦克风。
- 恢复 BlackHole、微信输入法或其他虚拟音频链路。
- 移植旧 Ghostty、hooks、Codex CLI 会话控制。
- 让 Windows App 模拟 Codex Micro HID。
- 自动提交识别结果。
- 第一阶段支持 Windows 10、ARM64、商店发布或自动更新。

## 3. 已冻结的架构决策

### 3.1 保持固件和 BLE contract 不变

Windows 必须兼容现有六个 characteristic、BLE envelope、fragment、CRC、message codec 和 IMA-ADPCM 格式。Windows 端不得自行增加 fallback 协议，也不得绕过 fragment 层直接解释 characteristic payload。

Windows 首版使用 C# 实现协议。所有 codec 必须通过现有 `macos/Fixtures/ble-v1` 和跨语言固定向量测试。只有在协议长期频繁扩展、C# 与 Swift/C 出现明显维护成本后，才评估把 `firmware/components/codex_remote_core` 包装成 Windows DLL。

### 3.2 使用分层 C# 解决方案

```text
windows/
├── CodexRemote.Windows.sln
├── Directory.Build.props
├── src/
│   ├── CodexRemote.Protocol/       # 无 WinUI、WinRT 依赖
│   ├── CodexRemote.Core/           # PTT、音频、识别协调状态机
│   ├── CodexRemote.Windows/        # BLE、WebView2、DPAPI、SendInput
│   └── CodexRemote.WindowsApp/     # WinUI 3、托盘和设置窗口
├── tests/
│   ├── CodexRemote.Protocol.Tests/
│   ├── CodexRemote.Core.Tests/
│   └── CodexRemote.Windows.Tests/
└── README.md
```

- `CodexRemote.Protocol` 和 `CodexRemote.Core` 使用纯 .NET API，可在 macOS 开发机运行单元测试。
- `CodexRemote.Windows` 隔离 WinRT 和 Win32 API。
- `CodexRemote.WindowsApp` 只负责装配和界面，不解释 BLE 数据。
- UI 采用 WinUI 3；系统托盘采用 `System.Windows.Forms.NotifyIcon`。

### 3.3 系统能力通过 port 隔离

核心协调器只依赖以下接口：

```csharp
public interface IBluetoothTransport { }
public interface IAudioInputSession { }
public interface IRecognitionSession { }
public interface ITextEmitter { }
public interface ICredentialStore { }
public interface ICodexMicroLayoutReader { }
```

测试使用确定性 fake；单元测试不得扫描真实蓝牙、打开登录窗口、写系统凭据或向当前窗口发送按键。

### 3.4 文字注入锁定 PTT 起始目标

PTT 开始时记录前台窗口和进程；识别结束后只向同一目标注入。若目标已关闭、权限级别不匹配或窗口不再可用，则保留识别文本并明确提示失败，不把文字发送到新的前台应用。

Windows 使用 `SendInput` 和 `KEYEVENTF_UNICODE`，不覆盖剪贴板。普通权限进程不能向管理员权限窗口注入，产品必须显示这一限制，不自动提升权限。

### 3.5 豆包网页接口属于可变外部依赖

Windows 端复刻当前 Mac App 已验证的 Cookie、localStorage 和 WebSocket 行为，但不把网页内部接口视为稳定公共 API。登录字段或 ASR 协议变化时必须明确失败并记录脱敏诊断，不切换到其他识别服务伪装成功。

## 4. 依赖和授权门禁

开始实现前需要确认并锁定：

- 当前受支持的 .NET LTS SDK 和 Windows App SDK 版本。
- `Microsoft.WindowsAppSDK`、`Microsoft.Web.WebView2` 和测试框架版本。
- 凭据保护使用 Win32 DPAPI 封装，避免保存明文 Cookie。
- 首发打包采用 MSIX 还是自包含 unpackaged 可执行文件。

新增 NuGet 依赖、修改 CI、增加代码签名、创建发布 tag、修改 BLE contract 或烧录固件均为独立门禁。计划获批不自动授权这些外部或共享变更。

## 5. 实施任务

任务按顺序执行。前一任务的退出条件未满足，不进入依赖它的任务。

### Task 0：建立 Windows 现场和工具链基线

**目标：** 在真实 Windows 机器确认系统、蓝牙、目标应用和构建工具条件。

**Files:**

- Create: `docs/verification/windows-enhanced-baseline.md`

**Steps:**

- [ ] 记录 Windows 版本、架构、蓝牙适配器和驱动版本。
- [ ] 记录 ChatGPT/Codex App 版本、进程名和普通/管理员权限状态。
- [ ] 确认 ESP32 能作为 Codex Micro/HID 配对，并记录设备实例。
- [ ] 确认 Windows 能发现自定义 service UUID，而不只识别 HID 服务。
- [ ] 安装并记录所选 .NET SDK、Windows App SDK 和 WebView2 Runtime。
- [ ] 在 Windows 机器验证 `dotnet --info`、开发者模式和 MSIX 签名条件。

**Exit gate:** 基线文档包含可复现的系统信息；Windows 能看到设备自定义 GATT 服务。若只能看到 HID，先排查配对、GATT 缓存和广播，不开始应用层开发。

### Task 1：创建解决方案并移植 BLE/ADPCM 协议

**目标：** 先证明 C# 与 Swift/C 对同一输入产生相同结果。

**Files:**

- Create: `windows/CodexRemote.Windows.sln`
- Create: `windows/Directory.Build.props`
- Create: `windows/src/CodexRemote.Protocol/CodexRemote.Protocol.csproj`
- Create: `windows/src/CodexRemote.Protocol/Ble/*`
- Create: `windows/src/CodexRemote.Protocol/Audio/ImaAdpcmCodec.cs`
- Create: `windows/tests/CodexRemote.Protocol.Tests/*`
- Create: `windows/README.md`

**Tests first:**

- [ ] BLE envelope 版本、sequence、payload 长度和 CRC。
- [ ] fragment 单包、多包、乱序、重复、超长和 message ID 切换。
- [ ] 所有 BLE message 类型的 encode/decode round trip。
- [ ] 现有 `macos/Fixtures/ble-v1` 全部通过。
- [ ] IMA-ADPCM 320 sample 编解码、非法 sample 数、非法 step index 和截断数据。
- [ ] 用固件 C encoder 生成固定 ADPCM 帧，C# 与 Swift decoder 输出逐 sample 一致。

**Verification:**

```powershell
dotnet test windows/CodexRemote.Windows.sln --filter CodexRemote.Protocol.Tests
```

```bash
swift test --package-path macos --filter 'BLEGoldenFixtureTests|IMAADPCMCodecTests' --disable-sandbox
zsh firmware/test/host/verify-golden-fixtures.zsh
```

**Exit gate:** 三端 fixture 一致；Protocol 项目不引用 WinUI、WinRT、WebView2 或 Windows-only API。

### Task 2：实现 Windows BLE transport

**目标：** 建立可测试的 GATT 连接状态机，再连接真实设备。

**Files:**

- Create: `windows/src/CodexRemote.Windows/Bluetooth/BluetoothUuids.cs`
- Create: `windows/src/CodexRemote.Windows/Bluetooth/BluetoothTransportStateMachine.cs`
- Create: `windows/src/CodexRemote.Windows/Bluetooth/WindowsBluetoothTransport.cs`
- Create: `windows/tests/CodexRemote.Windows.Tests/BluetoothTransportStateMachineTests.cs`

**Tests first:**

- [ ] Bluetooth unavailable、scanning、connecting、discovering、subscribing、ready 和 disconnected。
- [ ] 六个 characteristic 完整发现前不得进入 ready。
- [ ] 只订阅 `controlToHost`、`audioToHost` 和 `deviceInfo`。
- [ ] `controlToDevice` 使用带响应写入，写失败向上返回。
- [ ] MTU/最大写入长度变化时仍使用 BLE v1 fragment codec。
- [ ] 重复设备、超时、断线、蓝牙关闭、系统休眠和恢复。
- [ ] 旧连接回调不得污染新连接 generation。

**Hardware verification:**

- [ ] 发现并连接真实 ESP32。
- [ ] 读取 `deviceInfo`，显示型号、固件版本和电量。
- [ ] 断开设备后状态立即变化；重新上电后自动恢复。
- [ ] 连续重连 20 次无重复订阅和事件倍增。

**Exit gate:** transport 能稳定收发真实 BLE v1 数据；尚未实现 ASR 时，音频包只进入诊断 sink，不伪造识别成功。

### Task 3：移植 Companion 协调器和配置同步

**目标：** 复刻当前 `CompanionAudioCoordinator` 的请求去重、PTT 状态和布局同步语义。

**Files:**

- Create: `windows/src/CodexRemote.Core/Companion/CompanionAudioCoordinator.cs`
- Create: `windows/src/CodexRemote.Core/Companion/CompanionAudioSnapshot.cs`
- Create: `windows/src/CodexRemote.Core/Configuration/CodexMicroLayoutReader.cs`
- Create: `windows/tests/CodexRemote.Core.Tests/CompanionAudioCoordinatorTests.cs`
- Create: `windows/tests/CodexRemote.Core.Tests/CodexMicroLayoutReaderTests.cs`

**Tests first:**

- [ ] 收到 `deviceInfo` 后读取 `%USERPROFILE%\.codex\config.toml` 并发送 `microControlLayout`。
- [ ] 配置缺失、字段非法和越界时明确记录错误，不发送半有效布局。
- [ ] `pttBegin`、`audioFrame`、`pttEnd` 的正常和非法状态。
- [ ] 重复 request ID 返回缓存结果且不重复副作用。
- [ ] malformed fragment、sequence gap、resync 和断线中止。
- [ ] 增强模式忽略 session、scroll 和 terminal 控制消息。

**Verification:**

```powershell
dotnet test windows/CodexRemote.Windows.sln --filter CodexRemote.Core.Tests
```

**Exit gate:** fake transport 可完整驱动连接、布局同步和一次 PTT 事务；断线不会留下 recording/processing 伪状态。

### Task 4：实现音频管线和诊断

**目标：** 将 BLE ADPCM 帧转换为连续 PCM，并为识别和水波纹提供稳定输入。

**Files:**

- Create: `windows/src/CodexRemote.Core/Audio/SpeechAudioInputBridge.cs`
- Create: `windows/src/CodexRemote.Core/Audio/AudioDiagnostics.cs`
- Create: `windows/src/CodexRemote.Core/Audio/WaveformLevelReducer.cs`
- Create: `windows/tests/CodexRemote.Core.Tests/SpeechAudioInputBridgeTests.cs`

**Tests first:**

- [ ] 正常帧按 sequence 顺序进入识别 session。
- [ ] sequence gap 按现有 Mac 语义补静音，重复帧不重复追加。
- [ ] 非法 ADPCM、识别 append 失败、取消和断线。
- [ ] PTT end 等待最终结果，但有明确超时和取消路径。
- [ ] 空文本不注入；settled/final 文本只提交一次。
- [ ] RMS/峰值 reducer 对静音保持低位，对语音平滑变化。

**Exit gate:** 使用 fake recognition session 完成 100 次 PTT 循环，内存稳定、状态归零、音频帧和补帧统计可核对。

### Task 5：实现豆包登录、凭据保护和流式 ASR

**目标：** 在 Windows 复刻当前 Mac App 已验证的豆包识别链路。

**Files:**

- Create: `windows/src/CodexRemote.Windows/Speech/DoubaoCredentials.cs`
- Create: `windows/src/CodexRemote.Windows/Speech/DoubaoCredentialStore.cs`
- Create: `windows/src/CodexRemote.Windows/Speech/DoubaoLoginController.cs`
- Create: `windows/src/CodexRemote.Windows/Speech/DoubaoRecognitionSession.cs`
- Create: `windows/tests/CodexRemote.Windows.Tests/DoubaoCredentialsTests.cs`
- Create: `windows/tests/CodexRemote.Windows.Tests/DoubaoRecognitionResultStateTests.cs`

**Steps:**

- [ ] 先测试 Cookie header、必需标识、脱敏日志和失效凭据。
- [ ] 使用 WebView2 打开豆包登录页，读取目标域 Cookie 和必需 localStorage 字段。
- [ ] 使用当前用户 DPAPI 加密序列化凭据；退出登录删除本地密文和 WebView2 会话数据。
- [ ] 使用 `ClientWebSocket` 连接当前 ASR endpoint，保持现有 PCM 格式和消息语义。
- [ ] 测试中只使用录制 fixture/fake server，不提交真实 Cookie。
- [ ] 真实登录后完成短句、长句、连续句、停顿和网络中断测试。

**Security gate:** 日志、异常、测试快照、crash dump 和 Git diff 不得包含 Cookie、device ID、web ID 或完整 WebSocket URL query。

**Hardware exit gate:** 实体设备连续完成 20 次中文语音识别，结果完整且没有稳定复现的首尾丢字。

### Task 6：实现目标窗口锁定和 Unicode 文本注入

**目标：** 把最终文字安全写入正确窗口，不依赖剪贴板。

**Files:**

- Create: `windows/src/CodexRemote.Windows/Input/ForegroundTarget.cs`
- Create: `windows/src/CodexRemote.Windows/Input/WindowsTextEmitter.cs`
- Create: `windows/tests/CodexRemote.Windows.Tests/WindowsTextEmitterTests.cs`

**Tests first:**

- [ ] 基本中文、ASCII、换行、emoji 和 surrogate pair。
- [ ] 长文本分批发送并保持顺序。
- [ ] PTT 后用户切换窗口时拒绝注入。
- [ ] 目标窗口关闭、最小化或失去有效句柄。
- [ ] UIPI 权限级别不匹配时返回明确错误。
- [ ] 失败后保留最终文本供用户手动复制，且不自动发送 Enter。

**Hardware verification:**

- [ ] 记事本用于基础 Unicode smoke。
- [ ] ChatGPT/Codex 输入框用于真实目标验证。
- [ ] 普通权限目标成功；管理员权限目标显示受限提示。
- [ ] PTT 过程中切换到密码框或其他应用不会误注入。

**MVP exit gate:** Task 0 至 Task 6 全部通过，Windows 已完成真实“长按说话 -> 识别 -> 正确输入框出现完整文字”闭环。

### Task 7：实现托盘、设置和语音动画

**目标：** 补齐可日常使用的 Windows 界面，不把诊断项暴露成无意义设置。

**Files:**

- Create: `windows/src/CodexRemote.WindowsApp/App.xaml*`
- Create: `windows/src/CodexRemote.WindowsApp/AppModel.cs`
- Create: `windows/src/CodexRemote.WindowsApp/TrayIconService.cs`
- Create: `windows/src/CodexRemote.WindowsApp/Views/SettingsWindow.xaml*`
- Create: `windows/src/CodexRemote.WindowsApp/Views/SpeechOverlay.xaml*`
- Create: `windows/tests/CodexRemote.Windows.Tests/AppModelTests.cs`

**UI requirements:**

- [ ] 托盘紧凑显示设备、语音、设置和退出。
- [ ] 连接后显示电量；未知电量不得显示 `100%`。
- [ ] 设置页显示设备信息、豆包登录、自动连接和开机启动。
- [ ] 显示设备实际读取到的六键、旋钮内外圈和摇杆四方向配置。
- [ ] 语音 overlay 位于桌面下方，静音时静止，有输入时按 RMS 平滑放大。
- [ ] recording、processing、failed 和 disconnected 状态视觉明确。
- [ ] 不增加虚拟麦克风、输入法或旧会话控制设置。

**Exit gate:** 100%、125%、150% 和 200% 缩放下界面无裁切；主窗口关闭后托盘仍工作，退出命令能终止 BLE、ASR 和 WebView2 资源。

### Task 8：打包、日志、启动和 CI

**目标：** 形成可安装、可诊断和可重复构建的 Windows 产物。

**Files:**

- Create: `windows/Package.appxmanifest`
- Create: `windows/Scripts/package-app.ps1`
- Create: `windows/Scripts/install-local.ps1`
- Create: `docs/verification/windows-enhanced-release.md`
- Modify after approval: `.github/workflows/release.yml` or create a dedicated Windows workflow
- Modify after approval: `README.md`
- Modify after approval: `AGENTS.md`

**Steps:**

- [ ] Manifest 声明 Bluetooth 能力和明确的最低 Windows 版本。
- [ ] 生成 x64 Release 产物；调试符号与用户包分离。
- [ ] 日志按大小滚动，默认脱敏，不记录音频和识别全文。
- [ ] 实现显式开机启动开关；安装时不默认启用。
- [ ] Windows CI 运行 build、test、format 和 fixture 检查。
- [ ] Release 仅在 Windows job、现有 macOS job和固件验证全部通过后发布。
- [ ] 签名证书、发布 tag 和正式 Release 另行确认。

**Verification:**

```powershell
dotnet restore windows/CodexRemote.Windows.sln --locked-mode
dotnet build windows/CodexRemote.Windows.sln -c Release --no-restore
dotnet test windows/CodexRemote.Windows.sln -c Release --no-build
powershell -ExecutionPolicy Bypass -File windows/Scripts/package-app.ps1
```

**Exit gate:** 干净 Windows 用户环境可安装、启动、登录、连接、退出和卸载；卸载不删除用户未授权保留的其他 Codex 配置。

### Task 9：实体设备回归和发布候选验收

**目标：** 用真实硬件证明 Windows 增强模式可日常使用。

**Required matrix:**

- [ ] Windows 冷启动、App 冷启动、ESP32 冷启动的不同顺序。
- [ ] 设备断线重连 20 次。
- [ ] 系统睡眠/唤醒 10 次。
- [ ] 连续 PTT 100 次，包含 1 秒短句和 60 秒长输入。
- [ ] 网络断开、恢复、豆包登录失效和 WebSocket 中断。
- [ ] BLE 丢帧、重复帧、坏 CRC 和 resync。
- [ ] 中文、英文、数字、标点和 emoji 注入。
- [ ] ChatGPT、Codex App、记事本和普通浏览器输入框。
- [ ] 六键、旋钮和摇杆设置与设备详情页一致。
- [ ] 电量变化、低电量、完成提示音和需要输入提示音不回归。
- [ ] 同一固件重新连接 macOS 后原有增强模式不回归。

**Exit gate:** 验收记录包含版本、命令结果、设备日志和人工操作结果。编译、模拟器、单元测试或 BLE 单向收包都不能替代本任务。

## 6. 验证门禁汇总

每次实现提交前至少运行：

```powershell
dotnet build windows/CodexRemote.Windows.sln -c Release
dotnet test windows/CodexRemote.Windows.sln -c Release
```

涉及协议或 fixture 时追加：

```bash
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
```

涉及固件行为时追加 ESP-IDF build，并在单独确认后烧录。Windows 端适配本身不应触发固件烧录。

## 7. 里程碑和工期估算

| 里程碑 | 包含任务 | 预计工程日 | 交付结果 |
|---|---:|---:|---|
| M1 协议和连接 | Task 0-2 | 2-3 | Windows 稳定连接并读取设备信息 |
| M2 增强模式 MVP | Task 3-6 | 3-5 | 实体 PTT 识别并注入正确输入框 |
| M3 日常可用版本 | Task 7-8 | 2-4 | 托盘、设置、安装包和 CI |
| M4 发布候选 | Task 9 | 2-3 | 完整真机回归和发布证据 |

MVP 预计 5-8 个工程日；完整发布候选预计 9-15 个工程日。估算不包含豆包网页协议突变、Windows 蓝牙驱动异常、代码签名采购和商店审核时间。

## 8. 停止条件

出现以下任一情况时暂停后续任务并报告证据：

- Windows 无法同时访问设备的 HOGP 和自定义 GATT 服务。
- 现有 BLE fixture 在不修改 contract 的情况下无法兼容。
- 豆包网页登录或 ASR 在 Windows WebView2 中无法合法取得当前必需凭据。
- `SendInput` 无法对目标 ChatGPT/Codex 输入框稳定注入 Unicode。
- 方案需要新增驱动、管理员常驻、虚拟麦克风或修改固件协议。
- 真实凭据、用户音频或识别内容可能进入日志、测试产物或仓库。

任何停止条件都需要先完成安全的范围内取证，不能用 mock success、剪贴板 fallback 或自动提权掩盖问题。

## 9. 完成标准

Windows 增强模式只有同时满足以下条件才算完成：

- 固件和 BLE v1 contract 保持兼容。
- Windows App 能稳定连接、重连并显示真实电量。
- 长按实体按键能启动和结束 BLE 语音输入。
- 最终识别文本完整进入 PTT 开始时锁定的目标输入框。
- 单击 Enter、双击 Escape 和 Codex Micro 原生控制不回归。
- 六键、旋钮和摇杆配置在设备端正确显示。
- 凭据加密保存，日志和产物不泄露敏感信息。
- 单元测试、fixture、Windows 构建、安装测试和实体设备验收均有记录。
