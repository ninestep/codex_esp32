# BLE Notification Readiness Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 防止 Mac 在关键 BLE 通知尚未启用时显示已连接，并保证 `deviceInfo` 在普通连接和系统恢复订阅两种情况下都能完成握手。

**Architecture:** `BluetoothTransportStateMachine` 增加通知订阅阶段，并以 CoreBluetooth 的通知状态回调作为进入 `.ready` 的唯一条件。`CoreBluetoothTransport` 根据 `CBCharacteristic.isNotifying` 选择直接订阅或重置订阅，任何订阅错误都取消当前连接并回到扫描。

**Tech Stack:** Swift 6.2、CoreBluetooth、XCTest、Swift Package Manager。

---

### Task 1: 固化通知就绪门禁

**Files:**
- Modify: `macos/Tests/CodexRemoteMacTests/BluetoothTransportStateMachineTests.swift`
- Modify: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothTransportStateMachine.swift`

- [x] **Step 1: 写入失败测试**

增加断言：发现全部特征后状态为 `.subscribingNotifications`；依次确认 `controlToHost`、`audioToHost` 时仍未 ready；确认 `deviceInfo` 后才返回 `.connectionReady` 并进入 `.ready`。增加订阅失败返回 `.cancelConnection` 的断言。

- [x] **Step 2: 运行测试并确认按预期失败**

Run: `swift test --package-path macos --filter BluetoothTransportStateMachineTests`

Expected: FAIL，原因是尚无订阅状态和通知更新事件。

- [x] **Step 3: 实现最小状态机变更**

增加 `.subscribingNotifications(id:)` 状态和 `.notificationStateUpdated(characteristic:isNotifying:succeeded:)` 事件。仅跟踪三个入站通知特征；全部开启后进入 `.ready`，失败时取消连接。

- [x] **Step 4: 运行定向测试并确认通过**

Run: `swift test --package-path macos --filter BluetoothTransportStateMachineTests`

Expected: PASS。

### Task 2: 接入 CoreBluetooth 真实回调

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Bluetooth/CoreBluetoothTransport.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/AppSourceWiringTests.swift`
- Modify: `macos/Sources/CodexRemoteApp/AppModel.swift`
- Modify: `macos/Sources/CodexRemoteMac/Client/MacClientCoordinator.swift`

- [x] **Step 1: 写入失败测试**

源码接线测试要求 `deviceInfo` 已通知时执行重置，未通知时直接订阅，并要求回调把 `error == nil`、`isNotifying` 交给状态机。

- [x] **Step 2: 运行测试并确认按预期失败**

Run: `swift test --package-path macos --filter AppSourceWiringTests`

Expected: FAIL，现有实现无条件关闭 `deviceInfo` 且忽略回调错误。

- [x] **Step 3: 实现最小适配层变更**

对 `deviceInfo` 检查 `isNotifying`；关闭回调成功后重新开启，开启回调统一进入状态机。把新订阅状态映射为“正在建立数据通道”，并在协调器中按未就绪状态清理连接数据。

- [x] **Step 4: 运行 Mac 全量测试和发布构建**

Run: `swift test --package-path macos`

Run: `swift build --package-path macos -c release`

Expected: 两条命令退出码均为 0。

### Task 3: 复核交付边界

**Files:**
- Review: all modified files

- [x] **Step 1: 检查差异和工作区**

Run: `git diff --check`

Run: `git status --short`

Expected: 无空白错误，只列出本轮目标文件和既有未跟踪 `.superpowers/`。

- [x] **Step 2: 保留安装门禁**

不替换 `/Applications/Codex Remote.app`，直到用户单独确认安装操作。
