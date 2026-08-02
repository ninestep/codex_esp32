# Phase 1 Verification Report

Date: 2026-08-03

Scope: controlled Task10 live smoke for the macOS session-control worktree. This report records observed evidence only. It does not claim provider/session hook lifecycle success where the live action was authorization-gated.

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

## Automated tests

Fresh Task10 build:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Build in managed sandbox | `cd macos && swift build` | 1 | SwiftPM failed before compilation with `sandbox-exec: sandbox_apply: Operation not permitted` |
| Build after approved escalation | `cd macos && swift build` | 0 | `Build complete! (0.17s)` |

Task9 automation evidence, not rerun in Task10:

| Source | Status | Evidence |
| --- | --- | --- |
| Upstream Task9 current verification, reported in this task handoff on 2026-08-03 | PASS | `swift test` reported 95 tests and 0 failures |
| Upstream Task9 current verification, reported in this task handoff on 2026-08-03 | PASS | `swift build` exited 0 |
| Upstream Task9 current verification, reported in this task handoff on 2026-08-03 | PASS | zsh shim test exited 0 |

Task10 did not fresh rerun `swift test` or the zsh shim suite. The entries above are retained as upstream automation context only.

## Ghostty live targeting

Helper smoke:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Private temp parent | `mktemp -d /private/tmp/codex-remote-task10.XXXXXX` | 0 | `/private/tmp/codex-remote-task10.2PKb9e` |
| Parent mode | `chmod 700 /private/tmp/codex-remote-task10.2PKb9e` then `stat -f '%Sp %p' /private/tmp/codex-remote-task10.2PKb9e` | 0 | `drwx------ 40700` |
| Helper serve | `.build/debug/codex-remote-helper serve --socket /private/tmp/codex-remote-task10.2PKb9e/events.sock` | running during smoke | Helper tool session id was `63406` |
| Socket type and mode | `stat -f '%HT %Sp %p' /private/tmp/codex-remote-task10.2PKb9e/events.sock` | 0 | `Socket srw------- 140600` |
| Empty session list | `.build/debug/codex-remote-helper list --socket /private/tmp/codex-remote-task10.2PKb9e/events.sock --json` | 0 | `{"sessions":[],"version":1,"type":"sessions"}` |

GUI approval and targeting:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Plain AppleScript by app name | `osascript -e 'tell application "Ghostty" to return version'` | 1 | Failed with `不能获得 application "Ghostty"` |
| Approved AppleScript by bundle id | `osascript -e 'tell application id "com.mitchellh.ghostty" to return version'` | 0 | `1.3.1` |
| Disposable window creation | Approved `osascript` using `new window` and `new tab` | 0 | Window id `tab-group-600002198cf0`; waiter terminal ids `9FB0163E-6D55-4524-90C9-636B317FE93E` and `45CD3315-2FB5-4E1B-85CC-7F4D41EBAF49` |
| Initial input logs | `stat -f '%N %z bytes' /private/tmp/codex-remote-task10.2PKb9e/ghostty-a.hex` and same for B | 0 | A `0 bytes`; B `0 bytes` |
| Targeted focus, scroll, Enter, Esc | Approved `osascript` targeting terminal A by id, then focusing B and A by id | 0 | Focus readback `45CD3315-2FB5-4E1B-85CC-7F4D41EBAF49|9FB0163E-6D55-4524-90C9-636B317FE93E` |
| Input isolation | `xxd -p` and `stat` on both raw-mode logs | 0 | A hex-log file contained `0d` and `1b` entries; B remained `0 bytes` |

Result: PASS for Ghostty targeted focus, scroll, Enter, and Esc isolation. The targeted terminal received Enter/Esc (`0d` and `1b`), and the other disposable terminal received no input.

Same-directory shell evidence:

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Additional disposable Codex tabs | Approved `osascript` using `new tab` in the Task10 disposable window | 0 | Terminal ids `22CC4423-7892-4887-9B32-6723C9097369` and `3244583F-9F12-40A3-8CAA-30613296714D` |
| Same cwd readback | Approved read-only `osascript` against both terminal ids | 0 | `/Users/wj/data/mcp/esp32/.worktrees/macos-session-control|/Users/wj/data/mcp/esp32/.worktrees/macos-session-control` |

Result: PASS for same-directory shell/cwd separation and distinct Ghostty terminal ids. This does not prove live launcher/provider mapping.

Cleanup confirmed by root agent after the smoke:

| Check | Evidence |
| --- | --- |
| Helper shutdown | `lsof` confirmed helper PID `93231` bound the exact socket; `TERM` succeeded; socket disappeared |
| Ghostty cleanup | `close window` was applied only to window id `tab-group-600002198cf0`; subsequent existence check returned `false` |
| Temp cleanup | Exact path `/private/tmp/codex-remote-task10.2PKb9e` was removed; `test ! -e` exited 0 |

## Codex hook lifecycle

Live hook configuration change: NOT RUN.

Reason: Step5 hook configuration was explicitly excluded from Task10 and remains waiting for separate user authorization.

Persistent config status: no changes were made to `~/.codex/config.toml`, shell PATH startup files, or other persistent user configuration.

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
- Task10 did not rerun `swift test` or the zsh shim suite; those automation results are reported from upstream Task9 handoff context.

## Phase2 go-no-go

NO-GO pending provider/hook live evidence.

Phase2 should wait until the user separately authorizes the live provider prompt path and hook configuration lifecycle check, or until an approved non-external provider strategy can exercise the same launcher/provider/session mapping without sending repository context to an external service.
