# macOS 客户端应用实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有会话控制和 BLE v1 协议核心之上，建立可编译的 macOS 菜单栏客户端，实现 CoreBluetooth 会话同步与设备控制闭环，并为 BlackHole/豆包音频链路提供可测试、默认禁用的系统适配边界。

**Architecture:** `CodexRemoteCore` 继续保持平台无关，新增纯状态的连接同步和音频事务 reducer。`CodexRemoteMac` 承载 CoreBluetooth、Core Audio、快捷键和应用协调器；新的 `CodexRemoteApp` SwiftUI executable 只负责菜单栏及设置视图。所有系统 API 都包在可替换 port 后，测试使用确定性 fake，不连接真实设备、不安装 BlackHole、不修改辅助功能或默认输入设备。

**Tech Stack:** Swift 6.2、SwiftUI、CoreBluetooth、CoreAudio、现有 Unix Socket/Ghostty adapter、XCTest、BLE v1 golden fixtures。

---

## 范围与门禁

- 本计划不修改 BLE v1 shared contract、ESP-IDF schema、依赖或 CI。
- 本计划不安装 BlackHole，不修改默认输入设备，不写 `~/.codex` 或 shell 配置，不请求 Accessibility 授权。
- 真实 BLE、豆包识别和虚拟麦克风切换属于现场验证；在没有设备/BlackHole 时必须显示不可用，不伪造成功。
- 本轮不做签名、公证、DMG、自动更新、LaunchAgent 或 App Store 分发。

### Task 1: 建立平台无关的 BLE 客户端同步 reducer

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Client/DeviceConnectionState.swift`
- Create: `macos/Sources/CodexRemoteCore/Client/DeviceSyncReducer.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/DeviceSyncReducerTests.swift`

- [x] **Step 1: 写失败测试**

覆盖断开、协议协商、ready、重同步和 incompatible；transport 宣告连接 ready 后首次输出完整 snapshot，字段变化输出严格递增 delta，会话成员变化重新发送新 generation snapshot；断线清除 connection sequence 但保留最新会话投影。

- [x] **Step 2: 验证 RED**

Run: `cd macos && swift test --disable-sandbox --filter DeviceSyncReducerTests`

Expected: 编译失败，因为 `DeviceSyncReducer` 不存在。

- [x] **Step 3: 实现最小 reducer**

公开 API 只接收 `RemoteSession` 投影、连接事件和 resync 请求，输出 `BLEMessage.sessionSnapshot`、`.sessionDelta` 或明确错误；不引用 CoreBluetooth。

- [x] **Step 4: 验证 GREEN**

Run: `cd macos && swift test --disable-sandbox --filter DeviceSyncReducerTests`

Expected: 全部通过。

### Task 2: 实现 CoreBluetooth transport 及 GATT 映射

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothTransport.swift`
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/CoreBluetoothTransport.swift`
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothUUIDs.swift`
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothTransportStateMachine.swift`
- Create: `macos/Tests/CodexRemoteMacTests/BluetoothTransportStateMachineTests.swift`
- Modify: `macos/Package.swift`

- [x] **Step 1: 写失败测试**

覆盖 central powered off/unauthorized、只连接一个匹配设备、六 characteristic 完整发现前不 ready、断线 reset、indication/notify 分流、写入队列优先级以及 256 KiB/1,024 分片上限。

- [x] **Step 2: 验证 RED**

Run: `cd macos && swift test --disable-sandbox --filter BluetoothTransportStateMachineTests`

Expected: 编译失败，因为 transport state machine 不存在。

- [x] **Step 3: 实现 state machine 和薄 CoreBluetooth adapter**

固定六条逻辑通道：`ControlToHost`、`ControlToDevice`、`StateToDevice`、`AudioToHost`、`AssetToDevice`、`DeviceInfo`。delegate 回调只转换为 Sendable 事件；codec、重组和优先级在 actor 内处理。

- [x] **Step 4: 验证 GREEN 与平台边界**

Run: `cd macos && swift test --disable-sandbox --filter BluetoothTransportStateMachineTests`

Expected: 全部通过；`CoreBluetooth` 只出现在 `CodexRemoteMac/Bluetooth`。

### Task 3: 建立客户端协调器并接入 SessionService

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Client/MacClientCoordinator.swift`
- Create: `macos/Sources/CodexRemoteMac/Client/ClientSnapshot.swift`
- Create: `macos/Tests/CodexRemoteMacTests/MacClientCoordinatorTests.swift`
- Modify: `macos/Sources/CodexRemoteMac/Service/SessionService.swift`

- [x] **Step 1: 写失败测试**

覆盖 ready 后发送最多八会话 snapshot；状态变化发送 delta；设备 select 先聚焦再 ACK；scroll、Enter/Esc 路由到已选会话；无 selection/PTT/mapping 失效明确拒绝；重复 request ID 不重复副作用。

- [x] **Step 2: 验证 RED**

Run: `cd macos && swift test --disable-sandbox --filter MacClientCoordinatorTests`

Expected: 编译失败，因为 `MacClientCoordinator` 不存在。

- [x] **Step 3: 实现 actor 协调器**

协调器依赖 `SessionService` port 和 `BluetoothTransport` port，不直接依赖 AppleScript；所有设备控制消息先通过 BLE codec/selection 校验再调用服务。

- [x] **Step 4: 验证 GREEN**

Run: `cd macos && swift test --disable-sandbox --filter MacClientCoordinatorTests`

Expected: 全部通过。

### Task 4: 实现音频恢复事务、BlackHole 检测和豆包快捷键边界

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Audio/AudioInputTransaction.swift`
- Create: `macos/Sources/CodexRemoteMac/Audio/AudioInputBridge.swift`
- Create: `macos/Sources/CodexRemoteMac/Audio/CoreAudioDeviceCatalog.swift`
- Create: `macos/Sources/CodexRemoteMac/Input/HotkeyEmitter.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/AudioInputTransactionTests.swift`
- Create: `macos/Tests/CodexRemoteMacTests/AudioInputBridgeTests.swift`

- [ ] **Step 1: 写失败测试**

覆盖仅选择会话后允许 PTT、BlackHole 缺失禁用、begin 保存原输入设备、320 sample 独立 ADPCM 解码、丢帧补静音、end 先排空再 key-up/恢复设备、启动发现未完成事务时只恢复不继续录音。

- [ ] **Step 2: 验证 RED**

Run: `cd macos && swift test --disable-sandbox --filter 'AudioInputTransactionTests|AudioInputBridgeTests'`

Expected: 编译失败，因为音频事务类型不存在。

- [x] **Step 3: 实现无安装副作用的 adapter**

BlackHole 仅按 CoreAudio 设备名称和 UID 探测；未找到时返回 `.dependencyMissing`。快捷键以配置值生成 keyDown/keyUp 事件，但测试和默认启动不调用真实 CGEvent。

- [ ] **Step 4: 验证 GREEN**

Run: `cd macos && swift test --disable-sandbox --filter 'AudioInputTransactionTests|AudioInputBridgeTests'`

Expected: 全部通过。

### Task 5: 建立 SwiftUI 菜单栏应用与设置模型

**Files:**
- Modify: `macos/Package.swift`
- Create: `macos/Sources/CodexRemoteApp/CodexRemoteApp.swift`
- Create: `macos/Sources/CodexRemoteApp/AppModel.swift`
- Create: `macos/Sources/CodexRemoteApp/MenuBarContentView.swift`
- Create: `macos/Sources/CodexRemoteApp/SettingsView.swift`
- Create: `macos/Tests/CodexRemoteMacTests/AppSettingsTests.swift`

- [x] **Step 1: 写设置模型失败测试**

覆盖默认 socket、BLE 自动重连、豆包快捷键、PTT 启用条件、BlackHole 缺失提示和不持久化 prompt/录音。

- [x] **Step 2: 验证 RED**

Run: `cd macos && swift test --disable-sandbox --filter AppSettingsTests`

Expected: 编译失败，因为设置模型不存在。

- [x] **Step 3: 实现菜单栏和设置窗口**

菜单显示 Mac helper、BLE、设备、电量、当前会话和音频依赖状态；设置页只包含已确认能力，不提供未实现的 OTA/配对重置。

- [x] **Step 4: 构建应用目标**

Run: `cd macos && swift build --disable-sandbox --product codex-remote-app`

Expected: 构建成功；不启动 App、不申请权限。

### Task 6: 全量回归与中文验证报告

**Files:**
- Create: `macos/Docs/phase-3-mac-client-verification.md`

- [x] **Step 1: 完整测试和构建**

Run:

```bash
cd macos
swift test --parallel --disable-sandbox
swift build --disable-sandbox
zsh Tests/Scripts/codex-shim.zsh
zsh Tests/Scripts/ble-golden-fixtures.zsh
```

- [x] **Step 2: 边界扫描**

Run:

```bash
rg -n '^import (SwiftUI|AppKit|CoreBluetooth|CoreAudio)' macos/Sources/CodexRemoteCore
rg -n 'terminalTargetID|launcherInstanceID|providerSessionID' macos/Sources/CodexRemoteCore/BLE macos/Fixtures/ble-v1
git diff --check
```

Expected: 两项私有边界扫描无匹配，diff 检查退出 0。

- [x] **Step 3: 编写中文报告并停在系统变更门禁**

报告区分纯 reducer、CoreBluetooth 编译、模拟闭环和真机现场证据；明确 BlackHole 安装、默认输入设备切换、Accessibility、真实豆包识别和签名打包均未授权/未验证。

## 完成标准

- Mac App 目标可编译，菜单栏能表达 helper/BLE/设备/音频依赖状态。
- 模拟 BLE transport 能驱动 snapshot/delta、select、scroll、Enter/Esc 和 PTT 音频事务。
- CoreBluetooth adapter 编译并严格使用冻结的 BLE v1 codec。
- BlackHole 缺失时 PTT 明确禁用，不修改系统音频配置。
- 现有 153 项测试、shim 和 golden fixtures 不回归。
