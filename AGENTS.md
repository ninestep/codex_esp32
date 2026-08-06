# Repository Guidelines

## Project Structure & Module Organization

This repository contains two cooperating applications. `macos/` is a Swift 6.2 package with shared protocol/domain code in `Sources/CodexRemoteCore`, macOS integrations in `Sources/CodexRemoteMac`, the SwiftUI app in `Sources/CodexRemoteApp`, and XCTest suites under `Tests/`. `firmware/` is an ESP-IDF project: reusable C components live in `components/`, the device entry point is in `main/`, and host tests are in `test/host/`. BLE golden fixtures are stored in `macos/Fixtures/ble-v1/`. Architecture decisions, implementation plans, and verification notes belong in `docs/`.

## Build, Test, and Development Commands

Run commands from the repository root unless noted:

- `swift build --package-path macos --disable-sandbox` builds the macOS libraries, helper, and app.
- `swift test --package-path macos --parallel --disable-sandbox` runs all Swift tests.
- `zsh firmware/test/host/run-tests.zsh all` compiles C17 host tests with strict warnings, ASan, and UBSan.
- `zsh firmware/test/host/verify-golden-fixtures.zsh` checks protocol fixtures against both implementations.
- `(cd firmware && idf.py build)` builds ESP32-S3 firmware in an activated ESP-IDF environment.
- `zsh macos/Scripts/package-app.zsh release /tmp/codex-remote-build` creates an ad-hoc-signed app bundle.

## Coding Style & Naming Conventions

Match surrounding code and use four-space indentation. Swift types use `UpperCamelCase`; methods, properties, and test names use `lowerCamelCase`. C APIs use the existing `cr_` prefix and `snake_case`; constants and enum cases follow their enclosing module. Keep Core platform-neutral. Do not introduce macOS frameworks into `CodexRemoteCore`. Treat BLE message layouts, UUIDs, limits, and fixtures as a cross-platform contract: update Swift, C, and golden fixtures together.

## Testing Guidelines

Use XCTest for Swift and focused C executables for firmware logic. Name Swift tests `testBehaviorUnderCondition` and C files `test_<unit>.c`. Add regression coverage for behavior changes. Run targeted tests first, then the relevant full suite and golden-fixture check for protocol changes. Hardware-dependent claims require device evidence; a successful firmware build alone is not a flash or runtime verification.

## Commit & Pull Request Guidelines

History follows Conventional Commits, for example `fix(mac): 修复会话控制` or `feat: 完成终端快捷键`. Keep commits focused and use an imperative Chinese summary without a trailing period. Pull requests should explain scope, affected Mac/firmware paths, verification commands and results, linked issues, and remaining hardware risks. Include screenshots for SwiftUI or device UI changes. Never commit credentials, local hook configuration, build products, or temporary `.superpowers/` artifacts.
