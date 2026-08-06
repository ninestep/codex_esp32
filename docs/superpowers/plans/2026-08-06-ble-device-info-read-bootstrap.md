# BLE Device Info Read Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Mac 主动读取替代一次性通知作为 `deviceInfo` 唯一启动来源，可靠触发首个 ESP32 会话快照。

**Architecture:** 固件的 `deviceInfo` GATT Read 返回单分片 BLE 协议包，继续复用现有消息、envelope、CRC 和分片格式。Mac 在三个通知确认并进入 ready 后执行 `readValue`，读取回调继续走现有 `.deviceInfo` 数据通道；原通知路径保留。

**Tech Stack:** ESP-IDF 5.5.4、NimBLE、C17、Swift 6.2、CoreBluetooth、XCTest。

---

### Task 1: 固化 Mac 主动读取行为

**Files:**
- Modify: `macos/Tests/CodexRemoteMacTests/BluetoothTransportStateMachineTests.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/AppSourceWiringTests.swift`
- Modify: `macos/Sources/CodexRemoteMac/Bluetooth/BluetoothTransportStateMachine.swift`
- Modify: `macos/Sources/CodexRemoteMac/Bluetooth/CoreBluetoothTransport.swift`

- [x] **Step 1: 写入失败测试**

状态机测试要求最后一个通知确认后返回 `[.connectionReady, .read(.deviceInfo)]`。接线测试要求 CoreBluetooth 对 `.read` 调用 `peripheral.readValue(for:)`。

- [x] **Step 2: 运行测试并确认失败**

Run: `swift test --package-path macos --filter 'BluetoothTransportStateMachineTests|AppSourceWiringTests'`

Expected: FAIL，原因是尚无 `.read` action，也没有 `readValue` 接线。

- [x] **Step 3: 实现最小 Mac 变更**

新增 `BluetoothTransportAction.read(BluetoothCharacteristic)`；通知全部确认后在 `.connectionReady` 之后读取 `.deviceInfo`。`CoreBluetoothTransport.execute` 将该 action 映射到 `CBPeripheral.readValue(for:)`，回调仍由 `didUpdateValueFor` 送到 `.deviceInfo` channel。

- [x] **Step 4: 运行定向测试并确认通过**

Run: `swift test --package-path macos --filter 'BluetoothTransportStateMachineTests|AppSourceWiringTests'`

Expected: PASS。

### Task 2: 固化固件读取协议包

**Files:**
- Modify: `firmware/test/host/test_ble_connection_order.c`
- Modify: `firmware/components/codex_remote_ble/src/ble_transport.c`

- [x] **Step 1: 写入失败测试**

源码契约测试要求 Read 分支调用 `append_device_info_packet(ctxt->om)`，并要求构造 `fragmentCount = 1` 的 8 字节头；同时禁止继续返回纯文本 `Codex Remote 0.1.0`。

- [x] **Step 2: 运行测试并确认失败**

Run: `zsh firmware/test/host/run-tests.zsh test_ble_connection_order`

Expected: FAIL，因为当前 Read 返回纯文本版本字符串。

- [x] **Step 3: 实现单分片读取值**

复用现有 `CR_MESSAGE_DEVICE_INFO`、`cr_message_encode` 和 `cr_envelope_encode`。在发送锁内分配新的 envelope sequence 与 message ID，把单分片头和 envelope 追加到 Read `os_mbuf`；编码或追加失败返回明确 ATT 错误。

- [x] **Step 4: 运行固件主机测试**

Run: `zsh firmware/test/host/run-tests.zsh all`

Expected: 所有目标退出码为 0。

### Task 3: 构建、安装、烧录与真机验证

**Files:**
- Build output: `macos` release app
- Build output: `firmware/build`

- [x] **Step 1: 全量测试和构建**

Run: `swift test --package-path macos`

Run: `swift build --package-path macos -c release`

Run: `idf.py -C firmware build`

Expected: 全部退出码为 0。

- [x] **Step 2: 打包并核验 App**

用 `macos/Scripts/package-app.zsh release <temporary-directory>` 生成 bundle；运行 `codesign --verify --deep --strict` 和 `plutil -lint`。

- [x] **Step 3: 可恢复替换和烧录**

停止当前任务 App，保留时间戳备份，安装新 bundle并启动。通过 `idf.py -C firmware -p /dev/cu.usbmodem1101 flash` 烧录已连接 ESP32。

- [ ] **Step 4: 现场验收**

Mac 菜单必须显示已连接且电量为 `100%`；ESP32 必须显示“Mac 已连接”并出现当前会话。检查运行日志无 GATT Read、解码或快照发送错误。

本计划不包含 Git commit 或 push。
