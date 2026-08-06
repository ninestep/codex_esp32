# ESP UI Navigation and Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 ESP32 会话列表改为中文深色整卡状态样式，并增加详情双页、方向键和五个固定 Slash 快捷键的 BLE 1.1 输入链路。

**Architecture:** 保留现有状态快照、动作结果和请求去重结构。`terminalKey` 扩展四个方向键；新增固定枚举 `terminalShortcut`，Mac 将枚举映射为常量文本，通过 Ghostty `input text` 后发送 Enter。ESP32 根据会话能力位决定是否开放快捷键页。

**Tech Stack:** Swift 6.2、XCTest、C17、ESP-IDF、NimBLE、LVGL 9、zsh host tests、Ghostty AppleScript。

---

本计划不包含 commit、push、Mac 应用安装或设备刷写；这些操作需要用户另行授权。

## 文件结构

- `macos/Sources/CodexRemoteCore/BLE/`：BLE 1.1 类型和编解码。
- `macos/Sources/CodexRemoteCore/Terminal/TerminalController.swift`：终端按键与固定命令接口。
- `macos/Sources/CodexRemoteMac/Ghostty/GhosttyAppleScriptController.swift`：Ghostty 方向键和命令输入。
- `macos/Sources/CodexRemoteMac/Service/SessionService.swift`：聚焦会话并发送终端动作。
- `macos/Sources/CodexRemoteMac/Client/MacClientCoordinator.swift`：BLE 请求校验、去重和结果响应。
- `firmware/components/codex_remote_core/`：C 端协议常量、消息体和 codec。
- `firmware/components/codex_remote_ble/`：固定快捷键消息发送。
- `firmware/components/codex_remote_ui/`：列表样式、中文文案和详情双页。
- `firmware/main/app_main.c`：UI 回调接线。
- `firmware/sdkconfig.defaults`：启用 Source Han Sans SC 16 CJK。
- `macos/Fixtures/ble-v1/`：Swift/C 共用的 BLE 1.1 golden fixtures。

### Task 1: Swift BLE 1.1 contract

**Files:**
- Modify: `macos/Sources/CodexRemoteCore/BLE/BLEProtocolVersion.swift`
- Modify: `macos/Sources/CodexRemoteCore/BLE/BLEMessage.swift`
- Modify: `macos/Sources/CodexRemoteCore/BLE/BLEMessageCodec.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/BLEMessageCodecTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Add assertions for `BLEProtocolVersion.current == 1.1`, key values `3...6`, shortcut values `1...5`, capabilities `1 << 3` and `1 << 4`, plus this round trip:

```swift
let message = BLEMessage.terminalShortcut(
    requestID: 9,
    sessionKey: 2,
    shortcut: .compact
)
XCTAssertEqual(try codec.decode(codec.encode(message, sequence: 7)).message, message)
```

Corrupt the last shortcut byte to `0xff` and assert `unknownEnum(field: "terminalShortcut", rawValue: 0xff)`.

- [ ] **Step 2: Verify RED**

Run:

```bash
cd macos
swift test --disable-sandbox --filter BLEMessageCodecTests
```

Expected: compile failure because `RemoteTerminalShortcut`, new key cases and `terminalShortcut` do not exist.

- [ ] **Step 3: Implement the minimal Swift contract**

Use these public types and values:

```swift
public enum RemoteTerminalKey: UInt8, Equatable, Sendable {
    case enter = 1, escape = 2, up = 3, down = 4, left = 5, right = 6
}

public enum RemoteTerminalShortcut: UInt8, Equatable, Sendable {
    case newSession = 1, quit = 2, write = 3, plan = 4, compact = 5
}

public static let navigationKeys = Self(rawValue: 1 << 3)
public static let terminalShortcuts = Self(rawValue: 1 << 4)
```

Set protocol minor to `1`, add `BLEMessageType.terminalShortcut = 0x0f`, and encode/decode the payload as `u32 requestID + u16 sessionKey + u8 shortcut`.

- [ ] **Step 4: Verify GREEN**

Run the Task 1 command. Expected: `BLEMessageCodecTests` pass with zero failures.

### Task 2: Mac terminal command path

**Files:**
- Modify: `macos/Sources/CodexRemoteCore/Terminal/TerminalController.swift`
- Modify: `macos/Sources/CodexRemoteMac/Ghostty/GhosttyAppleScriptController.swift`
- Modify: `macos/Sources/CodexRemoteMac/Service/SessionService.swift`
- Modify: `macos/Sources/CodexRemoteMac/Client/MacClientCoordinator.swift`
- Test: `macos/Tests/CodexRemoteMacTests/GhosttyAppleScriptControllerTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/SessionServiceTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/MacClientCoordinatorTests.swift`

- [ ] **Step 1: Write failing controller and service tests**

Require all six `TerminalKey` raw values and add a fixed command enum:

```swift
public enum TerminalShortcut: String, Sendable {
    case newSession = "/new"
    case quit = "/q"
    case write = "/w"
    case plan = "/plan"
    case compact = "/compact"
}
```

Test that `sendShortcut(.compact, to: "term-42")` produces one AppleScript containing, in order:

```applescript
input text "/compact" to targetTerm
send key "enter" to targetTerm
```

Test `SessionService.sendShortcut` records `.focus`, then `.shortcut` for the selected terminal.

- [ ] **Step 2: Write failing coordinator tests**

Test these behaviors:

- selected session + `.terminalShortcut(..., .plan)` calls `sendShortcut(.plan, remoteSessionID:)` and returns success;
- no selected session returns `invalidState`;
- duplicate request ID returns the cached response without sending the command twice;
- `.terminalKey(..., .up/.down/.left/.right)` maps to the same `TerminalKey` case.

- [ ] **Step 3: Verify RED**

Run:

```bash
cd macos
swift test --disable-sandbox --filter 'GhosttyAppleScriptControllerTests|SessionServiceTests|MacClientCoordinatorTests'
```

Expected: compile failures for the new methods and message case.

- [ ] **Step 4: Implement the Mac path**

Extend `TerminalController` and `SessionClient` with:

```swift
func sendShortcut(_ shortcut: TerminalShortcut, to terminalTargetID: String) async throws
func sendShortcut(_ shortcut: TerminalShortcut, remoteSessionID: String) async throws
```

Build AppleScript only from `TerminalShortcut.rawValue`; keep terminal ID validation unchanged. In `MacClientCoordinator`, validate selection and map remote enums explicitly. Add `.terminalShortcut` to the control-to-host outbound channel.

- [ ] **Step 5: Verify GREEN**

Run the Task 2 command. Expected: all selected suites pass.

### Task 3: Golden fixtures and C BLE codec

**Files:**
- Modify: `macos/Tests/CodexRemoteCoreTests/BLEGoldenFixtureTests.swift`
- Create: `macos/Fixtures/ble-v1/terminal-up.hex`
- Create: `macos/Fixtures/ble-v1/terminal-compact.hex`
- Modify: `macos/Fixtures/ble-v1/manifest.json`
- Modify: `firmware/components/codex_remote_core/include/codex_remote/protocol.h`
- Modify: `firmware/components/codex_remote_core/include/codex_remote/message.h`
- Modify: `firmware/components/codex_remote_core/src/message.c`
- Modify: `firmware/test/host/test_message_codec.c`
- Modify: `firmware/test/host/test_codec.c`
- Modify: `firmware/test/host/verify-golden-fixtures.zsh`

- [ ] **Step 1: Add failing Swift fixtures and C expectations**

Add valid vectors:

```swift
("terminal-up", "terminalKey", 10, .terminalKey(requestID: 10, sessionKey: 2, key: .up))
("terminal-compact", "terminalShortcut", 11, .terminalShortcut(requestID: 11, sessionKey: 2, shortcut: .compact))
```

Update manifest protocol minor to `1`. In C host tests, expect type `CR_MESSAGE_TERMINAL_SHORTCUT`, shortcut `5`, and protocol minor `1`.

- [ ] **Step 2: Verify RED**

Run:

```bash
zsh firmware/test/host/run-tests.zsh test_codec test_message_codec
```

Expected: compile failure because the C message type and union body do not exist.

- [ ] **Step 3: Implement the C contract**

Set `CR_PROTOCOL_MINOR` to `1`, add `CR_MESSAGE_TERMINAL_SHORTCUT = 0x0f`, and add:

```c
struct {
    uint32_t request_id;
    uint16_t session_key;
    uint8_t shortcut;
} terminal_shortcut;
```

Decode and encode the three fields in little-endian order. Reject key values outside `1...6` and shortcut values outside `1...5` with `CR_ERR_INVALID_PAYLOAD`.

- [ ] **Step 4: Generate and verify fixtures**

Run:

```bash
fixture_output=$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-ble-v1-output.XXXXXX")
BLE_FIXTURE_OUTPUT_DIR="$fixture_output" swift test \
  --disable-sandbox \
  --package-path macos \
  --filter BLEGoldenFixtureTests/testGenerateFixtures
```

Copy the generated `terminal-up.hex`, `terminal-compact.hex`, updated existing vectors and `manifest.json` into `macos/Fixtures/ble-v1/`, then run:

```bash
zsh firmware/test/host/verify-golden-fixtures.zsh
```

Expected: checked-in Swift vectors and C round trips match; fixture count includes the two new files.

### Task 4: Firmware BLE sender and app wiring

**Files:**
- Modify: `firmware/components/codex_remote_ble/include/codex_remote/ble_transport.h`
- Modify: `firmware/components/codex_remote_ble/src/ble_transport.c`
- Modify: `firmware/components/codex_remote_ui/include/codex_remote/ui.h`
- Modify: `firmware/main/app_main.c`
- Test: `firmware/test/host/test_display_runtime.c`

- [ ] **Step 1: Write failing source-wiring assertions**

Assert the source contains:

```c
cr_ble_send_terminal_shortcut(session_key, shortcut)
.terminal_shortcut = ui_shortcut
```

Also assert the UI callback struct declares `terminal_shortcut`.

- [ ] **Step 2: Verify RED**

Run:

```bash
zsh firmware/test/host/run-tests.zsh test_display_runtime
```

Expected: assertion failure for the missing sender and callback wiring.

- [ ] **Step 3: Implement sender and callback**

Add:

```c
esp_err_t cr_ble_send_terminal_shortcut(uint16_t session_key, uint8_t shortcut);
```

Build `CR_MESSAGE_TERMINAL_SHORTCUT`, allocate `next_request_id`, send on `control_to_host_handle` with indication, and map the UI callback in `app_main.c`. Log `terminal shortcut unavailable` on failure without logging command contents.

- [ ] **Step 4: Verify GREEN**

Run the Task 4 command. Expected: `test_display_runtime: PASS`.

### Task 5: LVGL Chinese list and detail pages

**Files:**
- Modify: `firmware/sdkconfig.defaults`
- Modify: `firmware/components/codex_remote_ui/src/ui.c`
- Modify: `firmware/test/host/test_display_runtime.c`

- [ ] **Step 1: Write failing UI source assertions**

Assert all required strings exist, old English state strings and `card->dot` are absent, and the config enables:

```text
CONFIG_LV_FONT_SOURCE_HAN_SANS_SC_16_CJK=y
```

Assert UI source references `lv_font_source_han_sans_sc_16_cjk`, `detail_shortcut_page`, `navigationKeys`, `terminalShortcuts`, `/new`, `/q`, `/w`, `/plan`, and `/compact`.

- [ ] **Step 2: Verify RED**

Run:

```bash
zsh firmware/test/host/run-tests.zsh test_display_runtime
```

Expected: assertion failure on the first missing Chinese/UI marker.

- [ ] **Step 3: Implement list styling and font**

Enable the built-in CJK font and apply it on the active screen. Replace `state_text` with `空闲 / 正在处理 / 已完成 / 需要输入 / 错误 / 离线`. Remove the dot object. Apply background, border and readable text colors for all six states.

- [ ] **Step 4: Implement detail subpages**

Keep `detail_page` as the page root and create two child containers:

```c
static lv_obj_t *detail_status_page;
static lv_obj_t *detail_shortcut_page;
static bool shortcut_page_active;
```

Create the approved buttons and positions. Toggle child visibility from the top-right button. Reset to the status page on entering a new session, returning home, or losing selection. Disable the shortcut toggle unless selected session capabilities include both new bits. Respect `interaction_locked` in every event handler.

- [ ] **Step 5: Wire directions and shortcuts**

Direction buttons call `terminal_key` with values `3...6`. Slash buttons call `terminal_shortcut` with values `1...5`. Keep Enter and Escape values `1` and `2`.

- [ ] **Step 6: Verify GREEN**

Run the Task 5 command. Expected: `test_display_runtime: PASS`.

### Task 6: Full verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run full Swift tests**

```bash
cd macos
swift test --disable-sandbox
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Run all C host tests and fixture verification**

```bash
zsh firmware/test/host/run-tests.zsh
zsh firmware/test/host/verify-golden-fixtures.zsh
```

Expected: every host target prints `PASS`; fixture verification succeeds.

- [ ] **Step 3: Build firmware from defaults with CJK enabled**

Use a temporary build directory and SDK config so the tracked defaults, rather than the developer's existing untracked `firmware/sdkconfig`, control the build:

```bash
cd firmware
. "$IDF_PATH/export.sh"
firmware_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-ui-build.XXXXXX")
idf.py -B "$firmware_build_dir/build" -D SDKCONFIG="$firmware_build_dir/sdkconfig" build
```

Expected: ESP-IDF build succeeds and the generated config contains `CONFIG_LV_FONT_SOURCE_HAN_SANS_SC_16_CJK=y`.

- [ ] **Step 4: Review visual and code invariants**

Check 480×480 coordinates, button hit areas, page reset rules, all exhaustive Swift/C message switches, and capability gating. Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only task files plus the pre-existing `.superpowers/` directory are changed.
