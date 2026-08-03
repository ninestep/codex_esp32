# 第一阶段验证报告

日期：2026-08-03

范围：针对 macOS 会话控制工作树执行受控的任务 10 现场冒烟测试、任务 11 自动化验证，以及后续获准的 provider/hook 现场补证。本报告只记录实际观察到的证据，并明确区分已通过、未通过和未完成验证的项目。

## Provider/hook 现场补证

2026-08-03 在用户明确授权后执行现场补证。为避免向外部 provider 发送当前仓库上下文，真实 Codex 只在权限为 `0700` 的空白临时目录中运行，并使用 `--skip-git-repo-check`、只读 sandbox 和固定无害提示；没有在当前仓库中启动嵌套 Codex。现场版本为 Codex CLI `0.146.0`，界面显示 provider `newapi`、模型 `gpt-5.6-sol`。

### Hook 配置与回滚

- 按 Codex 官方 hook 契约临时配置 `SessionStart`、`UserPromptSubmit`、`PermissionRequest` 和 `Stop`。临时包装器只记录时间、事件名、provider session id 和 launcher id，不记录 prompt、transcript 或 assistant message。
- 补证结束后停止一次性 helper，恢复原始 `~/.codex/hooks.json`。恢复后的文件与备份 SHA-256 均为 `78922a784ee78e9e50587e93628cd3b9d4dfbe49087adc4514e6781cea38cbb9`，权限为 `0600`，内容为 `{ "hooks": {} }`。
- 一次性 Ghostty 标签页均已关闭，补证前的 `esp32` 标签页已恢复为选中状态。最终枚举未发现补证临时终端。

### 真实状态流转

会话 A 在真实 Codex 生命周期中的采样结果如下。状态变化来自 helper 的 `list --json`，不是 fixture 或手工构造事件。

| 时间（UTC） | 状态 | 现场证据 |
| --- | --- | --- |
| 02:49:29 | `idle` | launcher/terminal 已登记，provider 尚未绑定 |
| 02:49:39 | `idle` | `SessionStart` 已将 provider 绑定到 launcher |
| 02:49:41 | `working` | 状态详情为 `Codex 正在处理` |
| 02:49:49 | `completeUnread` | 状态详情为 `会话A验证完成` |

对应事件日志依次记录 `SessionStart`、`UserPromptSubmit` 和 `Stop`。最终映射为：remote `AE193FB2-4BDB-4F03-B9C2-0A9BE3FCB9FD`、launcher `9511de5f-fcc5-4fcc-8ba3-ec42579bd958`、provider `019fc58e-fa73-7642-9a59-bf87d285c3af`、terminal `9EF4F7C3-26FC-40B0-8C27-487F56502D95`。

### 同目录双会话映射

两个真实 Codex 会话均从同一个空白临时 cwd 启动；helper 的显示标签均为 `macos`，但三类运行时标识均不同：

| 会话 | Remote ID | Launcher ID | Provider Session ID | Ghostty Terminal ID | 最终状态 |
| --- | --- | --- | --- | --- | --- |
| A | `AE193FB2-4BDB-4F03-B9C2-0A9BE3FCB9FD` | `9511de5f-fcc5-4fcc-8ba3-ec42579bd958` | `019fc58e-fa73-7642-9a59-bf87d285c3af` | `9EF4F7C3-26FC-40B0-8C27-487F56502D95` | `completeUnread` |
| B | `490A8A18-1D47-4BA5-9629-FBB433011B03` | `eaf4ee76-7a7d-439b-a813-8f4bea169898` | `019fc58f-63ca-7a11-95f5-3af581d93197` | `1BF16D08-FE63-4CBA-87E4-B3B571F98E30` | `completeUnread` |

结果：同 cwd 情况下，launcher/provider/terminal 三段映射仍能精确区分会话，现场验证通过。

### 等待输入与完成分类

| 场景 | Remote ID | Provider Session ID | 结果 |
| --- | --- | --- | --- |
| 阻塞式确认：要求回复“确认推送”后才继续 | `AD5F47D8-AC02-4ACF-9FAC-B659AEB05A10` | `019fc590-d50f-77a3-8bb9-48ac97b49990` | `requiresInput`；详情完整保留确认提示，琥珀色分类通过 |
| 可选式后续协助：“如果你愿意，我也可以继续协助” | `0B28C9F9-2773-48F0-9E86-4AE78DF2A4C2` | `019fc591-b65c-7893-8eaf-776991d80574` | `completeUnread`；未误判为等待输入，绿色分类通过 |

另有两个真实 Codex 会话分别在 `03:03:10Z` 和 `03:04:42Z` 触发了 `PermissionRequest`，证明该事件能到达临时 hook。由于这两次启动时 Ghostty 选中标签页切换存在时序竞争，`register-launch` 返回 `handler_failed`，provider 无法绑定到目标终端，因此不能把这两次事件作为 `PermissionRequest → requiresInput` 的现场状态证据。临时包装器原计划在转发后拒绝无害的文件创建，但远端 hook 已先以 69 失败，Codex 未采纳后续拒绝并执行了临时目录内的 `touch`；两个探针文件均已精确删除，清理前后检查均确认不存在。本报告不宣称 PermissionRequest 拒绝生效。按停止条件没有继续增加重试。结论是：`PermissionRequest` 事件送达已证实，其状态映射尚未完成现场验证。

### 现场发现并修复的缺陷

现场首次捕获焦点终端时，helper 持续返回 `noFocusedTerminal`。根因是 Ghostty 的 AppleScript 词典将脚本中的 `tab` 解析为 Ghostty `tab` 对象，脚本实际返回字符串 `tab` 作为分隔符；Swift 端却按制表符 `\t` 拆分，字段数始终不符。

修复采用测试先行：先将 `GhosttyAppleScriptControllerTests` 改为要求 `(ASCII character 9)` 并禁止 ` & tab & `，定向测试出现 2 个预期断言失败；随后将生产脚本改为显式 ASCII 9，定向测试恢复为 1/1 通过。完整回归结果见本报告最终验证章节。

### 补证后的最终验证

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 完整 Swift 测试 | `cd macos && swift test --parallel` | 0 | 构建完成；XCTest 从 `[1/118]` 枚举至 `[118/118]`，无失败。包含焦点终端捕获、三段映射、PermissionRequest reducer、等待输入分类及 socket/队列回归。 |
| Swift 构建 | `cd macos && swift build` | 0 | `Build complete! (0.20s)`。 |
| Codex shim 脚本 | `zsh macos/Tests/Scripts/codex-shim.zsh` | 0 | stdout/stderr 均无输出，脚本成功结束。 |
| 差异空白检查 | `git diff --check` | 0 | 干净。 |
| Hook 恢复校验 | `shasum -a 256 ~/.codex/hooks.json` | 0 | SHA-256 为 `78922a784ee78e9e50587e93628cd3b9d4dfbe49087adc4514e6781cea38cbb9`，与清理前的原始备份一致。 |
| 临时目录清理 | `test ! -e /private/tmp/codex-remote-live.G3C05d` | 0 | 本轮 helper socket、日志、空白 cwd 和临时 hook 包装器均已删除。 |

## 第一阶段最终审查修复

2026-08-03 已修复第一阶段最终审查及后续质量审查发现的高、中优先级问题：

- 高：`GhosttyAppleScriptController` 现在通过 `tell application id "com.mitchellh.ghostty"` 生成捕获当前终端、聚焦、滚动及按键发送脚本。自动化测试确认四类操作全部使用 bundle id，且不含 `tell application "Ghostty"`。后续 provider/hook 现场补证还发现捕获脚本的 `tab` 分隔符冲突，并已改为 `(ASCII character 9)`；修复后真实 Codex 会话成功完成 terminal/launcher/provider 映射。
- 高：待处理队列现在存储带内部版本的 `PendingLocalEvent` 帧，包含 `.launchSnapshot(LaunchRegistration)` 和 `.hook(HookPayload)` 两种事件。当 `register-launch` 在发送请求前无法连接时，helper 会在同一次调用中立即捕获当前 Ghostty 终端，构造可信的 `LaunchRegistration` 快照并入队，然后以退出码 0 结束，同时向 stderr 输出固定文本 `codex-remote-helper: launch queued`。`serve` 按文件顺序先排空启动快照，再处理后续 hook，因此启动快照后紧跟 `SessionStart` 时，无需稍后重新捕获焦点即可恢复 launcher/provider/terminal 映射。
- 高：`server.start` 之后、dispatcher 处理之前，启动阶段的 IPC 请求受门控保护，直至待处理队列排空。socket handler 等待 `IPCStartupGate`，待处理事件则直接交给 `SessionIPCDispatcher`。无论排空成功还是失败，helper 都会显式打开门控，既防止启动请求越过已排队的启动快照，也避免排空失败后请求永久阻塞。
- 高：允许入队的传输错误现仅限发送前的连接失败：`connectFailed` 和 `connectTimedOut`。hook 与 register-launch 在写入、读取等发送后不确定状态、空响应、读取超时、本地编解码失败或 daemon 明确返回失败时均不入队，并返回 69，避免重复处理或破坏至多一次语义。
- 中：队列重写已由原地 `ftruncate` 改为更能抵御崩溃的原子替换。helper 持有稳定锁文件期间读取旧队列，将完整新帧写入同目录唯一临时文件；该文件以 `O_CREAT|O_EXCL|O_NOFOLLOW` 和 `0600` 打开。随后依次对临时文件执行 fsync、将其重命名覆盖 `pending-hooks.jsonl`，再对父目录执行 fsync。重命名前失败会删除临时文件，旧队列字节保持不变。若重命名后父目录 fsync 失败，代码会报告错误，但无法回滚已完成的重命名；因此这里不宣称具备绝对事务性。
- 队列只持久化规范化后的待处理事件字段。hook 的 `message` 和 `lastAssistantMessage` 各自截断为最多 1,024 个 Unicode 字符；不持久化原始 hook JSON 或完整 transcript。队列上限保持为 64 个事件、总文件 256 KiB、单帧 64 KiB，并优先丢弃最旧事件。
- 锁文件使用 `O_CREAT|O_RDWR|O_NOFOLLOW` 打开，并校验仅所有者可访问的 `0600` 权限。读取现有队列文件时，在完成相同的所有者、类型和权限校验后使用 `O_RDONLY|O_NOFOLLOW`。队列重写使用同目录唯一临时文件，以 `O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW` 和 `0600` 打开，随后依次执行临时文件 fsync、覆盖 `pending-hooks.jsonl` 的 rename，以及父目录 fsync。socket 父目录仍由 `SocketParentPreparer` 严格校验所有者和 `0700` 权限。入队与排空操作通过 `flock` 串行化。第一个返回 `.error` 的待处理事件及其后的所有事件都会保留。服务退出时不删除队列文件。

定向修复测试：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| Ghostty bundle id 与待处理队列行为 | `cd macos && swift test --filter 'GhosttyAppleScriptControllerTests\|HookEventQueueTests'` | 0 | 27 项测试通过。覆盖 capture/focus/scroll/sendKey 的 bundle id 脚本、hook 入队、启动快照入队、缺少启动信息时保留 `SessionStart`、通过 launchSnapshot + SessionStart 排空恢复映射、有界队列淘汰、文件权限与符号链接拒绝、排空成功或失败后的保留行为、并发入队，以及重命名前原子重写失败。 |
| Helper 命令与队列回归 | `cd macos && swift test --filter 'HelperCommandTests\|HookEventQueueTests'` | 0 | 46 项测试通过。覆盖原始 hook 解析失败返回 65、daemon 明确错误返回 69、connectFailed/connectTimedOut 入队、发送后失败不入队、非 hook 命令行为、IPC 服务端与客户端、待处理事件排空及原子重写语义。 |
| 启动门控顺序 | `cd macos && swift test --filter 'IPCStartupGateTests'` | 0 | 3 项测试通过。覆盖打开前等待、幂等打开并释放全部等待者、直接到达的 `SessionStart` 等待待处理启动快照排空并恢复映射，以及排空错误后打开门控并释放等待者。 |
| socket 连接上限稳定性 | `cd macos && swift test --filter 'UnixSocketEventServerTests/testConnectionLimitReturnsServerBusyAndKeepsExistingServerUsable\|UnixSocketEventServerTests/testBlockingEventGateWaitForBlockedCountTimesOutAndReturnsAfterTargetReached'` | 0 | 修复不稳定失败及后续中优先级审查问题后，两项定向测试先通过 1 次，再连续通过 20 次。连接上限测试会先同步确认两个 handler 阻塞的连接已占用 slot，再断言 `server_busy`；最终 socket helper 只重试临时 `read` EAGAIN/EWOULDBLOCK，`readUntilEOF` 内只重试 EINTR，并注册异步 teardown 释放 slot gate。测试会先释放两个占用的 slot，再确认后续有效帧处理成功。门控测试证明：计数未达标时会在短轮询截止时间后抛出 `TestTimeoutError.timedOut`，不会挂起；计数达标时正常返回。 |

最终修复后的全新验证：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| socket gate 超时修复后的完整 Swift 测试，第 1 次 | `cd macos && swift test --parallel` | 0 | 构建耗时 `0.15s`；XCTest 从 `[1/118]` 枚举至 `[118/118]`，无失败。Swift Testing 兼容性摘要输出 `Test run with 0 tests in 0 suites passed`。 |
| socket gate 超时修复后的完整 Swift 测试，第 2 次 | `cd macos && swift test --parallel` | 0 | 构建耗时 `0.12s`；XCTest 从 `[1/118]` 枚举至 `[118/118]`，无失败。Swift Testing 兼容性摘要输出 `Test run with 0 tests in 0 suites passed`。 |
| Swift 构建 | `cd macos && swift build` | 0 | `Build complete! (0.18s)`。 |
| Codex shim 脚本 | `zsh macos/Tests/Scripts/codex-shim.zsh` | 0 | stdout/stderr 均无输出，脚本成功结束。现有脚本仍断言 hook 缺少 helper 时返回 69，保留“安装错误”和“daemon/App 不可用”之间的区别。 |
| Core 平台边界 | `rg -n 'import (AppKit\|SwiftUI\|CoreBluetooth\|CoreAudio)\|Ghostty\|AppleScript' macos/Sources/CodexRemoteCore` | 1 | 干净：无匹配。 |
| Ghostty 应用名称生产代码扫描 | `rg -n 'tell application "Ghostty"' macos/Sources` | 1 | 干净：生产 AppleScript 均未再通过应用名称定位 Ghostty。扩大到 `macos/Sources macos/Tests` 的扫描仅命中反向测试断言。 |
| Ghostty bundle id 扫描 | `rg -n 'tell application id "com\\.mitchellh\\.ghostty"' macos/Sources/CodexRemoteMac/Ghostty macos/Tests/CodexRemoteMacTests/GhosttyAppleScriptControllerTests.swift` | 0 | 4 个生产脚本使用 bundle id，测试也断言使用同一 bundle id。 |
| Prompt/transcript 暴露面 | `rg -n 'last_assistant_message\|prompt\|transcript' macos/Sources macos/Tests` | 0 | 已审查全部匹配项。运行时代码只映射官方 hook 字段；队列测试包含 `transcript` fixture，用于证明该字段不会持久化。 |
| 常见密钥字符串 | `rg -n '(Bearer \|api[_-]?key\|BEGIN .*PRIVATE KEY\|password\\s*[=:])' macos docs/superpowers -g '!macos/Docs/phase-1-verification.md'` | 1 | 干净：无匹配。 |
| diff 空白检查 | `git diff --check` | 0 | 干净。 |

## 环境

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| Swift 工具链 | `swift --version` | 0 | `swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)`，目标为 `arm64-apple-macosx15.0` |
| Xcode 选择路径 | `xcode-select -p` | 0 | `/Applications/Xcode.app/Contents/Developer` |
| Codex CLI | `codex --version` | 0 | 警告：`could not create PATH aliases: Operation not permitted`；版本为 `codex-cli 0.146.0` |
| Ghostty CLI | `/Applications/Ghostty.app/Contents/MacOS/ghostty +version` | 0 | Ghostty `1.3.1`，stable channel |
| Ghostty 脚本字典 | `sdef /Applications/Ghostty.app` | 0 | 字典包含 `new window`、`new tab`、`terminal id`、`focus`、`input text`、`send key` 和 `send mouse scroll` |
| Ghostty bundle id | `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Ghostty.app/Contents/Info.plist` | 0 | `com.mitchellh.ghostty` |
| Ghostty bundle 名称 | `/usr/libexec/PlistBuddy -c 'Print CFBundleName' /Applications/Ghostty.app/Contents/Info.plist` | 0 | `Ghostty` |

## 任务 11 全新验证

以下命令于 2026-08-03 在提交 `a195b6c` 上重新执行。SwiftPM 先在受管沙箱内运行；仅当受管沙箱在 package planning 前失败时，才在批准提权后使用相同命令重试。

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 受管沙箱内执行 Swift 测试 | `cd macos && swift test --parallel` | 1 | SwiftPM 在执行测试前编译 `Package.swift` 时失败：`sandbox-exec: sandbox_apply: Operation not permitted` |
| 批准提权后执行 Swift 测试 | `cd macos && swift test --parallel` | 0 | 构建完成，日志从 `[1/95]` 枚举至 `[95/95]`，未报告失败；Swift Testing 兼容性摘要输出 `Test run with 0 tests in 0 suites passed` |
| 受管沙箱内执行 Swift 构建 | `cd macos && swift build` | 1 | SwiftPM 在开始编译前编译 `Package.swift` 时失败：`sandbox-exec: sandbox_apply: Operation not permitted` |
| 批准提权后执行 Swift 构建 | `cd macos && swift build` | 0 | `Build complete! (0.16s)` |
| Codex shim 脚本 | `zsh macos/Tests/Scripts/codex-shim.zsh` | 0 | stdout/stderr 均无输出，脚本成功结束 |

沙箱差异说明：两次 SwiftPM 受管沙箱失败均发生在 SwiftPM manifest 沙箱初始化阶段，属于环境限制，并非项目代码的测试或构建失败。提权后的重试使用相同工作目录和命令参数。

## 任务 11 扫描

| 扫描项 | 命令 | 退出码 | 结果 |
| --- | --- | ---: | --- |
| Core 平台边界 | `rg -n 'import (AppKit\|SwiftUI\|CoreBluetooth\|CoreAudio)\|Ghostty\|AppleScript' macos/Sources/CodexRemoteCore` | 1 | 干净：无匹配。`CodexRemoteCore` 未引用 AppKit、SwiftUI、CoreBluetooth、CoreAudio、Ghostty 或 AppleScript。 |
| Prompt/transcript 暴露面 | `rg -n 'last_assistant_message\|prompt\|transcript' macos/Sources macos/Tests` | 0 | 已审查全部匹配项。运行时代码仅在 `RawHookPayloadMapper` 中解码官方 hook 字段；其余命中项为状态分类测试、codec 测试、helper 命令 fixture 和 zsh shim 参数 fixture。未发现运行时记录完整 transcript/message。 |
| 常见密钥字符串 | `rg -n '(Bearer \|api[_-]?key\|BEGIN .*PRIVATE KEY\|password\s*[=:])' macos docs/superpowers -g '!macos/Docs/phase-1-verification.md'` | 1 | 干净：无匹配。报告文件包含扫描表达式本身，为避免自匹配而将其排除。 |

## 任务 11 静态证据

| 结论 | 证据 |
| --- | --- |
| 三段映射存在且不依赖 cwd | `SessionRegistry` 分别维护 `remoteIDByLauncher`、`remoteIDByTerminal` 和 `remoteIDByProvider` 索引。`registerLaunch` 绑定 launcher 与 terminal，`bindProviderSession` 通过 launcher 绑定 provider，`session(providerSessionID:)` 通过 provider id 解析会话。`workingDirectoryLabel` 只用于显示元数据。 |
| Enter/Esc 通过 Ghostty terminal id 精确投递且不重试 | `SessionService.sendKey` 解析远程会话，聚焦 `session.terminalTargetID`，再向同一 terminal id 发送一次按键。`GhosttyAppleScriptController.sendKey` 只生成一次针对 `terminal id` 的 `send key` AppleScript 调用，调用路径中未发现重试循环。 |
| 绿色测试覆盖阻塞式确认与可选式完成 | 全新执行的 `swift test --parallel` 包含 `WaitingInputClassifierTests/testBlockingConfirmationIsAmber`、`testChoiceRequiredIsAmber`、`testConfirmationBeforeContinueIsAmber`、`testOptionalOfferIsNormalCompletion` 和 `testQuestionInsideCompletedExplanationIsNormal`；完整 95 项测试退出码为 0。 |
| Shim 保留参数、流和退出状态 | 全新执行的 `zsh macos/Tests/Scripts/codex-shim.zsh` 退出码为 0。脚本断言参数转发、stdout/stderr 保留、真实 Codex 退出状态透传、缺少真实 Codex 时返回 127、helper 失败不阻塞、默认 socket 路径及 hook stdin 转发。 |
| 任务 11 未改变持久化配置 | 任务 11 未执行任何写入 `~/.codex/config.toml`、shell 启动文件、依赖、BLE/设备状态或 provider/hook 现场配置的命令。该结论仅基于已执行命令的范围；本次有意未检查或修改用户持久化配置。 |

## 自动化测试

任务 10 的全新构建：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 受管沙箱内构建 | `cd macos && swift build` | 1 | SwiftPM 在编译前失败：`sandbox-exec: sandbox_apply: Operation not permitted` |
| 批准提权后构建 | `cd macos && swift build` | 0 | `Build complete! (0.17s)` |

任务 10 未重新执行 `swift test` 或 zsh shim 测试套件。任务 11 已重新执行，详见上方“任务 11 全新验证”。

## Ghostty 现场精确定位

下列临时路径、进程 id、窗口 id 和终端 UUID 是任务 10 的一次性审计证据，并非密钥。独立的发布打包步骤可以在保留原始验证日志的同时对这些值脱敏。

Helper 冒烟测试：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 私有临时父目录 | `mktemp -d /private/tmp/codex-remote-task10.XXXXXX` | 0 | `/private/tmp/codex-remote-task10.2PKb9e` |
| 父目录权限 | `chmod 700 /private/tmp/codex-remote-task10.2PKb9e`，随后执行 `stat -f '%Sp %p' /private/tmp/codex-remote-task10.2PKb9e` | 0 | `drwx------ 40700` |
| 启动 Helper serve | `.build/debug/codex-remote-helper serve --socket /private/tmp/codex-remote-task10.2PKb9e/events.sock` | 冒烟测试期间持续运行 | Helper 工具会话 id 为 `63406` |
| Socket 类型和权限 | `stat -f '%HT %Sp %p' /private/tmp/codex-remote-task10.2PKb9e/events.sock` | 0 | `Socket srw------- 140600` |
| 空会话列表 | `.build/debug/codex-remote-helper list --socket /private/tmp/codex-remote-task10.2PKb9e/events.sock --json` | 0 | `{"sessions":[],"version":1,"type":"sessions"}` |

GUI 授权与精确定位：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 按应用名称执行普通 AppleScript | `osascript -e 'tell application "Ghostty" to return version'` | 1 | 失败：`不能获得 application "Ghostty"` |
| 批准后通过 bundle id 执行 AppleScript | `osascript -e 'tell application id "com.mitchellh.ghostty" to return version'` | 0 | `1.3.1` |
| 创建一次性窗口 | 批准执行使用 `new window` 和 `new tab` 的 `osascript` | 0 | 窗口 id 为 `tab-group-600002198cf0`；等待输入的终端 id：A 为 `9FB0163E-6D55-4524-90C9-636B317FE93E`，B 为 `45CD3315-2FB5-4E1B-85CC-7F4D41EBAF49` |
| 初始输入日志 | 对 `/private/tmp/codex-remote-task10.2PKb9e/ghostty-a.hex` 和 B 对应文件执行 `stat -f '%N %z bytes'` | 0 | A 为 `0 bytes`；B 为 `0 bytes` |
| 定向聚焦、滚动、Enter 和 Esc | 批准执行按 id 定位终端 A 的 `osascript`，随后按 id 依次聚焦 B 和 A | 0 | 焦点回读为 `45CD3315-2FB5-4E1B-85CC-7F4D41EBAF49\|9FB0163E-6D55-4524-90C9-636B317FE93E` |
| 输入隔离 | 对两个 raw-mode 日志执行 `xxd -p` 和 `stat` | 0 | A 的十六进制日志包含 `0d` 和 `1b`；B 仍为 `0 bytes` |

结果：Ghostty 定向聚焦、滚动、Enter 和 Esc 隔离验证通过（PASS）。目标终端收到 Enter/Esc（`0d` 和 `1b`），另一个一次性终端未收到输入。

同目录 shell 证据：

| 检查项 | 命令 | 退出码 | 证据 |
| --- | --- | ---: | --- |
| 新增一次性 Codex 标签页 | 批准在任务 10 一次性窗口中执行使用 `new tab` 的 `osascript` | 0 | 终端 id：C 为 `22CC4423-7892-4887-9B32-6723C9097369`，D 为 `3244583F-9F12-40A3-8CAA-30613296714D` |
| 相同 cwd 回读 | 批准对两个终端 id 执行只读 `osascript` | 0 | `/Users/wj/data/mcp/esp32/.worktrees/macos-session-control\|/Users/wj/data/mcp/esp32/.worktrees/macos-session-control` |

结果：同目录 shell/cwd 隔离及不同 Ghostty terminal id 验证通过（PASS）。该证据不能证明现场 launcher/provider 映射。

根代理在冒烟测试后确认完成清理：

| 检查项 | 证据 |
| --- | --- |
| Helper 关闭 | `lsof` 确认 helper PID `93231` 绑定指定 socket；发送 `TERM` 成功；socket 随后消失 |
| Ghostty 清理 | `close window` 只作用于窗口 id `tab-group-600002198cf0`；随后检查存在性返回 `false` |
| 临时文件清理 | 已删除精确路径 `/private/tmp/codex-remote-task10.2PKb9e`；`test ! -e` 退出码为 0 |

## Codex hook 生命周期

现场 hook 配置变更：已在用户授权后临时执行，并在补证结束后完整回滚。

真实生命周期已验证 `SessionStart → UserPromptSubmit → Stop`，并观察到 `idle → working → completeUnread`。阻塞式自然语言确认被分类为 `requiresInput`，可选式完成提示保持 `completeUnread`。两个同 cwd 会话的 launcher/provider/terminal 标识互不相同。

`PermissionRequest` 在两个真实会话中送达 hook，但由于对应启动登记均发生 Ghostty 标签页时序失败，尚未形成可归属到目标远程会话的琥珀色状态证据。这是当前 hook 生命周期唯一尚未闭环的专项现场项。

补证没有改动 `~/.codex/config.toml` 或 shell PATH 启动文件。`~/.codex/hooks.json` 已恢复为补证前内容和权限，摘要校验一致。

## 受授权限制的检查

外部执行范围与限制：

| 计划检查 | 计划执行路径 | 结果 |
| --- | --- | --- |
| 在当前仓库内启动真实嵌套 Codex | 通过 Ghostty 标签页和仓库内 shim 启动真实 Codex | 授权系统拒绝；未执行，也未绕过 |
| 在空白临时目录启动真实 Codex | 使用只读 sandbox、固定无害提示和一次性 hook/helper | 已执行；取得真实状态流转、双会话映射和分类证据 |

授权边界说明：当前仓库执行路径仍被拒绝，因此本次改用不含仓库文件的空白临时目录。该范围足以验证 shim、hook、launcher/provider/terminal 映射和状态分类，但不能证明 provider 在当前仓库内容下的行为；后者也不是本轮补证所必需的数据条件。

## 失败与修复

| 失败项 | 观察证据 | 处理措施 | 状态 |
| --- | --- | --- | --- |
| SwiftPM 沙箱失败 | `swift build` 失败，错误为 `sandbox-exec: sandbox_apply: Operation not permitted` | 获得明确提权批准后，以相同命令重新构建 | 已修复任务 10 构建；构建退出码为 0 |
| Ghostty 按应用名称执行 AppleScript 失败 | `tell application "Ghostty"` 失败，提示 `不能获得 application "Ghostty"` | 获得批准后改用 bundle id `com.mitchellh.ghostty` | 已修复任务 10 GUI 自动化 |
| 最终全新测试中 socket 连接上限测试不稳定失败 | 提交 `bfca4f7` 后第一次最终执行 `cd macos && swift test --parallel` 时，仅 `UnixSocketEventServerTests/testConnectionLimitReturnsServerBusyAndKeepsExistingServerUsable` 失败，POSIX `read` 返回 errno 35（`EAGAIN`）。该定向测试随后重复通过，说明问题来自对时序敏感的测试 helper，而非生产服务端证据。修复过程中，在仍通过“已连接但空闲的客户端”推断 busy/slot 占用时，中间重试再次复现同一 errno。 | 仅修改测试：`sendFrameEventually` 只重试临时 `read` EAGAIN/EWOULDBLOCK；`readUntilEOF` 重试 EINTR；连接上限测试改用两个 handler 阻塞的连接占用 slot，确保仅在服务端已实际占满两个活动 slot 后断言 `server_busy`。随后释放两个占用者，再验证后续有效帧处理成功。 | 已修复：定向测试先通过 1 次，再连续通过 20 次；完整 `swift test --parallel` 连续通过 2 次，最终 XCTest 数量从 `[1/117]` 至 `[117/117]`；`swift build` 和 shim 脚本退出码也均为 0。 |
| 后续中优先级审查发现 slot gate 计数等待问题 | 审查发现 `BlockingEventGate.waitForBlockedCount` 保存 checked continuation，却没有显式超时；若未达到预期计数，测试可能挂起而不能明确失败。 | 仅修改测试：移除计数等待 continuation，将 `waitForBlockedCount` 改为 actor 可重入轮询，使用 `ContinuousClock`、默认 10ms 轮询间隔和显式超时；超时抛出 `TestTimeoutError.timedOut`，取消自然向上传播。连接上限测试注册异步 teardown，始终释放 handler 等待者；正常路径的显式释放保持幂等。新增门控测试，覆盖超时与计数达标两种情况。 | 已修复：两项定向测试先通过 1 次，再连续通过 20 次；完整 `swift test --parallel` 连续通过 2 次，最终 XCTest 数量从 `[1/118]` 至 `[118/118]`；`swift build` 和 shim 脚本退出码也均为 0。 |
| Ghostty 焦点终端捕获始终返回 `noFocusedTerminal` | AppleScript 中 `tab` 被 Ghostty 解释为标签页对象，实际输出不含 Swift 解析所需的制表符 | 先新增失败断言，再将生产脚本分隔符改为 `(ASCII character 9)` | 已修复；定向测试由预期失败恢复为 1/1 通过，真实会话随后成功建立映射 |
| 当前仓库内真实嵌套 Codex 被拒绝 | 授权系统拒绝向外部服务暴露当前仓库上下文 | 不绕过限制，改在空白临时目录执行相同会话生命周期验证 | 已取得不依赖仓库内容的 provider/hook 现场证据 |
| `PermissionRequest` 未形成可归属状态 | 两次真实事件均到达 hook，但对应 `register-launch` 因 Ghostty 选中标签页时序返回 `handler_failed` | 保留事件日志并按停止条件终止重试，不把事件送达误报为状态映射成功 | 事件送达已证实；`PermissionRequest → requiresInput` 现场映射待后续复验 |

## 残余风险

- `PermissionRequest` 事件已确认送达，但其到 `requiresInput` 的现场状态映射尚未闭环；自动化测试仍覆盖该映射逻辑。
- 当前仓库内的嵌套 Codex 启动未获授权。本次现场证据来自空白临时目录，因此没有验证 provider 读取仓库上下文时的外部行为。
- Ghostty 新建标签页后立即登记存在选中标签页时序竞争；正常 `SessionStart/UserPromptSubmit/Stop` 流程通过等待焦点稳定已成功，`PermissionRequest` 专项复验仍应在安装后的前台 App 流程中执行。

## 第二阶段准入结论

结论：第一阶段核心链路准入（GO），`PermissionRequest` 专项现场映射作为已记录约束保留。

真实 provider/hook 生命周期、同 cwd 双会话精确映射、阻塞式确认琥珀色分类和可选式完成绿色分类均已通过。可以进入第二阶段；但在发布前必须通过安装后的正常前台 App 流程补跑 `PermissionRequest → requiresInput`，并消除或规避 Ghostty 新建标签页后的登记时序竞争。本结论不把尚未完成的 PermissionRequest 状态映射表述为已通过。
