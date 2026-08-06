# 固件中文与 PTT 可靠性修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复固件中文缺字，并恢复 ESP32 到 Mac/BlackHole/豆包的按住说话链路。

**Architecture:** 项目自有字体覆盖 UI 字符；固件音频在显示前分配关键资源并对失败关闭 PTT；Mac AVAudioEngine 使用 BlackHole 原生硬件格式。协议和用户设置保持不变。

**Tech Stack:** ESP-IDF 5.5、FreeRTOS、LVGL 9、Swift 6.2、AVFoundation、CoreAudio、XCTest。

---

### Task 1: 中文字体覆盖

**Files:**
- Create: `firmware/components/codex_remote_ui/src/codex_remote_font_16.c`
- Modify: `firmware/components/codex_remote_ui/src/ui.c`
- Modify: `firmware/components/codex_remote_ui/CMakeLists.txt`
- Modify: `firmware/test/host/test_display_runtime.c`

- [x] 在 `test_display_runtime.c` 加入测试，要求 UI 引用项目字体且字体字符表覆盖全部 UI 中文。
- [x] 运行 `firmware/test/host/run-tests.zsh test_display_runtime`，确认测试因项目字体不存在而失败。
- [x] 用仓内 Source Han Sans 源字体生成简体中文业务字库并接入 UI。
- [x] 重跑测试并确认通过。

### Task 2: ESP32 音频初始化和 PTT 门禁

**Files:**
- Modify: `firmware/components/codex_remote_audio/src/audio_capture.c`
- Modify: `firmware/main/app_main.c`
- Modify: `firmware/test/host/test_audio_runtime.c`

- [x] 增加源代码回归测试：音频先于显示初始化、I²C 先于 I²S 初始化，预录失败不能发送 PTT，提交失败必须回滚。
- [x] 运行 `firmware/test/host/run-tests.zsh test_audio_runtime`，确认按预期失败。
- [x] 提前音频初始化、显式初始化共享 I²C bus、增加内部堆诊断并实现错误门禁。
- [x] 重跑固件主机测试并确认通过。

### Task 3: Mac BlackHole 原生格式

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Audio/BlackHoleAudioInputBridge.swift`
- Modify: `macos/Tests/CodexRemoteMacTests/BlackHoleAudioInputBridgeTests.swift`

- [x] 增加测试，要求先切换默认输入，再绑定输出设备、读取原生格式并显式连接 mixer 到 output。
- [x] 运行目标 XCTest，确认测试因现有调用顺序失败。
- [x] 修改引擎配置顺序并保留可诊断错误上下文。
- [x] 重跑目标测试和全部 Swift 测试。

### Task 4: 构建、安装与真机验收

**Files:**
- Build output only; no source additions.

- [x] 用全新临时目录执行 ESP-IDF build，检查镜像大小。
- [x] 构建 release Mac app 并核验 bundle。
- [x] 停止本任务应用进程，备份现有 app，安装新 bundle 并重新启动。
- [x] 将新固件烧录 `/dev/cu.usbmodem1101`。
- [x] 串口验证启动、麦克风、BLE；真机长按验证快捷键、连续音频帧、BlackHole 路由和中文页面。

安装、烧录及最终 Git commit/push 均由用户在实施过程中明确授权。
