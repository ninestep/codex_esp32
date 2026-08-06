# Detail Delete Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 ESP32 会话详情页增加“删除”按钮，短按删除一个字符，长按清空当前输入行。

**Architecture:** BLE v1 的 `terminalKey` 增加 `backspace = 7` 和 `clearLine = 8`，次版本升级到 1.2。固件使用 LVGL 的短按、长按两个互斥事件发送语义按键；Mac 将其映射为 Ghostty Backspace 和 Control+U。

**Tech Stack:** C17、ESP-IDF、LVGL 9、Swift 6.2、XCTest、Ghostty AppleScript、BLE golden fixtures

---

### Task 1: Freeze BLE v1.2 key contract

**Files:**
- Modify: `macos/Tests/CodexRemoteCoreTests/BLEMessageCodecTests.swift`
- Modify: `firmware/test/host/test_message_codec.c`
- Modify: `firmware/components/codex_remote_core/include/codex_remote/protocol.h`
- Modify: `firmware/components/codex_remote_core/src/message.c`
- Modify: `macos/Sources/CodexRemoteCore/BLE/BLEProtocolVersion.swift`
- Modify: `macos/Sources/CodexRemoteCore/BLE/BLEMessage.swift`

- [x] **Step 1: Write failing protocol assertions**

Assert protocol version `1.2`, Swift raw values `.backspace == 7` and `.clearLine == 8`, and C decode acceptance for both values.

- [x] **Step 2: Run RED tests**

```bash
swift test --package-path macos --disable-sandbox --filter BLEMessageCodecTests
zsh firmware/test/host/run-tests.zsh test_message_codec
```

Expected: fail because v1.2 and key values 7/8 are not defined.

- [x] **Step 3: Implement the minimal contract**

Add the two enum values on both sides, change the C key validation upper bound to `CR_TERMINAL_KEY_CLEAR_LINE`, and set both protocol minors to `2`.

- [x] **Step 4: Re-run protocol tests**

Expected: both commands pass.

### Task 2: Map semantic keys to Ghostty

**Files:**
- Modify: `macos/Tests/CodexRemoteMacTests/GhosttyAppleScriptControllerTests.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/MacClientCoordinatorTests.swift`
- Modify: `macos/Sources/CodexRemoteCore/Terminal/TerminalController.swift`
- Modify: `macos/Sources/CodexRemoteMac/Ghostty/GhosttyAppleScriptController.swift`
- Modify: `macos/Sources/CodexRemoteMac/Client/MacClientCoordinator.swift`

- [x] **Step 1: Write failing routing tests**

Require `.backspace` to produce `send key "backspace" to targetTerm`, `.clearLine` to produce `send key "u" modifiers "control" to targetTerm`, and coordinator routing for both BLE values.

- [x] **Step 2: Run RED tests**

```bash
swift test --package-path macos --disable-sandbox --filter GhosttyAppleScriptControllerTests
swift test --package-path macos --disable-sandbox --filter MacClientCoordinatorTests
```

Expected: fail because the new `TerminalKey` cases and mappings are missing.

- [x] **Step 3: Implement key mapping**

Add `.backspace` and `.clearLine` to `TerminalKey`. Keep ordinary keys on the existing script path; generate the modifier form only for `.clearLine`. Extend the coordinator's exhaustive switch.

- [x] **Step 4: Re-run Mac tests**

Expected: both filtered suites pass.

### Task 3: Add short-press and long-press delete UI

**Files:**
- Modify: `firmware/test/host/test_display_runtime.c`
- Modify: `firmware/components/codex_remote_ui/src/ui.c`

- [x] **Step 1: Write failing UI source assertions**

Require the label `删除`, `LV_EVENT_SHORT_CLICKED`, `LV_EVENT_LONG_PRESSED`, `CR_TERMINAL_KEY_BACKSPACE`, and `CR_TERMINAL_KEY_CLEAR_LINE`.

- [x] **Step 2: Run RED test**

```bash
zsh firmware/test/host/run-tests.zsh test_display_runtime
```

Expected: fail because the delete button is absent.

- [x] **Step 3: Implement the button**

Keep the existing Cancel and Confirm buttons. Add a red 108×52 Delete button at the right edge. Register `LV_EVENT_SHORT_CLICKED` to send Backspace and `LV_EVENT_LONG_PRESSED` to send Clear Line. Both handlers must respect `interaction_locked` and require a selected session.

- [x] **Step 4: Re-run UI test**

Expected: pass.

### Task 4: Update cross-platform fixtures and verify

**Files:**
- Modify: `macos/Tests/CodexRemoteCoreTests/BLEGoldenFixtureTests.swift`
- Modify: `macos/Fixtures/ble-v1/manifest.json`
- Create: `macos/Fixtures/ble-v1/terminal-backspace.hex`
- Create: `macos/Fixtures/ble-v1/terminal-clear-line.hex`
- Modify: `firmware/test/host/test_codec.c`
- Modify: `firmware/test/host/test_message_codec.c`
- Modify: `firmware/test/host/verify-golden-fixtures.zsh`

- [x] **Step 1: Add v1.2 vectors and regenerate fixtures**

Generate Backspace and Clear Line terminal-key vectors, update manifest protocol minor and fixture count, then teach C tests to decode both vectors.

- [x] **Step 2: Run complete verification**

```bash
swift test --package-path macos --parallel --disable-sandbox
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
git diff --check
```

Expected: all commands exit 0. Do not claim hardware success without flashing and operating a real device.

- [x] **Step 3: Review scope**

Confirm only the approved BLE contract, Mac mapping, firmware UI, fixtures, tests, and this plan changed. Preserve all pre-existing dirty worktree edits. Do not commit or push without separate authorization.
