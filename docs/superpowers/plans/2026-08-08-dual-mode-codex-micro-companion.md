# Codex Micro 原生模式与 Mac App 增强模式开发计划

**状态：** 实施中；原生控制已完成，Mac App 增强模式基础件开发中

**目标平台：** ESP32-S3-Touch-AMOLED-2.16、macOS 15+；USB 麦克风兼容 Windows 作为独立验收项

**基线：** `main` / `v0.1.6` / `2ec7c0c`

## 1. 目标

在同一份 ESP32 固件中提供两种可切换的运行模式：

1. **原生 Codex Micro 模式**
   - ESP32 通过 BLE HOGP 直接连接 ChatGPT Desktop。
   - Agent 键、命令键、旋钮和状态回传由 ChatGPT Desktop 原生处理。
   - PTT 使用电脑系统麦克风，或使用 ESP32 暴露的标准 USB UAC 麦克风。
   - 不依赖 Codex Remote Mac App、Ghostty、Codex CLI shim、hooks、app-server 或 BlackHole。

2. **Mac App 增强模式**
   - Codex Micro 按键和状态仍优先通过 HOGP 直连 ChatGPT Desktop，不让 Mac App 虚拟 Codex Micro HID。
   - ESP32 麦克风通过项目自有 BLE GATT 发送 IMA-ADPCM 音频。
   - Codex Remote Mac App 使用 macOS Speech Framework 识别语音，并将最终文字定向写入 ChatGPT Desktop 输入框。
   - 不安装虚拟声卡，不把识别文字发送到未经确认的当前焦点，不自动发送消息。

## 2. 已冻结的架构决策

### 2.1 两种模式使用同一固件

固件保存明确的运行模式：

```c
typedef enum {
    CR_CONNECTION_MODE_UNCONFIGURED,
    CR_CONNECTION_MODE_NATIVE_MICRO,
    CR_CONNECTION_MODE_MAC_COMPANION,
} cr_connection_mode_t;
```

- 首次启动进入模式选择页，不凭空猜测旧设备应使用哪种模式。
- 模式保存到 NVS。
- 切换模式时停止 PTT、断开连接、保存配置并重启，不热切换 BLE profile。
- 恢复出厂设置会清除模式和配对信息；普通模式切换不自动清除全部 NVS。

### 2.2 按键始终优先直达 ChatGPT Desktop

Mac App 增强模式不实现虚拟 Codex Micro HID。设备按键直接发送兼容的 HOGP Report，原因是：

- ChatGPT Desktop 识别的是特定 HID descriptor、Report ID 和私有消息，不是普通键盘快捷键。
- 让普通 Mac App 虚拟同等 HID 设备需要额外系统扩展、签名和兼容性验证。
- Mac App 崩溃时，Agent 切换、Approve、Decline、Fork 和 Send 仍应可用。

Mac App 可接收镜像事件用于日志和 UI，但不得成为控制事件的必经路径。

### 2.3 两条语音链路互斥

原生模式：

```text
ESP32 ACT10 → ChatGPT Desktop → 系统当前麦克风
                                     ├─ Mac 内置麦克风
                                     └─ ESP32 USB UAC 麦克风
```

增强模式：

```text
ESP32 ES7210 → I2S → IMA-ADPCM → 自定义 BLE GATT
    → Codex Remote Mac App → Speech Framework
    → ChatGPT composer
```

增强模式不创建系统虚拟麦克风。若未来要求 ESP32 麦克风出现在所有 macOS 应用的输入设备列表中，应另立 AudioDriverKit/CoreAudio 项目，不纳入本计划。

### 2.4 ChatGPT 输入必须定向且可失败

增强模式的最终文字写入遵循以下规则：

- 只面向经过识别的 ChatGPT Desktop 进程。
- 先检查辅助功能权限，再定位可编辑 composer。
- 找不到目标输入框时明确失败，保留识别文本供用户复制，不向其他应用输入。
- 默认只填入，不自动发送。
- 不覆盖用户剪贴板。
- 不使用静默 fallback 掩盖 Accessibility Tree 不兼容。

### 2.5 私有兼容协议独立隔离

Codex Micro 兼容代码与现有 Codex Remote BLE v1 codec 分开：

- `codex_micro_hid` 只负责 HOGP、Report ID 6、JSON 分片和 Codex Micro RPC。
- `codex_remote_ble` 继续负责增强模式的控制/音频 GATT。
- 不把私有 Codex Micro JSON 方法塞进现有 BLE v1 envelope。
- 所有 buffer 有固定上限；拒绝超长、未终止或无法解析的 JSON。
- 兼容标识和私有方法集中定义，便于 ChatGPT 更新后单点调整。

OpenAI 官方文档只确认 Codex Micro 与 ChatGPT Desktop 的用户功能，并明确 Mic 键使用电脑麦克风；厂商 JSON-RPC 仍属于非公开兼容协议，不得写成 OpenAI 官方 API。

## 3. 目标运行结构

```text
firmware/main
    ├─ connection_mode_store
    ├─ input_router
    ├─ codex_micro_hid
    ├─ codex_remote_ble          # 仅增强音频/诊断
    ├─ codex_remote_audio
    ├─ codex_remote_usb_audio    # 仅原生 USB 麦克风
    └─ codex_remote_ui

macos/CodexRemoteApp
    ├─ CompanionAudioTransport
    ├─ CompanionAudioCoordinator
    ├─ SpeechAudioInputBridge
    ├─ ChatGPTComposerTextEmitter
    └─ CompanionSetupInspector
```

## 4. 模式能力矩阵

| 能力 | 原生 Codex Micro | Mac App 增强 |
|---|---|---|
| ChatGPT 原生 Agent 状态 | 必须 | 必须 |
| Agent/Approve/Decline/Fork/Send | HOGP 直连 | HOGP 直连 |
| Mac 内置麦克风 | 支持 | 非目标 |
| ESP32 USB 麦克风 | 支持 | 可关闭 |
| ESP32 无线麦克风 | 不支持 | BLE + Speech |
| Codex Remote Mac App | 不需要 | 必需 |
| Ghostty/hooks/app-server | 不需要 | 不需要 |
| BlackHole/虚拟声卡 | 不需要 | 不需要 |
| Windows USB 麦克风 | 必须验证 | 不适用 |
| Windows Codex Micro 集成 | 实验性验证 | 不适用 |

## 5. 实施顺序

以下任务必须按顺序推进。前一阶段的退出条件未满足，不进入依赖它的阶段。

### Task 0：建立基线和兼容性证据目录

**目标：** 固化改造前测试、固件尺寸和现场版本，后续所有回归有可比较基线。

**Files:**

- Create: `docs/verification/dual-mode-baseline.md`
- Create: `firmware/Fixtures/codex-micro/README.md`

**Steps:**

- [x] 记录当前 ChatGPT Desktop bundle ID、版本和构建号；若本机未安装，记录为现场阻塞，不猜测。
- [x] 记录 macOS 版本、ESP-IDF 版本、固件版本和目标板卡。
- [x] 运行全部 Swift 测试、固件 host 测试和 BLE golden fixtures。
- [x] 运行当前 ESP-IDF build，记录镜像尺寸和剩余分区空间。
- [x] 将 Core2 兼容项目中用于协议判断的公开字段整理为来源说明，不复制其 UI 或无关 Arduino 代码。
- [x] 保存官方文档和兼容项目链接、验证日期与“私有协议可能变化”的风险说明。

**Verification:**

```bash
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
(cd firmware && idf.py build)
```

**Exit gate:** 四项命令结果、当前已知失败和固件尺寸均写入基线文档。

### Task 1：建立可测试的模式配置与路由边界

**目标：** 先建立模式状态机，不在 `app_main.c` 中散布模式判断。

**Files:**

- Create: `firmware/components/codex_remote_core/include/codex_remote/connection_mode.h`
- Create: `firmware/components/codex_remote_core/src/connection_mode.c`
- Create: `firmware/components/codex_remote_platform/CMakeLists.txt`
- Create: `firmware/components/codex_remote_platform/include/codex_remote/connection_mode_store.h`
- Create: `firmware/components/codex_remote_platform/src/connection_mode_store.c`
- Create: `firmware/test/host/test_connection_mode.c`
- Modify: `firmware/components/codex_remote_core/CMakeLists.txt`
- Modify: `firmware/components/codex_remote_ui/include/codex_remote/ui.h`
- Modify: `firmware/components/codex_remote_ui/src/ui.c`
- Modify: `firmware/test/host/run-tests.zsh`
- Modify: `firmware/test/host/test_display_runtime.c`
- Modify: `firmware/main/CMakeLists.txt`
- Modify: `firmware/main/app_main.c`

**Steps:**

- [x] 先写模式迁移、非法 NVS 值、首次启动和切换确认的失败测试。
- [x] 实现平台无关的模式 reducer。
- [x] 实现 NVS adapter；NVS schema 使用独立 namespace 和显式版本。
- [x] `app_main` 只调用模式装配器，不直接解析 NVS。
- [x] 模式切换期间拒绝新输入并结束活跃 PTT。
- [x] 提供最小首次启动模式选择和二次确认页；完整设置页与状态展示留在 Task 8。
- [x] 首次启动停留在模式选择，不启动会产生歧义的 BLE 广播。
- [x] Task 2 完成前，原生模式不得误启动旧自定义 BLE transport；未实现状态必须明确失败。

**Verification:**

```bash
zsh firmware/test/host/run-tests.zsh test_connection_mode
zsh firmware/test/host/run-tests.zsh all
```

**Exit gate:** 模式行为由纯 C 测试覆盖，非法配置不会进入伪 ready 状态。

### Task 2：实现最小 Codex Micro HOGP 兼容层

**目标：** 只完成设备枚举、ChatGPT 检测和一组最小请求响应，不接入现有 UI 和音频。

**Files:**

- Create: `firmware/components/codex_micro_hid/CMakeLists.txt`
- Create: `firmware/components/codex_micro_hid/include/codex_micro/hid_transport.h`
- Create: `firmware/components/codex_micro_hid/include/codex_micro/vendor_frame.h`
- Create: `firmware/components/codex_micro_hid/include/codex_micro/rpc_codec.h`
- Create: `firmware/components/codex_micro_hid/src/hid_transport.c`
- Create: `firmware/components/codex_micro_hid/src/vendor_frame.c`
- Create: `firmware/components/codex_micro_hid/src/rpc_codec.c`
- Create: `firmware/test/host/test_codex_micro_vendor_frame.c`
- Create: `firmware/Fixtures/codex-micro/*.json`
- Modify: `firmware/sdkconfig.defaults`
- Modify: `firmware/main/CMakeLists.txt`

**Protocol requirements:**

- BLE name `Codex Micro`。
- HOGP/HID service，Vendor Usage Page `0xFF00`。
- Application Usage `0x01`，Report ID `6`。
- HOGP characteristic body 固定 63 bytes；JSON payload 每片最多 61 bytes。
- 输入按换行符完成一条 JSON 消息；输出按 61-byte 分片。
- 支持最小 host 请求：`sys.version`、`device.status`。
- 支持最小 device 事件：一个 Agent key press/release。
- 所有输入做长度、UTF-8、JSON 结构和 method 白名单校验。

**Steps:**

- [x] 先写 63-byte report、跨片重组、空 payload、超长 JSON、缺少换行和未知 method 测试。
- [x] 实现纯 framing，再实现 NimBLE HOGP adapter。
- [x] 不修改现有 `codex_remote_ble`，通过实验装配入口选择新 transport。
- [x] 构建通过后单独申请烧录授权。
- [ ] 真机配对后验证 macOS HID 枚举和 ChatGPT Desktop 检测。

**Verification:**

```bash
zsh firmware/test/host/run-tests.zsh test_codex_micro_vendor_frame
zsh firmware/test/host/run-tests.zsh all
(cd firmware && idf.py build)
```

**Hardware exit gate:**

- macOS 蓝牙显示已连接。
- ChatGPT Desktop 出现 Codex Micro 设置入口。
- ChatGPT 能发出至少一条已知 host 请求，ESP32 日志能有界解析。
- 一个 Agent key 的 press/release 被 ChatGPT 接收。

若当前 ChatGPT Desktop 不识别，暂停后续开发并记录版本、HID descriptor、PnP ID、配对和请求日志；不得用普通键盘快捷键伪装成功。

### Task 3：补齐原生按键、状态和设备 UI

**目标：** 原生模式达到可独立使用的 Codex Micro 控制器效果。

**Files:**

- Modify: `firmware/components/codex_micro_hid/src/rpc_codec.c`
- Create: `firmware/components/codex_micro_hid/include/codex_micro/micro_state.h`
- Create: `firmware/components/codex_micro_hid/src/micro_state.c`
- Create: `firmware/test/host/test_codex_micro_state.c`
- Modify: `firmware/components/codex_remote_ui/include/codex_remote/ui.h`
- Modify: `firmware/components/codex_remote_ui/src/ui.c`
- Modify: `firmware/main/app_main.c`

**Steps:**

- [x] 覆盖 `AG00` 至 `AG05`、`ACT06/07/08/09/10/12`、旋钮和方向事件。
- [x] 解析 `v.oai.thstatus`、灯光配置、focused app 等已验证 host 消息。
- [x] 为六个槽位建立独立 native view model，不复用含会话标题/目录的旧 `RemoteSession` 语义。
- [ ] UI 明确显示槽位、颜色、选中状态和错误；协议未提供标题时不生成假标题。
- [x] 单击、双击和长按由 ChatGPT 解释的事件只发送底层 press/release，不在固件重复触发动作。
- [x] PTT 的 `ACT10` press/release 与音频路由解耦。

> 2026-08-08 现场补充：当前 Codex Desktop 下发的 `v.oai.thstatus` 只有六个槽位的灯光字段
> `{id,c,b,e,s,sk,sa}`，不包含会话标题、目录、明确选中态或错误文本。设备 UI 因此只显示
> `AGENT 1...6`、槽位号、颜色和亮度，不伪造会话标题。上述第四项需在刷写后依据真实颜色/亮度
> 与 Codex Desktop 的对应关系完成硬件验收后再勾选。

**Verification:**

```bash
zsh firmware/test/host/run-tests.zsh test_codex_micro_state
zsh firmware/test/host/run-tests.zsh all
(cd firmware && idf.py build)
```

**Hardware exit gate:**

- 六个槽位状态与 ChatGPT Desktop 一致。
- 单击/双击会话切换、Approve、Decline、Fork、Send 均实测。
- ChatGPT 退出或蓝牙断开后设备不保留伪连接状态。

### Task 4：实现原生 USB UAC 麦克风

**目标：** ESP32 在原生模式下作为标准 USB 麦克风使用，不依赖 Mac App。

**Dependency gate:** `esp_device_uac` 或等价 TinyUSB 组件属于新增依赖；实施前单独确认版本和依赖变更。

**Files:**

- Create: `firmware/components/codex_remote_usb_audio/CMakeLists.txt`
- Create: `firmware/components/codex_remote_usb_audio/include/codex_remote/usb_audio.h`
- Create: `firmware/components/codex_remote_usb_audio/src/usb_audio.c`
- Create: `firmware/test/host/test_usb_audio_runtime.c`
- Modify: `firmware/main/idf_component.yml`
- Modify: `firmware/sdkconfig.defaults`
- Modify: `firmware/components/codex_remote_audio/src/audio_capture.c`
- Modify: `firmware/components/codex_remote_audio/include/codex_remote/audio_capture.h`
- Modify: `firmware/main/app_main.c`

**Steps:**

- [ ] 将 ES7210 采集与输出编码解耦，提供有界 PCM consumer 接口。
- [ ] 使用固定 ring buffer；underflow 输出静音，overflow 丢最旧帧并限频记录。
- [ ] 第一轮验证 `16 kHz / 16-bit / mono`；若 macOS 或 Windows 驱动不稳定，再评审 `48 kHz` 采集或重采样，不静默切换格式。
- [ ] USB UAC 未连接时不积压历史音频。
- [ ] PTT 前清空陈旧数据；未录音时持续提供符合 UAC 时序的静音帧。
- [ ] 验证 USB Serial/JTAG 与 UAC 的资源冲突。
- [ ] 第一阶段允许运行时只启用 UAC、日志走 UART；UAC 稳定后再评审 UAC + CDC 复合设备。
- [ ] 不启用会导致 Windows 无法枚举的 macOS-only descriptor 作为默认配置。

**Verification:**

```bash
zsh firmware/test/host/run-tests.zsh test_usb_audio_runtime
zsh firmware/test/host/run-tests.zsh all
(cd firmware && idf.py build)
```

**Hardware exit gate:**

- macOS `system_profiler SPAudioDataType SPUSBDataType` 能看到设备。
- QuickTime 或系统录音工具能录到清晰语音。
- ChatGPT PTT 使用 ESP32 USB 麦克风时首字、尾字不被截断。
- Windows 设备管理器和录音机完成一次无第三方驱动 smoke。
- BLE HOGP 与 USB UAC 同时工作至少 30 分钟，无重启、持续掉帧或连接抖动。

### Task 5：验证 HOGP 与增强音频 GATT 共存

**目标：** 在不破坏 ChatGPT 原生识别的前提下，让 Mac App 访问现有音频特征。

**Files:**

- Modify: `firmware/components/codex_remote_ble/src/ble_transport.c`
- Modify: `firmware/components/codex_remote_ble/include/codex_remote/ble_transport.h`
- Create: `firmware/components/codex_remote_ble/src/transport_router.c`
- Create: `firmware/test/host/test_dual_transport_runtime.c`
- Modify: `firmware/main/app_main.c`

**Preferred design:**

- HOGP 与自定义 GATT 使用同一 NimBLE host 和同一物理连接。
- GATT 服务表保持稳定，避免模式切换后 macOS 使用过期缓存。
- 原生模式不启动增强音频业务；增强模式允许 Mac App 订阅 `audioToHost`。
- HOGP 控制优先级高于音频 notify；音频拥塞时允许丢音频帧，不延迟 Approve/Decline。

**Steps:**

- [ ] 先写 transport router 测试，覆盖模式门禁、连接断开、订阅状态和发送优先级。
- [ ] 注册 HOGP 和现有自定义 GATT，但保持协议状态与 buffer 独立。
- [ ] Mac App 通过 service UUID 发现设备，不依赖广播名称 `Codex Remote`。
- [ ] 测量 16kHz ADPCM 连续传输时 HOGP 状态延迟和音频丢帧。
- [ ] 验证 Mac App 退出后 HOGP 控制不受影响。

**Compatibility gate:**

- ChatGPT Desktop 必须继续显示 Codex Micro 设置。
- 六个 Agent 状态和全部命令键必须继续工作。
- Mac App 必须能订阅自定义音频特征。
- 两个客户端共享系统 BLE 连接时不能反复断开或触发配对循环。

若 ChatGPT 拒绝带自定义 GATT 服务的设备，立即停止增强模式实施并向用户提交证据。后续只能在以下替代路线中重新确认一条：独立无线接收器、Mac App-only 语义映射，或放弃无线 ESP32 麦克风；不得擅自引入虚拟 HID/system extension。

### Task 6：将 Mac App 收缩为增强音频 Companion

**目标：** 建立不依赖 SessionService、Ghostty、hooks 和 Codex CLI 的最小运行时。

**Files:**

- Create: `macos/Sources/CodexRemoteMac/Client/CompanionAudioCoordinator.swift`
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/CompanionAudioTransport.swift`
- Create: `macos/Tests/CodexRemoteMacTests/CompanionAudioCoordinatorTests.swift`
- Modify: `macos/Sources/CodexRemoteMac/Audio/SpeechAudioInputBridge.swift`
- Modify: `macos/Sources/CodexRemoteApp/AppModel.swift`
- Modify: `macos/Sources/CodexRemoteApp/MenuBarContentView.swift`

**Steps:**

- [x] 为 companion coordinator 写 PTT begin、重复请求、识别失败、PTT end、异常分片和断线取消测试；乱序帧、sequence gap 与空识别继续由 `SpeechAudioInputBridgeTests` 覆盖。
- [x] 复用现有 BLE fragmentation、IMA-ADPCM codec 和 Speech session。
- [x] coordinator 只处理设备信息、PTT control、audio frame 和 action result，不查询 Codex CLI 会话。
- [x] App 启动时不创建 `SessionService`、IPC socket、Hook dispatcher 或 Ghostty controller。
- [ ] 菜单栏分别显示：HOGP 状态未知/正常、自定义音频 BLE 状态、Speech 状态、最近一次识别结果。
- [ ] 日志只记录序列、帧数、字节数和错误，不记录完整语音文本。

2026-08-09 增补：新增只读 `CodexMicroLayoutReader`，从 `~/.codex/config.toml` 的
`desktop.codex-micro-layout` 读取六个 Command Key 的实际槽位、显式 command/skill 覆盖和麦克风
分键状态。该读取器不修改 Codex 配置；动态同步到设备需要后续单独评审 BLE shared contract。

**Verification:**

```bash
swift test --package-path macos --filter CompanionAudioCoordinatorTests --disable-sandbox
swift test --package-path macos --filter SpeechAudioInputBridgeTests --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox
```

**Exit gate:** Mac App 在没有 Codex CLI、Ghostty 和 hooks 的测试环境中能独立启动并完成模拟音频识别事务。

### Task 7：实现 ChatGPT composer 定向写入

**目标：** 最终文字只写入 ChatGPT 当前 composer，不能误输入其他应用。

**Files:**

- Create: `macos/Sources/CodexRemoteMac/ChatGPT/ChatGPTApplicationLocator.swift`
- Create: `macos/Sources/CodexRemoteMac/ChatGPT/ChatGPTComposerTextEmitter.swift`
- Create: `macos/Sources/CodexRemoteMac/ChatGPT/AccessibilityTreeQuery.swift`
- Create: `macos/Tests/CodexRemoteMacTests/ChatGPTApplicationLocatorTests.swift`
- Create: `macos/Tests/CodexRemoteMacTests/ChatGPTComposerTextEmitterTests.swift`
- Modify: `macos/Sources/CodexRemoteMac/Audio/SpeechAudioInputBridge.swift`

**Steps:**

- [x] 已读取当前 Codex Desktop bundle metadata 和 Accessibility Tree：bundle ID `com.openai.codex`，版本 `26.803.41515`，build `6321`，进程显示名 `ChatGPT`；composer 为 `AXTextArea`，`AXDOMClassList` 含 `ProseMirror`，描述为“随心输入”，无 `AXIdentifier`。
- [x] 用 protocol 隔离运行应用发现和 AX 查询，单元测试使用确定性 fake tree。
- [x] 只接受已确认的 ChatGPT bundle identity；多实例或身份不明时失败。
- [x] 只接受目标进程当前聚焦且可编辑的 `AXTextArea`，并要求 DOM class 命中现场确认的 `ProseMirror`；侧栏搜索框、设置字段和其他应用均拒绝。
- [x] 通过 `AXSelectedText` 在当前选择或光标位置插入，不覆盖 composer 其余内容；身份或 DOM 特征变化时保持 fail-closed。
- [ ] 写入失败时返回识别文本和明确错误，App 提供手动复制按钮。
- [x] 不调用 Send；用户仍通过实体 Send 键或 ChatGPT UI 发送。
- [x] 保留 `CGEventRecognizedTextEmitter` 仅供旧测试迁移，最终 companion runtime 不使用它。

2026-08-09 现场修正：当前应用包是 `Codex.app` / `com.openai.codex`，只有进程显示名为
`ChatGPT`；增强模式按真实 bundle identity 定位。`SpeechAudioInputBridge` 默认 emitter 已切换为
定向 composer emitter，不再向系统全局焦点发送识别文字。

**Verification:**

```bash
swift test --package-path macos --filter 'ChatGPTApplicationLocatorTests|ChatGPTComposerTextEmitterTests' --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox
```

**Live exit gate:**

- ChatGPT 在前台和后台时各完成一次定向填入。
- 焦点位于其他应用、ChatGPT 设置页或无 composer 时均明确拒绝。
- 中文、英文、标点、长文本和空识别结果符合预期。
- 识别结果只填入，不自动发送。

### Task 8：重做设备和 Mac App 设置体验

**目标：** 用户能理解当前模式、三条连接状态和语音路径。

**Files:**

- Modify: `firmware/components/codex_remote_ui/src/ui.c`
- Modify: `firmware/components/codex_remote_ui/include/codex_remote/ui.h`
- Modify: `macos/Sources/CodexRemoteApp/SettingsView.swift`
- Modify: `macos/Sources/CodexRemoteApp/SetupAssistantView.swift`
- Modify: `macos/Sources/CodexRemoteApp/InstallationDiagnosticsView.swift`
- Modify: `macos/Sources/CodexRemoteMac/App/AppSettings.swift`
- Modify: corresponding Swift and C tests

**Device UI:**

- [ ] 在 Task 1 的最小首次选择页基础上，补齐常规设置页模式切换、说明文案和状态反馈。
- [ ] 原生模式显示 HOGP、USB 麦克风和当前 PTT 状态。
- [ ] 增强模式显示 HOGP、自定义音频 BLE、Mac App、录音和识别状态。
- [ ] USB 麦克风开关只控制设备是否暴露/输出 UAC；提示用户仍需在系统或 ChatGPT 中选择该输入设备。
- [ ] 模式切换明确提示将重启连接。

**Mac App UI:**

- [ ] 只保留 Bluetooth、Speech Recognition、Accessibility 和 ChatGPT 目标检查。
- [ ] 移除新用户流程中的 Ghostty、Codex CLI、hooks、Socket、BlackHole 和快捷键设置。
- [ ] 对历史受管配置提供单独的“迁移清理”入口，不自动删除。
- [ ] 明确显示“语音由 Mac App 识别并填入，不是系统虚拟麦克风”。

**Verification:**

```bash
swift test --package-path macos --filter 'AppSettingsTests|AppSourceWiringTests|SetupInspectorTests' --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
```

### Task 9：清理旧运行链路

**目标：** 新链路完成现场验收后，删除产品运行时不再需要的桥接代码。

**Destructive gate:** 删除文件和用户级受管配置前必须再次取得明确确认。本任务不能与前面兼容性 spike 同批执行。

**Candidate removals:**

- `macos/Sources/CodexRemoteMac/Ghostty/`
- `macos/Sources/CodexRemoteMac/Helper/` 中只服务 hooks/CLI session 的实现
- `macos/Sources/CodexRemoteMac/Service/SessionService.swift`
- `macos/Sources/CodexRemoteMac/Audio/BlackHoleAudioInputBridge.swift`
- `macos/Sources/CodexRemoteMac/Setup/BlackHoleInstaller.swift`
- Codex CLI shim、hook 安装和本地 IPC 产品装配
- 固件旧的 session title/directory 同步路径中不再可达的代码

**Steps:**

- [ ] 先用引用扫描确定真实不可达文件，不按候选列表机械删除。
- [ ] 保留通用 BLE fragment、IMA-ADPCM、音频诊断和必要迁移清理代码。
- [ ] 更新 Package products、Info.plist 权限说明、安装助手、README 和设备启用手册。
- [ ] 清理只属于旧运行时的测试；新行为必须已有替代测试后才能删除旧测试。
- [ ] 不自动卸载用户已安装的 BlackHole，不自动改写 `~/.codex/hooks.json`；只提供明确的受管配置清理动作。

**Verification:**

```bash
rg -n 'Ghostty|BlackHole|ManagedHooks|codex-remote-helper|SessionService' macos README.md docs
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
```

**Exit gate:** 产品运行时和首次设置不再依赖 Ghostty、hooks、app-server、BlackHole 或 CLI shim；保留的历史迁移代码有明确注释和测试。

### Task 10：全量构建、打包和双模式现场验收

**目标：** 用真实 ChatGPT Desktop、真实 ESP32 和真实麦克风闭环，而不是以编译成功代替交付。

**Automated verification:**

```bash
swift build --package-path macos --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
(cd firmware && idf.py build)
zsh macos/Scripts/package-app.zsh release /tmp/codex-remote-dual-mode
```

**Package verification:**

```bash
plutil -lint '/tmp/codex-remote-dual-mode/Codex Remote.app/Contents/Info.plist'
codesign --verify --deep --strict '/tmp/codex-remote-dual-mode/Codex Remote.app'
```

**Native mode hardware checklist:**

- [ ] 首次模式选择和重启正确。
- [ ] ChatGPT Desktop 检测 Codex Micro。
- [ ] 六个 Agent 状态、切换和命令键正确。
- [ ] 使用 Mac 内置麦克风完成一次 PTT。
- [ ] 使用 ESP32 USB UAC 完成一次 PTT。
- [ ] USB 拔出后控制功能仍通过 BLE 工作，语音明确退回系统麦克风或显示未选择。
- [ ] 休眠、唤醒、蓝牙断开、重新配对和 ChatGPT 重启均恢复。

**Companion mode hardware checklist:**

- [ ] HOGP 控制保持原生工作。
- [ ] Mac App 连接自定义音频 GATT。
- [ ] ESP32 麦克风连续发送音频，序列和丢帧诊断合理。
- [ ] Speech Framework 返回最终文本。
- [ ] 文本只进入 ChatGPT composer，不进入其他应用，不自动发送。
- [ ] Mac App 退出后原生控制继续工作。
- [ ] PTT 中断、BLE 断开、识别超时和权限撤销均明确失败并释放状态。

**Windows checklist:**

- [ ] USB UAC 无额外驱动枚举。
- [ ] Windows 录音机可以录音。
- [ ] ChatGPT Desktop 是否识别 Codex Micro 单独记录为“通过/不支持/待官方支持”，不影响 USB 麦克风结论。

安装 `/Applications/Codex Remote.app`、烧录 ESP32、清理旧用户配置、commit 和 push 均是独立动作，需要分别确认。

## 6. 测试门禁总表

| 层级 | 必测内容 | 完成标准 |
|---|---|---|
| C 纯逻辑 | 模式 reducer、HID framing、状态 reducer、路由优先级 | host tests + ASan/UBSan 退出 0 |
| 协议 | Report ID 6、63-byte body、JSON 分片、错误输入 | fixtures 与边界测试通过 |
| Swift | BLE audio、ADPCM、Speech、ChatGPT AX emitter | 定向测试和全量 XCTest 通过 |
| 固件构建 | NimBLE + UI + audio + USB | `idf.py build` 成功并记录尺寸 |
| Mac 打包 | bundle、plist、签名 | `plutil`、`codesign` 通过 |
| 真机 BLE | ChatGPT 检测、命令、状态、共存 | 当前 ChatGPT Desktop 实测 |
| 真机语音 | Mac mic、USB mic、BLE companion | 真实说话并检查最终文字 |
| 平台 | macOS 完整；Windows UAC | 分平台记录，不互相推断 |

## 7. 风险与停止条件

### ChatGPT 私有协议变化

停止条件：当前 ChatGPT Desktop 不检测设备，或更新后方法/descriptor 不兼容。

处理：记录版本和原始日志，只调整隔离的兼容层，不改现有 audio/core 逻辑掩盖问题。

### HOGP 与自定义 GATT 不共存

停止条件：加入自定义服务后 ChatGPT 不再识别，或系统 BLE 连接持续抖动。

处理：暂停增强模式，提交现场证据并重新选择替代架构。

### USB UAC 与 USB Serial/JTAG 冲突

停止条件：UAC 枚举导致无法稳定日志、刷写或运行。

处理：先采用 UAC-only runtime + UART 日志；复合 CDC 另行评审。

### ChatGPT Accessibility Tree 不稳定

停止条件：无法唯一定位 composer。

处理：不注入文字；保留识别文本和错误，不回退到任意焦点输入。

### BLE 音频影响控制延迟

停止条件：Approve/Decline 或 Agent 切换明显延迟、丢失。

处理：控制优先，丢弃音频帧并明确报告；不扩大无限 buffer。

## 8. 授权边界

用户本次确认的是目标方案和开发计划。进入实施时仍需按动作分别确认：

1. 修改 BLE shared contract、NVS schema 和固件根配置。
2. 新增 USB UAC managed dependency。
3. 烧录实体 ESP32。
4. 替换 `/Applications/Codex Remote.app`。
5. 删除旧文件或清理用户级 hooks/shim/BlackHole 相关配置。
6. commit、push、tag 或发布 Release。

未取得对应确认时，可以完成只读调查、测试设计和不触及这些边界的局部实现准备，但不能执行外部或破坏性动作。

## 9. 参考资料

- [OpenAI Codex Micro 官方文档](https://learn.chatgpt.com/docs/features/codex-micro)
- [Codex Micro Core2 兼容项目](https://github.com/imliubo/codex-micro-4-core2)
- [Core2 技术说明](https://github.com/imliubo/codex-micro-4-core2/blob/main/docs/TECHNICAL.md)
- [ESP32-S3-Touch-AMOLED-2.16 板卡文档](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-2.16)
- [Espressif USB Device UAC 文档](https://docs.espressif.com/projects/esp-iot-solution/en/latest/usb/usb_device/usb_device_uac.html)
