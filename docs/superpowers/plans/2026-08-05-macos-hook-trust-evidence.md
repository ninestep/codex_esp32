# macOS Hook 信任证据运行目录修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让真实 Codex Hook 沙箱在可写的私有运行目录记录信任证据，并让配置检查从同一位置读取证据。

**Architecture:** 证据路径由本次 Hook 命令的 `--socket` 派生：`events.sock` 的父目录下固定使用 `codex-remote-hook-trust.json`。`HelperCommandRunner` 不持有固定 store，而接收一个按 Socket URL 创建记录器的工厂；`SetupInspector` 使用相同的共享路径函数。GUI 业务分发仍不承担证据写入职责，本地 IPC 契约保持不变。

**Tech Stack:** Swift 6、Swift Package Manager、XCTest、Foundation、Darwin、本地 Unix Socket IPC、macOS App bundle。

---

## 约束与当前状态

- 当前 `/Applications/Codex Remote.app` 是固定写入 `~/.codex` 的错误构建。真实 Hook 返回退出码 74，不能作为交付版本。
- 既有备份 `/Applications/Codex Remote.app.backup-20260805-204404` 保留，不在本计划中删除。
- 当前工作区包含同一轮 Bluetooth、辅助功能、BlackHole 和 stale socket 修复，不得还原。
- 不修改 Hook/本地 IPC contract，不新增依赖，不修改 shell 持久配置。
- 不烧录 ESP32，不暂存无关的 `.superpowers/`。
- 安装新构建和提交实现均属于独立高风险门禁，执行前分别取得用户确认。

### Task 1: 用失败测试固定 Socket 派生契约

**Files:**
- Modify: `macos/Tests/CodexRemoteMacTests/ManagedHooksConfigurationTests.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/HelperCommandTests.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/HookEventQueueTests.swift`

- [x] **Step 1: 添加证据路径测试**

在 `HookTrustEvidenceStoreTests` 中增加：

```swift
func testEvidenceURLUsesSocketParentDirectory() {
    let socketURL = URL(fileURLWithPath: "/private/tmp/codex-remote-501/events.sock")

    XCTAssertEqual(
        HookTrustEvidenceStore.evidenceURL(forSocketAt: socketURL).path,
        "/private/tmp/codex-remote-501/codex-remote-hook-trust.json"
    )
}
```

- [x] **Step 2: 把 helper 测试改成记录器工厂**

将现有 `hookTrustEvidenceRecorder: recorder` 改为：

```swift
hookTrustEvidenceRecorderFactory: { socketURL in
    XCTAssertEqual(socketURL.path, "/tmp/codex.sock")
    return recorder
}
```

保留并继续验证以下边界：

- 四种受支持事件在 IPC 业务失败前已记录；
- malformed/unknown 事件不记录；
- 证据写入失败时返回 74，且不进入 IPC；
- IPC 不可用并进入队列时，证据仍已记录。

- [x] **Step 3: 运行定向测试并确认先失败**

Run:

```bash
cd macos
swift test --disable-sandbox --filter HookTrustEvidenceStoreTests
swift test --disable-sandbox --filter HelperCommandTests
swift test --disable-sandbox --filter HookEventQueueTests
```

Expected: FAIL，错误只指向尚不存在的 `evidenceURL(forSocketAt:)` 或 `hookTrustEvidenceRecorderFactory` API。

### Task 2: 实现共享路径和按 Socket 注入

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Setup/HookTrustEvidenceStore.swift`
- Modify: `macos/Sources/CodexRemoteMac/Helper/HelperCommandRunner.swift`
- Modify: `macos/Sources/codex-remote-helper/main.swift`

- [x] **Step 1: 新增共享路径函数**

在 `HookTrustEvidenceStore` 中加入：

```swift
public static func evidenceURL(forSocketAt socketURL: URL) -> URL {
    socketURL
        .standardizedFileURL
        .deletingLastPathComponent()
        .appendingPathComponent(fileName)
}
```

保留现有安全检查：父目录必须属于当前用户且 group/other 不可写；证据文件必须为当前用户所有的普通文件且权限为 `0600`；继续使用原子替换。

- [x] **Step 2: 将固定记录器改为工厂**

在 `HelperCommandRunner` 定义：

```swift
public typealias HookTrustEvidenceRecorderFactory =
    @Sendable (URL) -> (any HookTrustEvidenceRecording)?
```

初始化参数改为：

```swift
hookTrustEvidenceRecorderFactory: @escaping HookTrustEvidenceRecorderFactory = { _ in nil }
```

解析 `--socket` 和 Hook payload 后，用实际 `socketURL` 创建记录器：

```swift
if ManagedHookEvent(rawValue: payload.hookEventName) != nil,
   let recorder = hookTrustEvidenceRecorderFactory(socketURL) {
    do {
        try recorder.recordAcceptedHook(eventName: payload.hookEventName)
    } catch {
        return HelperCommandResult(
            exitCode: 74,
            stderr: "codex-remote-helper: hook trust evidence write failed\n"
        )
    }
}
```

- [x] **Step 3: 生产 helper 按实际 Socket 创建 store**

`codex-remote-helper/main.swift` 注入：

```swift
let result = await HelperCommandRunner(
    hookTrustEvidenceRecorderFactory: { socketURL in
        HookTrustEvidenceStore(
            evidenceURL: HookTrustEvidenceStore.evidenceURL(forSocketAt: socketURL)
        )
    }
).run(
    arguments: arguments,
    stdin: stdin,
    environment: ProcessInfo.processInfo.environment
)
```

`serve` 模式不写证据。

- [x] **Step 4: 运行定向测试并确认通过**

Run:

```bash
cd macos
swift test --disable-sandbox --filter HookTrustEvidenceStoreTests
swift test --disable-sandbox --filter HelperCommandTests
swift test --disable-sandbox --filter HookEventQueueTests
```

Expected: PASS。

### Task 3: 让 SetupInspector 读取同一路径

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Setup/SetupInspector.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift`

- [x] **Step 1: 添加默认 store 的集成测试**

测试创建权限为 `0700` 的临时运行目录、`events.sock` 路径和真实 `HookTrustEvidenceStore`，记录一个时间不早于 `hooks.json` 的受支持事件。构造 `SetupInspector` 时不注入 store，断言 `.hooksTrust` 为 `.ready`。

该测试必须证明默认读取位置来自 `context.socketPath`，不能依赖 `managedHooksTrustTargetURL`。

- [x] **Step 2: 运行测试并确认先失败**

Run:

```bash
cd macos
swift test --disable-sandbox --filter SetupInspectorTests
```

Expected: 新测试 FAIL，现实现仍读取 `managedHooksTrustTargetURL`。

- [x] **Step 3: 切换默认读取路径**

将 `SetupInspector` 的默认 store 改为：

```swift
self.hookTrustEvidenceStore = hookTrustEvidenceStore ?? HookTrustEvidenceStore(
    evidenceURL: HookTrustEvidenceStore.evidenceURL(
        forSocketAt: URL(fileURLWithPath: context.socketPath)
    )
)
```

保留 `managedHooksTrustTargetURL` 字段以避免扩大公共初始化接口改动；本任务不再用它派生证据路径。

- [x] **Step 4: 运行测试并确认通过**

Run:

```bash
cd macos
swift test --disable-sandbox --filter SetupInspectorTests
```

Expected: PASS。

### Task 4: 全量验证和真实 App 门禁

**Files:**
- Verify: `macos/`
- Verify: `macos/Scripts/package-app.zsh`

- [x] **Step 1: 静态检查和全量测试**

Run:

```bash
git diff --check
cd macos
swift test --disable-sandbox
swift build -c release --disable-sandbox
```

Expected: 全部退出码 0；测试总数不少于当前基线 324。

- [x] **Step 2: 打包并校验签名**

Run:

```bash
cd macos
zsh Scripts/package-app.zsh release /tmp/codex-remote-hook-runtime-build.usqsjS
codesign --verify --deep --strict "/tmp/codex-remote-hook-runtime-build.usqsjS/Codex Remote.app"
plutil -lint "/tmp/codex-remote-hook-runtime-build.usqsjS/Codex Remote.app/Contents/Info.plist"
```

Expected: 打包成功且签名校验退出码 0。

- [x] **Step 3: 取得安装确认**

明确告知用户新构建会替换 `/Applications/Codex Remote.app`，现有 dated backup 保留。用户确认后才安装、启动。

- [x] **Step 4: 执行真实 Hook 验证**

安装并启动后，执行真实 Codex 命令触发 `SessionStart`、`UserPromptSubmit`、`Stop`。核对：

```bash
stat -f '%Sp %Su %N' "$TMPDIR/codex-remote-$(id -u)/codex-remote-hook-trust.json"
```

Expected:

- Hook 不再返回 `hook trust evidence write failed`；
- 文件位于实际 `events.sock` 的父目录；
- 文件权限为 `-rw-------`，所有者为当前用户；
- `acceptedAt` 不早于当前 `hooks.json` 修改时间；
- 配置页 Hooks 信任项显示已确认。

### Task 5: 实现提交门禁

**Files:**
- Review: 本轮目标文件

- [x] **Step 1: 核对范围**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

确认不包含 `.superpowers/`、构建产物、应用备份或其他无关文件。

- [x] **Step 2: 取得提交确认**

汇报改动、自动测试、真实 Hook 验证和残余风险。只有用户明确确认后，才按目标文件逐一暂存并提交；提交信息遵循：

```text
fix(mac): 修复安装检查与 Hook 信任检测
```
