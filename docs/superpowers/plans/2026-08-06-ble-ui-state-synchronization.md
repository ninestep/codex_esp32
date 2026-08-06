# BLE 与界面状态同步修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让固件、Mac 菜单栏、安装配置页和 Codex 会话列表使用同一条真实 BLE 连接与快照链路。

**Architecture:** 固件在订阅回调中使用事件携带的连接句柄发送 `deviceInfo`。Mac 使用一个主线程隔离的连接状态对象桥接运行时快照与安装检查器，并用观察 `AppModel` 的独立 SwiftUI 标签刷新菜单栏图标。

**Tech Stack:** ESP-IDF 5.5.4、NimBLE、C17、Swift 6.2、SwiftUI、XCTest、Swift Package Manager。

---

### Task 1: 固化 NimBLE 订阅时序修复

**Files:**
- Modify: `firmware/components/codex_remote_ble/src/ble_transport.c`
- Create: `firmware/test/host/test_ble_connection_order.c`
- Modify: `firmware/test/host/run-tests.zsh`

- [x] **Step 1: 写入失败回归测试**

测试读取 BLE transport 源码并要求订阅分支调用：

```c
assert(strstr(source, "send_device_info(event->subscribe.conn_handle)") != NULL);
```

- [x] **Step 2: 运行测试并确认修复前失败**

Run: `zsh firmware/test/host/run-tests.zsh test_ble_connection_order`

Expected: 断言失败，因为旧代码调用无参数的 `send_device_info()`。

- [x] **Step 3: 使用订阅事件连接句柄发送设备信息**

将发送路径改为显式接收 `conn_handle`：

```c
static int send_device_info(uint16_t conn_handle)
{
    return send_message_on_connection(&message, device_info_handle, false, conn_handle);
}

case BLE_GAP_EVENT_SUBSCRIBE:
    if (event->subscribe.attr_handle == device_info_handle && event->subscribe.cur_notify) {
        int rc = send_device_info(event->subscribe.conn_handle);
        if (rc != 0) ESP_LOGW(TAG, "device info notify failed: %d", rc);
    }
    return 0;
```

- [x] **Step 4: 验证主机测试和目标固件构建**

Run: `zsh firmware/test/host/run-tests.zsh all`

Expected: 全部目标退出 0。

Run: `/Users/wj/.espressif/tools/cmake/3.30.2/CMake.app/Contents/bin/cmake --build firmware/build`

Expected: 生成 `firmware/build/codex_remote.bin`，镜像尺寸检查通过。

### Task 2: 建立可测试的实时 BLE 连接状态源

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothConnectionStatus.swift`
- Create: `macos/Tests/CodexRemoteMacTests/BluetoothConnectionStatusTests.swift`

- [x] **Step 1: 写入连接状态失败测试**

```swift
@MainActor
final class BluetoothConnectionStatusTests: XCTestCase {
    func testUpdateTracksReadyAndReturnsOnlyRealTransitions() {
        let status = BluetoothConnectionStatus()

        XCTAssertFalse(status.isConnected)
        XCTAssertTrue(status.update(.ready(id: "device-1")))
        XCTAssertTrue(status.isConnected)
        XCTAssertFalse(status.update(.ready(id: "device-1")))
        XCTAssertTrue(status.update(.scanning))
        XCTAssertFalse(status.isConnected)
    }
}
```

- [x] **Step 2: 运行测试并确认类型缺失**

Run: `cd macos && swift test --disable-sandbox --filter BluetoothConnectionStatusTests`

Expected: 编译失败，提示找不到 `BluetoothConnectionStatus`。

- [x] **Step 3: 实现最小连接状态对象**

```swift
@MainActor
public final class BluetoothConnectionStatus {
    public private(set) var isConnected = false

    public init() {}

    @discardableResult
    public func update(_ state: BluetoothTransportState) -> Bool {
        let nextValue: Bool
        if case .ready = state {
            nextValue = true
        } else {
            nextValue = false
        }
        guard nextValue != isConnected else { return false }
        isConnected = nextValue
        return true
    }
}
```

- [x] **Step 4: 运行定向测试**

Run: `cd macos && swift test --disable-sandbox --filter BluetoothConnectionStatusTests`

Expected: 测试通过。

### Task 3: 将安装检查器接入实时状态

**Files:**
- Modify: `macos/Sources/CodexRemoteApp/AppModel.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift`

- [x] **Step 1: 补充注入读取器回归测试**

```swift
func testMacSetupEnvironmentUsesInjectedESP32ConnectionState() async {
    let connected = MacSetupEnvironment(esp32ConnectedReader: { true })
    let disconnected = MacSetupEnvironment(esp32ConnectedReader: { false })

    XCTAssertTrue(await connected.isESP32Connected())
    XCTAssertFalse(await disconnected.isESP32Connected())
}
```

- [x] **Step 2: 运行定向测试确认现有注入边界可用**

Run: `cd macos && swift test --disable-sandbox --filter SetupInspectorTests/testMacSetupEnvironmentUsesInjectedESP32ConnectionState`

Expected: 测试通过；它锁定 App 装配所依赖的读取器接口。

- [x] **Step 3: 在 AppModel 装配真实状态读取器**

新增属性并在初始化时创建闭包：

```swift
private let bluetoothConnectionStatus: BluetoothConnectionStatus
private let esp32ConnectedReader: @Sendable () async -> Bool

let bluetoothConnectionStatus = BluetoothConnectionStatus()
let esp32ConnectedReader: @Sendable () async -> Bool = {
    await bluetoothConnectionStatus.isConnected
}
self.bluetoothConnectionStatus = bluetoothConnectionStatus
self.esp32ConnectedReader = esp32ConnectedReader
setupServices = Self.makeSetupServices(
    settings: loadedSettings,
    esp32ConnectedReader: esp32ConnectedReader
)
```

让 `makeSetupServices` 接收读取器并传给环境：

```swift
private static func makeSetupServices(
    settings: AppSettings,
    esp32ConnectedReader: @escaping @Sendable () async -> Bool
) -> SetupServices {
    let environment = MacSetupEnvironment(
        esp32ConnectedReader: esp32ConnectedReader,
        hotkeyTestReader: { hotkey in
            HotkeyParser().parse(hotkey)?.displayValue == testedHotkey
        }
    )
}
```

协调器发布快照时更新连接状态；仅在连接布尔值变化时复查安装状态：

```swift
coordinator.onSnapshotChange = { [weak self] snapshot in
    guard let self else { return }
    let connectionChanged = self.bluetoothConnectionStatus.update(snapshot.transportState)
    self.snapshot = snapshot
    if connectionChanged {
        Task { await self.refreshSetup() }
    }
}
```

设置变化后重建服务时继续传入同一读取器。

- [x] **Step 4: 运行连接与安装检查定向测试**

Run: `cd macos && swift test --disable-sandbox --filter 'BluetoothConnectionStatusTests|SetupInspectorTests'`

Expected: 两组测试通过。

### Task 4: 让菜单栏图标观察连接状态

**Files:**
- Modify: `macos/Sources/CodexRemoteApp/CodexRemoteApp.swift`

- [x] **Step 1: 增加观察 AppModel 的菜单栏标签**

```swift
private struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label("Codex Remote", systemImage: model.menuBarSymbol)
    }
}
```

- [x] **Step 2: 改用 MenuBarExtra 的 label 构造器**

```swift
MenuBarExtra {
    MenuBarContentView(model: appDelegate.model)
} label: {
    MenuBarStatusLabel(model: appDelegate.model)
}
```

- [x] **Step 3: 编译 Mac 应用目标**

Run: `cd macos && swift build --disable-sandbox`

Expected: `CodexRemoteApp` 编译和链接通过。

### Task 5: 完整验证并生成临时安装包

**Files:**
- Verify: `firmware/build/codex_remote.bin`
- Create in temporary directory: `/tmp/codex-remote-ble-sync-build/Codex Remote.app`

- [x] **Step 1: 运行全部固件主机测试**

Run: `zsh firmware/test/host/run-tests.zsh all`

Expected: 命令退出 0，无断言失败。

- [x] **Step 2: 运行全部 Swift 测试和 release 构建**

Run: `cd macos && swift test --parallel --disable-sandbox`

Expected: XCTest 全部通过。

Run: `cd macos && swift build -c release --disable-sandbox`

Expected: release 构建完成。

- [x] **Step 3: 生成并校验临时 App**

Run: `cd macos && zsh Scripts/package-app.zsh release /tmp/codex-remote-ble-sync-build`

Expected: 生成 `/tmp/codex-remote-ble-sync-build/Codex Remote.app`。

Run: `codesign --verify --deep --strict '/tmp/codex-remote-ble-sync-build/Codex Remote.app'`

Expected: 退出 0。

Run: `plutil -lint '/tmp/codex-remote-ble-sync-build/Codex Remote.app/Contents/Info.plist'`

Expected: `OK`。

- [x] **Step 4: 交付人工真机验收步骤**

用户先烧录 `firmware/build/codex_remote.bin` 对应的完整 flash 目标，再从临时路径运行新 App。验收四项：ESP32 显示 `Mac connected`；配置页显示 `ESP32 已连接`；菜单栏图标切换为连接图标；新建 Codex 会话后 Mac 和 ESP32 均显示该会话。

本计划不包含 commit、push，也不替换 `/Applications/Codex Remote.app`。
