# Codex Remote 双端远程控制工具设计

日期：2026-08-02
状态：设计已确认，阶段 1 实施计划已编写
目标平台：macOS + ESP32-S3-Touch-AMOLED-2.16
后续平台：Windows

## 1. 摘要

Codex Remote 由 macOS 客户端和 ESP32-S3-Touch-AMOLED-2.16 设备端组成。用户继续在 Ghostty 中使用 Codex CLI；Mac 客户端观察 Codex 状态、维护 Ghostty terminal 与 Codex session 的映射、接收设备控制、管理虚拟麦克风，并通过 BLE 与设备同步。设备显示最多八个活跃会话，支持选择会话、控制终端滚动和按住实体键语音输入。

首阶段交付技术原型，验证两条高风险链路：

1. Ghostty terminal、透明 Codex launcher instance 与 Codex session 的稳定映射。
2. 设备音频协议、Mac 虚拟麦克风和豆包输入法之间的语音输入链路。

当前没有设备实物。首阶段可验证 Mac 真实链路、模拟设备协议和 ESP-IDF 固件编译，不能声称 BLE、麦克风、触摸、PMU、功耗或屏幕通过真机验收。

## 2. 目标与范围

### 2.1 产品目标

- 在设备端查看最多八个 Ghostty Codex 会话的当前状态。
- 用白、蓝、绿、琥珀、红和灰六种视觉语义区分会话状态。
- 点击设备会话后，将对应 Ghostty terminal 切到前台并进入设备详情页。
- 在详情页通过触摸手势控制对应终端滚动。
- 在详情页通过触摸按钮或 GPIO18 单击/双击操作对应终端的 Enter 和 Esc。
- 在详情页按住 GPIO18 用户键采集语音，松开后结束输入。
- 将设备音频通过 BLE 送入 Mac 虚拟麦克风，并触发豆包输入法的可配置快捷键。
- 支持低亮状态屏保、自定义图片轮播和最终息屏。
- 保持设备协议与操作系统无关，为 Windows 和 Codex 官方客户端预留适配器。

### 2.2 技术原型范围

- SwiftUI 菜单栏应用与设置窗口。
- 透明 `codex` shim、Codex hook helper 和会话映射注册。
- Ghostty 1.3.1 AppleScript 枚举、聚焦、页签选择、滚动和定向按键输入。
- Codex CLI 0.146.0 hooks 状态源。
- App Server 只读观察能力验证；不满足隔离条件时关闭该增强。
- 保守的非结构化等待输入文本分类。
- BlackHole 2ch 检测、音频输出、默认输入设备切换与恢复。
- 豆包输入法 0.9.4 快捷键配置与真实 WAV 注入测试。
- BLE 协议 codec、设备模拟器、IMA-ADPCM 音频和图片同步模拟。
- 基于 Waveshare ESP-IDF 5.5+ BSP/示例的固件工程和完整编译。
- LVGL 设备界面、会话状态机、按键、触摸和省电逻辑的可测试实现。

### 2.3 不进入技术原型的范围

- OTA、正式安装包、签名、公证和自动更新。
- 自有 macOS 或 Windows 虚拟音频驱动。
- Windows 客户端实现。
- Codex 官方桌面客户端适配器实现。
- 实时终端内容镜像、屏幕捕获或 OCR。
- 完整 Codex 对话在设备端显示或持久化。
- GIF、视频和 PNG 屏保动画。
- microSD 图片浏览器。
- 无实物条件下的硬件通过声明。

## 3. 已确认约束

- 用户在 Ghostty 中仍输入 `codex`；测试终端中的该命令可以透明经过 shim。
- 设备必须先进入一个有效会话，才允许使用语音。
- 进入会话时，Mac 必须先成功聚焦对应 Ghostty terminal。
- 详情页复用 GPIO18：短按发送 Enter，双击发送 Esc，按住约 350 ms 进入 PTT，松开结束。
- 详情页保留触摸“取消 Esc”和“确定 Enter”按钮作为即时备用操作。
- 首页最多八个活跃会话，首屏四个，纵向滑动查看第二屏。
- 设备只显示一行状态摘要，不显示完整 Codex 回复。
- 语音目标为豆包输入法。
- 技术原型接受 BlackHole 2ch。
- 当前没有 ESP32 实物。
- Git 提交、系统依赖安装、用户级 Codex 配置和 shell 配置修改仍需单独确认。

## 4. 架构决策

采用 A+ 架构：平台无关核心契约 + macOS 原生适配器。

```text
ESP32 + LVGL
      │
      │ versioned BLE protocol
      ▼
Codex Remote domain model
      ├─ SessionProvider
      ├─ TerminalController
      ├─ BluetoothTransport
      ├─ AudioInputBridge
      ├─ HotkeyController
      ├─ SettingsStore
      └─ AssetStore
             │
             ├─ macOS: SwiftUI/CoreBluetooth/Core Audio/AppleScript
             └─ Windows: WinUI/WinRT/WASAPI/Win32 adapters
```

首版不引入 Rust FFI 或 Tauri。项目先共享协议、状态语义和 golden fixtures；Windows 启动后再根据重复代码规模决定是否抽取 Rust core。Swift UI 类型、Ghostty 对象和 CoreBluetooth 类型不得进入 BLE contract。

## 5. 领域模型

### 5.1 会话标识

系统维护三段映射：

```text
terminal_target_id ↔ launcher_instance_id ↔ provider_session_id
```

- `terminal_target_id`：平台私有终端目标。macOS 首版为 Ghostty terminal ID。
- `launcher_instance_id`：透明 shim 每次启动生成的随机 ID。
- `provider_session_id`：Codex hook 提供的 session ID。
- `remote_session_id`：Mac 内部对设备公开的稳定会话 ID，不暴露平台对象。
- `session_key`：BLE 连接期使用的短键；连接重建后可以重新分配。

### 5.2 会话记录

```text
RemoteSession
├─ remoteSessionID
├─ providerSessionID
├─ launcherInstanceID
├─ terminalTargetID
├─ displayTitle
├─ workingDirectoryLabel
├─ state
├─ statusDetail
├─ stateSource
├─ confidence
├─ unread
├─ selected
├─ capabilities
└─ updatedAt
```

`statusDetail` 是长度受限的一行摘要。Mac 不向设备发送完整 evidence 或 assistant message。

## 6. 会话状态模型

### 6.1 状态语义

| 状态 | 颜色 | 含义 |
|---|---|---|
| `idle` | 白色 | 会话可用，没有未处理结果 |
| `working` | 蓝色 | 当前 Codex 回合正在运行 |
| `completeUnread` | 绿色 | 回合完成，用户尚未进入详情查看 |
| `requiresInput` | 琥珀色 | Codex 等待审批、确认、选择或回答 |
| `error` | 红色 | Codex 回合失败、映射冲突或不可恢复错误 |
| `offline` | 灰色 | Mac、状态源或终端目标不可达 |

颜色必须配合圆点、文字和图形使用，不能成为唯一状态表达。

### 6.2 事件优先级

状态证据按以下优先级合并：

1. App Server 结构化请求与状态标志。
2. Codex lifecycle hooks。
3. `Stop.last_assistant_message` 的保守文本分类。
4. shim 退出状态与 Ghostty terminal 存活状态。

App Server 增强只在能够旁路观察时启用。它不能创建替代 thread、注入 prompt、持有审批、改变模型或并发接管 Ghostty CLI session。

### 6.3 基础转换

| 事件 | 新状态 |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `requiresInput` |
| App Server `waitingOnApproval` | `requiresInput` |
| App Server `waitingOnUserInput` | `requiresInput` |
| `Stop` + 阻塞性确认文本 | `requiresInput` |
| `Stop` + 普通完成回复 | `completeUnread` |
| 用户进入详情查看完成结果 | `idle` |
| 回合失败或不可恢复错误 | `error` |
| terminal 或状态源消失 | `offline` |

文本分类必须同时识别“要求用户回复”和“后续工作因此暂停”。以下表达属于正例：

- “请回复‘确认推送’，我会继续推送。”
- “确认后我会继续执行。”
- “需要你选择一个方案后才能继续。”

“如果你愿意，我也可以继续优化”属于建议性结尾，不得标为 `requiresInput`。

### 6.4 排序

默认按状态优先级和最近活动排序：

```text
requiresInput / error
working
completeUnread
idle
offline
```

同优先级按 `updatedAt` 降序。设备最多接收八个活跃会话。

## 7. Ghostty 与 Codex 映射

### 7.1 启动流程

用户在 Ghostty 输入透明包装后的 `codex`：

1. shim 生成 `launcher_instance_id`。
2. Mac helper 立即读取 Ghostty 前台 window、selected tab、focused terminal 和工作目录。
3. helper 注册 `terminal_target_id ↔ launcher_instance_id`。
4. shim 设置 `CODEX_REMOTE_INSTANCE_ID`。
5. shim 使用 `exec` 启动真实 Codex，原样转发参数、标准流和退出码。
6. `SessionStart` hook 从 JSON 读取 `session_id`，从环境读取 `launcher_instance_id`。
7. Mac 完成三段绑定并分配 `remote_session_id`。

如果 Ghostty 不是前台或没有 focused terminal，shim 明确提示本次会话未加入远程控制，然后继续启动真实 Codex。系统不得按工作目录猜测目标。

### 7.2 进入详情

```text
Device SELECT_SESSION(session_key)
  → Mac 校验 session、terminal 和 provider
  → Ghostty focus terminal
  → Ghostty select tab / activate window
  → Mac SELECT_ACK(success)
  → Device 进入详情
```

任何校验失败都返回明确错误；设备留在首页并禁用 PTT。

### 7.3 滚动

详情页中部是滚动触控区。设备将手势距离转换为有符号增量，Mac 调用 Ghostty `send mouse scroll`。手指与内容的移动方向保持一致。录音期间禁用滚动。

### 7.4 Enter 与 Esc

设备通过 GPIO18 手势或详情页触摸按钮发送 `TERMINAL_KEY(session_key, key, request_id)`，其中 `key` 只允许 `enter` 或 `escape`。Mac 重新校验当前设备详情会话、三段映射和目标 terminal，必要时将对应 Ghostty terminal 切到前台，再调用 Ghostty AppleScript `send key`：

```text
enter  → send key "enter" to terminal
escape → send key "escape" to terminal
```

Mac 通过 `ControlToDevice` 返回相同 `request_id` 的成功或失败结果。每次用户动作只发送一个请求；超时或失败后设备提示错误，不自动重试，避免对确认、取消等有副作用的操作重复输入。首页、屏保、息屏、映射失效和 PTT 期间禁用这两个按键。

## 8. Mac 客户端

### 8.1 应用形态

SwiftUI 菜单栏应用提供：

- BLE 配对、连接和重连状态。
- 会话列表、三段映射和状态来源诊断。
- 豆包快捷键与触发模式设置。
- BlackHole 检测、测试和输入设备恢复。
- 屏保模式、超时、亮度和图片集。
- BLE 延迟、音频丢帧和缓冲 underrun 指标。

### 8.2 组件

```text
SessionCoordinator
├─ CodexCLIProvider
├─ GhosttyAppleScriptController
├─ CoreBluetoothTransport
├─ VirtualMicrophonePipeline
├─ HotkeyController
├─ ScreensaverAssetManager
├─ SettingsStore
└─ DiagnosticsStore
```

`SessionCoordinator` 只处理领域事件，不直接依赖 AppleScript、CoreBluetooth、Core Audio 或 SwiftUI。

### 8.3 Hook 传输

hook helper 通过权限为 `0600` 的本地 Unix socket 向 Mac App 发送事件。App 不可达时，helper 将事件写入有界本地队列并立即退出，不阻塞 Codex。队列只保存状态所需字段，不保存完整 transcript。

### 8.4 权限

Mac App 需要：

- Bluetooth 权限。
- 音频输入/输出相关权限。
- Accessibility 权限，用于豆包快捷键。
- Automation 权限，用于控制 Ghostty。
- BlackHole 2ch 系统音频组件。

安装 BlackHole、修改 shell/Codex 用户配置和建立持久 shim 前必须再次取得用户确认，并提供恢复方式。

## 9. BLE 协议

### 9.1 角色

- ESP32：BLE peripheral。
- Mac/Windows 客户端：BLE central。
- 设备只绑定一台已配对电脑。

### 9.2 GATT 划分

| Characteristic | 方向 | 用途 | 可靠性 |
|---|---|---|---|
| `ControlToHost` | 设备 → Mac | 选择、滚动、Enter/Esc、PTT、资源 ACK、设备错误 | indication；滚动可使用 notify |
| `ControlToDevice` | Mac → 设备 | 控制 ACK、聚焦结果、错误和重同步请求 | write with response |
| `StateToDevice` | Mac → 设备 | 会话快照和增量 | 快照使用 write with response；增量使用 write without response + sequence |
| `AudioToHost` | 设备 → Mac | 低延迟音频帧 | notify，不重传过期帧 |
| `AssetToDevice` | Mac → 设备 | JPEG 分块和清单 | write without response；通过 `ControlToHost` 分块确认 + CRC |
| `DeviceInfo` | 设备 → Mac | 协议、固件、能力和电量 | read；变化时 notify |

`ControlToHost` 和 `ControlToDevice` 分开定义，避免把 central 写入与 peripheral notification 混为一条方向不明确的通道。所有需要严格确认的动作都携带 `request_id`；滚动和过期音频允许按序号丢弃。

### 9.3 Envelope

所有逻辑消息使用统一 envelope；超过协商 ATT payload 的消息先按 envelope 编码，再切成带 message ID、分块序号和总块数的传输片段：

```text
protocol_version
message_type
sequence
payload_length
flags
payload
crc32
```

接收端只有在完整重组并通过长度与 CRC32 校验后才交给领域层。大版本不兼容时拒绝控制和音频，仅保留升级提示。重连后 Mac 先发送完整快照；设备丢弃旧连接的 session key 和增量序列。

### 9.4 优先级

```text
PTT control > Audio > Enter/Esc > Session control > State > Asset
```

PTT 开始时立即暂停图片同步和复杂图片解码。录音结束后才恢复资源传输。

## 10. 音频与豆包输入法

### 10.1 设备采集

Waveshare 官方示例提供 16 kHz 双声道音频采样。设备端将双声道转换为单声道 16-bit PCM，再按 20 ms 分帧并编码为 IMA-ADPCM 4-bit。

每帧包含：

- 序号与采样时间戳。
- 独立 predictor 和 step index。
- 320 个采样对应的 ADPCM 数据。
- 帧级校验。

独立帧允许解码器在丢帧后立即恢复。技术原型不加入复杂降噪、回声消除算法或音乐级编码。

### 10.2 PTT 时序

```text
GPIO18 press in active detail
  → I2S pre-roll capture starts locally
  → hold threshold reaches about 350 ms
  → PTT_BEGIN with buffered pre-roll
  → Mac validates selected session and terminal
  → Mac saves current input device
  → Mac prepares BlackHole and hotkey
  → Mac triggers Doubao start
  → Mac drains jitter buffer to BlackHole
  → PTT_READY

GPIO18 release
  → PTT_END(last_sequence)
  → Mac receives/drains final frames
  → Mac triggers Doubao stop
  → configurable tail delay
  → restore previous input device
  → PTT_FINISHED
```

如果用户在约 350 ms 内松开，设备丢弃预录音频并进入点击判定：等待约 250 ms 双击窗口；没有第二次点击则发送 Enter，窗口内完成第二次点击则发送 Esc。进入 PTT 后，本次按键不会再产生 Enter 或 Esc。阈值允许在设置中微调，但默认值和状态机必须写入跨端测试向量。

快捷键支持两种模式：

- 按住型：开始时 key-down，结束时 key-up。
- 切换型：开始和结束各触发一次。

协议不写死豆包的具体快捷键。

### 10.3 恢复事务

切换输入设备前，Mac 写入最小恢复记录，包括原输入设备、快捷键模式和 session。正常结束后清除。应用启动时发现未完成事务，必须发送 key-up、停止音频、恢复输入设备并报告上次异常；不得自动继续录音。

## 11. 设备端

### 11.1 技术栈

- ESP-IDF 5.5+。
- Waveshare 官方 BSP 和 ESP-IDF 示例组件。
- LVGL v9，与官方 ESP-IDF 示例保持一致。
- ESP-IDF NimBLE host；首版仅使用 BLE，不启用 Classic Bluetooth。
- ES7210/I2S 音频链路基于官方音频示例。
- AXP2101、CST9220、CO5300 使用官方 BSP/驱动。

### 11.2 首页

- 480×480，2×2 状态卡片。
- 第一页显示会话 1–4，纵向滑动进入会话 5–8。
- 卡片显示状态、项目名、一行摘要和相对时间。
- 状态用边框、圆点和文字共同表达。
- 首页 GPIO18 不触发语音。

### 11.3 详情页

- 顶部显示返回、会话名称、目录简称和状态。
- 摘要区显示一行 `statusDetail` 和持续时间。
- 中部大面积滑动区控制 Ghostty 滚动。
- 底部左右分别显示“取消 Esc”和“确定 Enter”触摸按钮，中间显示 GPIO18 操作提示。
- 触摸按钮立即发送对应按键，不等待实体键的双击窗口。
- PTT 期间锁定触摸滚动、Enter/Esc 和会话切换。
- 映射丢失时立即停止录音并退出详情。

### 11.4 实体键

- GPIO18：详情页短按发送 Enter，双击发送 Esc，按住约 350 ms 开始 PTT，松开结束。
- GPIO18 按下即启动仅驻留内存的音频预录；识别为短按或双击时立即丢弃，识别为长按时作为 PTT 开头发送。
- PWR：短按息屏/唤醒；长按保留 PMU 电源语义。
- BOOT/GPIO0：只用于烧录、恢复和开发诊断。
- 首页的 GPIO18 不发送 Enter、Esc 或语音事件。
- 息屏状态下第一次 GPIO18 按下只唤醒；这次完整的按下和松开均被消费，不发送 Enter、Esc 或 PTT。

### 11.5 屏保与省电

默认时间线：

1. 0–60 秒：正常界面。
2. 60 秒：进入低亮屏保。
3. 5 分钟：关闭 AMOLED，BLE 保持连接。
4. Mac 断连 30 分钟：降低广播、刷新和传感器活动频率。

技术原型不默认进入会完全断开 BLE 的深睡眠。所有时间和亮度均可配置。琥珀或红色事件到达时短暂点亮八秒，然后回到此前省电阶段。录音期间禁止进入屏保或息屏。

### 11.6 自定义图片轮播

屏保支持：

- 状态屏保。
- 自定义图片轮播。
- 纯黑息屏。

Mac 将图片裁剪或适配为 480×480 基线 JPEG，经 BLE 分块传输。设备使用清单和 CRC 校验完整资源集；只有整组通过校验后才原子切换。轮播默认每 30 秒切换，亮度限制在正常亮度的 15%–25%，并加入轻微随机位移或缩放。五分钟后仍关闭屏幕。

实际图片数量和单图上限在取得设备、确认分区表和 JPEG 解码峰值内存后确定。技术原型只承诺协议、模拟存储和资源切换，不承诺真机容量。

## 12. Windows 与官方客户端扩展

Windows 复用领域模型、BLE contract、状态语义和 golden fixtures，实现以下 adapters：

| Port | macOS | Windows |
|---|---|---|
| `SessionProvider` | Codex shim/hooks | PowerShell/cmd shim/hooks |
| `TerminalController` | Ghostty AppleScript | Windows Terminal/UI Automation/Win32 |
| `BluetoothTransport` | CoreBluetooth | WinRT BluetoothLE |
| `AudioInputBridge` | Core Audio + BlackHole | WASAPI + 虚拟音频设备 |
| `HotkeyController` | CGEvent/Accessibility | Win32 SendInput |
| UI | SwiftUI | WinUI 3 或 WPF |

Ghostty 当前没有 Windows 发行版，因此 Port 必须命名为 `TerminalController`，不能把 Ghostty 写入领域层。未来 Codex 官方客户端通过新增 `CodexDesktopSessionProvider` 和相应 terminal/surface controller 接入；ESP32 协议保持不变。

## 13. 错误处理

### 13.1 PTT 状态机

```text
idle → preparing → recording → draining → restoring → idle
                       │
                       └→ failed → cleanup → idle
```

失败清理固定执行：释放快捷键、停止音频、恢复输入设备、记录错误、通知设备。BLE 断开、Ghostty 映射丢失、应用退出和音频 underrun 超限都走同一清理路径。

### 13.2 关键行为

- 映射冲突：隔离冲突会话，不猜测目标。
- Enter/Esc 发送失败或超时：显示错误，不自动重试。
- BlackHole 缺失：禁用 PTT，指出缺少依赖。
- 权限缺失：禁用对应能力，指出缺少的系统权限。
- App Server 不兼容：关闭增强，保留 hooks 路线。
- 图片同步中断：旧图片集继续生效。
- 音频帧丢失：丢弃过期帧并从下一独立帧恢复。
- 协议不兼容：停止控制和音频，只显示升级状态。
- Mac App 退出：恢复音频和快捷键，并让设备进入离线状态。

## 14. 安全与隐私

- 设备只接受已加密并绑定的单台电脑。
- 控制、音频和图片 characteristic 要求加密连接。
- ESP32 不长期保存录音；Mac 默认不落盘录音。
- Mac 不持久化完整 prompt、回复、豆包识别文本或 transcript。
- 文本分类在内存中处理最后一条 assistant message，生成摘要后丢弃原文。
- 日志只记录 ID、状态来源、帧序号、长度、延迟和丢包率。
- 恢复出厂设置清除 BLE bonding 和图片资源。

## 15. 测试与验收

### 15.1 当前可真实验证

- Ghostty 中的透明 `codex` 启动和三段映射。
- 同目录多会话区分。
- 真实 Ghostty 聚焦、页签选择和滚动。
- 通过 Ghostty `send key` 向已映射 terminal 定向发送 Enter 和 Esc。
- hooks 状态转换及状态来源诊断。
- 阻塞性确认与建议性结尾分类。
- 在用户确认安装或系统已存在 BlackHole 2ch 后，验证 WAV → BlackHole → 豆包输入法真实识别。
- 正常结束、模拟 BLE 断开和应用恢复后的麦克风恢复。
- 图片预处理、分块、CRC 和模拟设备原子切换。

### 15.2 当前可编译或模拟验证

- ESP-IDF 固件完整编译并生成 ELF、BIN 和分区表。
- LVGL 页面状态机、手势和 PTT 锁定测试。
- GPIO18 短按、双击、长按、临界时序、去抖和预录音频处理测试。
- Enter/Esc 请求去重、ACK、超时不重试和错误反馈测试。
- Mac/ESP codec 共享 golden fixtures。
- IMA-ADPCM 固定音频向量。
- 音频乱序、丢帧和重复帧恢复。
- 图片同步中断和资源集切换。
- 模拟设备驱动会话、滚动、Enter/Esc、PTT、音频和资源协议闭环。

### 15.3 设备到手后的真机门禁

- CoreBluetooth MTU、连接间隔、吞吐、延迟和重连。
- ES7210 增益、底噪、双麦克风转单声道和语音清晰度。
- BLE 音频进入豆包后的真实识别率。
- GPIO18 去抖、短按 Enter、双击 Esc、长按 PTT、临界时序和息屏首次按键语义。
- CST9220 坐标、滑动方向和滚动手感。
- AMOLED 亮度、轮播、息屏和烧屏风险。
- AXP2101、电量、PWR、唤醒和实际功耗。
- 息屏 BLE 保持、长时间稳定性和异常恢复。

### 15.4 技术原型完成标准

1. 真实 Ghostty/Codex 映射通过。
2. 真实 Ghostty 聚焦、滚动和定向 Enter/Esc 通过。
3. 状态引擎覆盖结构化事件、hooks 和文本补充规则。
4. 用户确认安装或系统已存在 BlackHole 2ch 后，WAV → BlackHole → 豆包输入法真实链路通过；在依赖尚未获准安装时，此项明确保持未验收，不以模拟结果替代。
5. Mac 与模拟设备完成会话、滚动、Enter/Esc、PTT、音频和图片协议闭环。
6. ESP-IDF 固件完整编译通过。
7. 跨端协议 golden tests 一致。
8. 交付清楚标记所有真机未验证项。

## 16. 实施阶段

### 阶段 1：Mac 高风险链路

实现 shim、hook receiver、会话状态机、Ghostty controller、BlackHole 音频管线和豆包快捷键测试。

### 阶段 2：共享协议与模拟设备

冻结 v1 协议，建立 codec、golden fixtures、设备模拟器、ADPCM 和图片同步。

### 阶段 3：ESP-IDF 固件

基于官方 BSP 建立 BLE、LVGL、音频、按键、屏保和资源组件，完成编译与模拟验证。

### 阶段 4：真机验收

设备到手后完成 BLE、音频、触摸、电源、功耗和长稳测试，再决定连接参数、图片容量和最终省电默认值。

### 阶段 5：产品化与扩展

在单独确认后加入安装、签名、OTA、Windows adapters 和 Codex 官方客户端 Provider。

## 17. 主要风险

| 风险 | 处理方式 |
|---|---|
| App Server 不能旁路观察 CLI | 将其降级为可选增强，以 hooks 为基础 |
| 非结构化等待输入误判 | 使用保守双条件规则、测试正反例并显示置信来源 |
| Ghostty AppleScript 预览 API 变化 | 隔离 controller，启动时探测版本和能力 |
| 豆包不接受 BlackHole 默认输入 | 在 Mac 高风险链路阶段先做真实验证 |
| BLE 音频吞吐不足 | 使用 20 ms 独立 IMA-ADPCM 帧，真机调整连接参数 |
| AMOLED 屏保耗电或烧屏 | 降亮、位移、轮播和最终息屏；真机测量后调整 |
| 应用崩溃后默认输入未恢复 | 使用恢复事务记录和启动恢复 |
| 无实物导致错误完成声明 | 分离真实、模拟、编译和真机门禁 |

## 18. 参考资料

- [Waveshare ESP32-S3-Touch-AMOLED-2.16 板卡文档](https://docs.waveshare.net/ESP32-S3-Touch-AMOLED-2.16/)
- [Waveshare ESP-IDF 开发与示例](https://docs.waveshare.net/ESP32-S3-Touch-AMOLED-2.16/Development-Environment-Setup-ESP-IDF/)
- [Ghostty AppleScript 官方文档](https://ghostty.org/docs/features/applescript)
- [Ghostty 官方文档与平台范围](https://ghostty.org/docs)
- [Codex Hooks 官方文档](https://learn.chatgpt.com/docs/hooks)
- [Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex Windows 官方说明](https://learn.chatgpt.com/docs/windows/windows-sandbox)
- [Arkey 项目](https://github.com/shuhari04/arkey)
