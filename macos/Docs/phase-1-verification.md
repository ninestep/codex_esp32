# Phase 1 Verification Report

Date: 2026-08-03

Scope: controlled Task10 live smoke plus Task11 fresh automated verification for the macOS session-control worktree. This report records observed evidence only. It does not claim provider/session hook lifecycle success where the live action was authorization-gated.

## Environment

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Swift toolchain | `swift --version` | 0 | `swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)`, target `arm64-apple-macosx15.0` |
| Xcode selection | `xcode-select -p` | 0 | `/Applications/Xcode.app/Contents/Developer` |
| Codex CLI | `codex --version` | 0 | Warning: `could not create PATH aliases: Operation not permitted`; version `codex-cli 0.146.0` |
| Ghostty CLI | `/Applications/Ghostty.app/Contents/MacOS/ghostty +version` | 0 | Ghostty `1.3.1`, stable channel |
| Ghostty scripting dictionary | `sdef /Applications/Ghostty.app` | 0 | Dictionary includes `new window`, `new tab`, `terminal id`, `focus`, `input text`, `send key`, and `send mouse scroll` |
| Ghostty bundle id | `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Ghostty.app/Contents/Info.plist` | 0 | `com.mitchellh.ghostty` |
| Ghostty bundle name | `/usr/libexec/PlistBuddy -c 'Print CFBundleName' /Applications/Ghostty.app/Contents/Info.plist` | 0 | `Ghostty` |

## Task11 fresh verification

Commands were run fresh on 2026-08-03 from commit `a195b6c`. SwiftPM was first run inside the managed sandbox, then rerun with the same command after escalation only where the managed sandbox failed before package planning.

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Swift tests in managed sandbox | `cd macos && swift test --parallel` | 1 | SwiftPM failed before test execution while compiling `Package.swift`: `sandbox-exec: sandbox_apply: Operation not permitted` |
| Swift tests after approved escalation | `cd macos && swift test --parallel` | 0 | Build completed, log enumerated `[1/95]` through `[95/95]`, no failures reported; Swift Testing compatibility summary printed `Test run with 0 tests in 0 suites passed` |
| Swift build in managed sandbox | `cd macos && swift build` | 1 | SwiftPM failed before compilation while compiling `Package.swift`: `sandbox-exec: sandbox_apply: Operation not permitted` |
| Swift build after approved escalation | `cd macos && swift build` | 0 | `Build complete! (0.16s)` |
| Codex shim script | `zsh macos/Tests/Scripts/codex-shim.zsh` | 0 | No stdout/stderr; script completed successfully |

Sandbox delta: the two SwiftPM managed-sandbox failures were environment restrictions at SwiftPM manifest sandbox setup, not test/build failures in project code. The escalated reruns used the same working directories and command arguments.

## Task11 scans

| Scan | Command | Exit | Result |
| --- | --- | ---: | --- |
| Core platform boundary | `rg -n 'import (AppKit\|SwiftUI\|CoreBluetooth\|CoreAudio)\|Ghostty\|AppleScript' macos/Sources/CodexRemoteCore` | 1 | Clean: no matches. `CodexRemoteCore` stays free of AppKit, SwiftUI, CoreBluetooth, CoreAudio, Ghostty, and AppleScript references. |
| Prompt/transcript surface | `rg -n 'last_assistant_message\|prompt\|transcript' macos/Sources macos/Tests` | 0 | Reviewed all matches. Runtime code only decodes official hook fields in `RawHookPayloadMapper`; remaining hits are state-classification tests, codec tests, helper command fixtures, and the zsh shim argument fixture. No runtime full transcript/message logging was found. |
| Common secret strings | `rg -n '(Bearer \|api[_-]?key\|BEGIN .*PRIVATE KEY\|password\s*[=:])' macos docs/superpowers` | 1 | Clean: no matches. |

## Task11 static evidence

| Claim | Evidence |
| --- | --- |
| Three-part mapping exists and is not cwd-bound | `SessionRegistry` stores separate indexes for `remoteIDByLauncher`, `remoteIDByTerminal`, and `remoteIDByProvider`. `registerLaunch` binds launcher plus terminal, `bindProviderSession` binds provider by launcher, and `session(providerSessionID:)` resolves by provider id. `workingDirectoryLabel` is display metadata only. |
| Enter/Esc target Ghostty terminal id without retry | `SessionService.sendKey` resolves the remote session, focuses `session.terminalTargetID`, then sends one key to the same terminal id. `GhosttyAppleScriptController.sendKey` emits a single `send key` AppleScript call to `terminal id`, and no retry loop was found in the call path. |
| Blocking vs optional completion behavior is covered by green tests | Fresh `swift test --parallel` included `WaitingInputClassifierTests/testBlockingConfirmationIsAmber`, `testChoiceRequiredIsAmber`, `testConfirmationBeforeContinueIsAmber`, `testOptionalOfferIsNormalCompletion`, and `testQuestionInsideCompletedExplanationIsNormal`; the full 95-test run exited 0. |
| Shim preserves args, streams, and exit status | Fresh `zsh macos/Tests/Scripts/codex-shim.zsh` exited 0. The script asserts argument forwarding, stdout/stderr preservation, real Codex exit status propagation, missing-real-Codex exit 127, helper failure non-blocking behavior, default socket path, and hook stdin forwarding. |
| Persistent config unchanged by Task11 | Task11 did not execute any command that writes `~/.codex/config.toml`, shell startup files, dependencies, BLE/device state, or provider/hook live configuration. This is based on executed command scope only; persistent user config was intentionally not inspected or modified. |

## Automated tests

Fresh Task10 build:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Build in managed sandbox | `cd macos && swift build` | 1 | SwiftPM failed before compilation with `sandbox-exec: sandbox_apply: Operation not permitted` |
| Build after approved escalation | `cd macos && swift build` | 0 | `Build complete! (0.17s)` |

Task10 did not fresh rerun `swift test` or the zsh shim suite. Task11 reran them fresh; see the Task11 fresh verification section above.

## Ghostty live targeting

Helper smoke:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Private temp parent | `mktemp -d /private/tmp/codex-remote-task10.XXXXXX` | 0 | `/private/tmp/codex-remote-task10.<redacted>` |
| Parent mode | `chmod 700 /private/tmp/codex-remote-task10.<redacted>` then `stat -f '%Sp %p' /private/tmp/codex-remote-task10.<redacted>` | 0 | `drwx------ 40700` |
| Helper serve | `.build/debug/codex-remote-helper serve --socket /private/tmp/codex-remote-task10.<redacted>/events.sock` | running during smoke | Helper tool session id was `<tool-session-id>` |
| Socket type and mode | `stat -f '%HT %Sp %p' /private/tmp/codex-remote-task10.<redacted>/events.sock` | 0 | `Socket srw------- 140600` |
| Empty session list | `.build/debug/codex-remote-helper list --socket /private/tmp/codex-remote-task10.<redacted>/events.sock --json` | 0 | `{"sessions":[],"version":1,"type":"sessions"}` |

GUI approval and targeting:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Plain AppleScript by app name | `osascript -e 'tell application "Ghostty" to return version'` | 1 | Failed with `不能获得 application "Ghostty"` |
| Approved AppleScript by bundle id | `osascript -e 'tell application id "com.mitchellh.ghostty" to return version'` | 0 | `1.3.1` |
| Disposable window creation | Approved `osascript` using `new window` and `new tab` | 0 | Disposable window id `<task10-window>`; waiter terminal ids `A` and `B` |
| Initial input logs | `stat -f '%N %z bytes' /private/tmp/codex-remote-task10.<redacted>/ghostty-a.hex` and same for B | 0 | A `0 bytes`; B `0 bytes` |
| Targeted focus, scroll, Enter, Esc | Approved `osascript` targeting terminal A by id, then focusing B and A by id | 0 | Focus readback proved B then A (`B\|A`) |
| Input isolation | `xxd -p` and `stat` on both raw-mode logs | 0 | A hex-log file contained `0d` and `1b` entries; B remained `0 bytes` |

Result: PASS for Ghostty targeted focus, scroll, Enter, and Esc isolation. The targeted terminal received Enter/Esc (`0d` and `1b`), and the other disposable terminal received no input.

Same-directory shell evidence:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Additional disposable Codex tabs | Approved `osascript` using `new tab` in the Task10 disposable window | 0 | Distinct disposable terminal ids `C` and `D` |
| Same cwd readback | Approved read-only `osascript` against both terminal ids | 0 | Both disposable terminals reported `/Users/wj/data/mcp/esp32/.worktrees/macos-session-control` |

Result: PASS for same-directory shell/cwd separation and distinct Ghostty terminal ids. This does not prove live launcher/provider mapping.

Cleanup confirmed by root agent after the smoke:

| Check | Evidence |
| --- | --- |
| Helper shutdown | `lsof` confirmed the helper process bound the exact socket; `TERM` succeeded; socket disappeared |
| Ghostty cleanup | `close window` was applied only to the Task10 disposable window id; subsequent existence check returned `false` |
| Temp cleanup | Exact temp path `/private/tmp/codex-remote-task10.<redacted>` was removed; `test ! -e` exited 0 |

## Codex hook lifecycle

Live hook configuration change: NOT RUN.

Reason: Step5 hook configuration was explicitly excluded from Task10 and remains waiting for separate user authorization.

Persistent config status: Task10/Task11 did not execute authorized hook configuration or persistent configuration writes to `~/.codex/config.toml`, shell PATH startup files, or other persistent user configuration. Task11 intentionally did not inspect or modify user config.

Fixture-backed hook behavior remains covered by the upstream automated evidence listed in the Automated tests section. Task10 did not mutate hook configuration or install runtime hooks.

## Authorization-gated checks

Blocked live check:

| Intended check | Attempted command path | Result |
| --- | --- | --- |
| Launch real Codex through repository-local `macos/Scripts/codex` shim in two same-cwd Ghostty tabs, submit different harmless prompts, then inspect `list --json` for distinct launcher/provider/terminal mapping | Approved-GUI `osascript` would have input two `codex exec --ephemeral --ignore-user-config --ignore-rules --sandbox read-only -a never -C ...` commands with explicit `PATH`, `CODEX_REMOTE_HELPER`, `CODEX_REMOTE_SOCKET`, and `CODEX_REMOTE_REAL_CODEX` | BLOCKED by approval system before execution |

Approval rejection summary: nested Codex sessions could read the local repository and send resulting context to an external service; the user had not specifically authorized that payload or destination. The task did not attempt to bypass the rejection.

Follow-up safer attempt status: a narrower `codex --version` through the shim was prepared after the rejection, but the session was interrupted while approval/execution was pending. There is no confirmed output for that command, so this report does not treat it as evidence.

Live mapping status: BLOCKED for real Codex prompt/provider mapping. The live evidence proves distinct same-cwd Ghostty terminal ids, but not a complete launcher/provider/terminal three-part mapping.

## Failures and fixes

| Failure | Observed evidence | Action taken | Status |
| --- | --- | --- | --- |
| SwiftPM sandbox failure | `swift build` failed with `sandbox-exec: sandbox_apply: Operation not permitted` | Re-ran the same build after explicit escalation approval | Fixed for Task10 build; build exited 0 |
| Ghostty app-name AppleScript lookup failure | `tell application "Ghostty"` failed with `不能获得 application "Ghostty"` | Used bundle id `com.mitchellh.ghostty` after approval | Fixed for Task10 GUI automation |
| Live nested Codex prompt check rejected | Approval system rejected nested Codex because it could send repository context to an external service | Stopped that path and recorded it as authorization-gated | BLOCKED pending explicit user authorization |

## Residual risks

- Provider/session lifecycle was not verified against live Codex prompts because that path was blocked by external-service authorization.
- Runtime hook binding was not verified live because Step5 hook configuration was not authorized and was intentionally not run.
- Same-directory evidence covers Ghostty terminal ids and cwd only; it does not establish provider session ids or final live session state transitions.
- Task11 fresh automated tests and static scans cannot replace live provider prompt mapping or live hook lifecycle verification.

## Phase2 go-no-go

NO-GO pending provider/hook live evidence.

Phase2 should wait until the user separately authorizes the live provider prompt path and hook configuration lifecycle check, or until an approved non-external provider strategy can exercise the same launcher/provider/session mapping without sending repository context to an external service.
