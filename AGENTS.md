# Repository Guidelines

## Project Structure

This repository contains two cooperating applications. `macos/` is a Swift 6.2 package: shared protocol and domain code lives in `Sources/CodexRemoteCore`, macOS integrations in `Sources/CodexRemoteMac`, the SwiftUI app in `Sources/CodexRemoteApp`, and XCTest suites in `Tests/`. `firmware/` is an ESP-IDF project with reusable components in `components/`, the device entry point in `main/`, and C17 host tests in `test/host/`. BLE golden fixtures live in `macos/Fixtures/ble-v1/`. Put architecture decisions, implementation plans, and verification notes in `docs/`.

## Runtime Architecture

Codex Micro mode uses two paths over one ESP32 connection:

- Native HOGP/HID sends Agent selection, six Command slots, keyboard editing, encoder, joystick, and the physical Enter/Escape/PTT controls to ChatGPT Desktop.
- The companion BLE service sends device information and ADPCM audio to the Mac App, and receives the current control layout from the App.

The Mac App reads `[desktop.codex-micro-layout]` from `~/.codex/config.toml`. It maps six slots, `encoderMode`, and `analogStick` directions to display labels, then sends `MICRO_CONTROL_LAYOUT` to the device. Treat this as a cross-platform contract: update Swift, C, protocol versions, tests, and golden fixtures together.

PTT audio follows `ESP32 microphone -> ADPCM -> BLE -> SpeechAudioInputBridge -> Doubao WebSocket recognition -> CGEvent text injection`. It does not require Doubao IME, a virtual microphone, or BlackHole. Do not reintroduce those runtime dependencies without an explicit product decision. Keychain access and credential restoration must not block App launch or CoreBluetooth startup.

The firmware also retains the hooks/Ghostty-based Mac session mode. Do not mix its terminal scrolling and session semantics with Codex Micro native HID behavior. Codex Micro has six fixed Agent cards on one page and disables list scrolling; Mac session mode can show up to eight sessions and keeps vertical scrolling.

## Build and Test Commands

Run commands from the repository root unless noted:

- `swift build --package-path macos --disable-sandbox` builds the Mac libraries, helper, and app.
- `swift test --package-path macos --parallel --disable-sandbox` runs all Swift tests.
- `zsh firmware/test/host/run-tests.zsh all` compiles C17 host tests with strict warnings, ASan, and UBSan.
- `zsh firmware/test/host/verify-golden-fixtures.zsh` checks fixtures against both protocol implementations.
- `(cd firmware && idf.py build)` builds the ESP32-S3 firmware in an activated ESP-IDF environment.
- `zsh macos/Scripts/package-app.zsh release /tmp/codex-remote-build` packages the Mac App.

On the project Mac, ESP-IDF 5.5.4 uses `IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4` and `IDF_PYTHON_ENV_PATH=/Users/wj/.espressif/python_env/idf5.5_py3.13_env`. Discover the current serial port before flashing; do not hard-code a stale `/dev/cu.usbmodem*` value.

Installing or replacing `/Applications/Codex Remote.app`, flashing hardware, changing BLE/HID contracts, and modifying user-level hooks are separate operations from a successful build. Preserve a recoverable App backup before replacement.

## Coding Style

Match surrounding code and use four-space indentation. Swift types use `UpperCamelCase`; methods, properties, and tests use `lowerCamelCase`. C APIs use the existing `cr_` prefix and `snake_case`. Keep `CodexRemoteCore` platform-neutral. Do not import AppKit, CoreBluetooth, Security, or other macOS frameworks into Core.

Keep BLE message sizes, UUIDs, enum values, sequence rules, and fixtures synchronized. Reject malformed or incompatible messages explicitly; do not add silent fallbacks or parallel protocol paths. Keep device UI state changes under the LVGL lock and move cross-task data through bounded queues.

## UI and Input Rules

The display is 480×480. Codex Micro shows six Agent cards in a fixed 2×3 grid. Its action page shows six dynamic Command labels, Delete, Clear, Encoder, and Joystick in a 2×5 grid. The encoder page exposes an outer left/right ring and an inner press/hold button. The joystick page displays the configured action for up, right, down, and left.

Use `PRESSED`, `RELEASED`, and `PRESS_LOST` for held controls. Every press must have at most one matching release; disconnects and page changes must clear held state. Keep the physical button mapping: hold for PTT, single click for Enter, double click for Escape. Delete sends one Backspace; Clear sends Command+A followed by Backspace.

## Testing and Hardware Evidence

Run targeted tests first, then the relevant full suite. Protocol changes require Swift codec tests, C codec tests, and golden-fixture verification. Layout changes require parser tests for all six slots, encoder mode, and four joystick directions. Speech changes must cover final text, empty results, sequence gaps, recognition failure, cancellation, consecutive sessions, and App startup without synchronous keychain blocking.

A firmware build is not a flash. A successful flash is not runtime verification. BLE delivery, a login state, or a permission prompt is not voice-input verification. Hardware-dependent completion requires serial evidence and, where applicable, physical screen, touch, audio, and focused-text checks. Record any hardware step that remains manual.

## Git and Release Rules

Use Conventional Commits with an imperative Chinese summary, for example `fix(mac): 避免钥匙串阻塞启动`. Keep commits focused, inspect the staged diff, and exclude credentials, local hooks, build products, backups, and temporary artifacts.

Tags matching `v*` trigger `.github/workflows/release.yml`. The workflow validates both platforms, packages a macOS DMG and ESP32 firmware, generates checksums, and creates a GitHub Release. After pushing a tag, monitor the workflow through completion and confirm the corresponding GitHub Release exists. A queued run or successful packaging job alone does not prove release success.
