# 双模式改造基线

记录日期：2026-08-08

## 代码与平台

- Git 基线：`2ec7c0c`（`main`，tag `v0.1.6`）
- macOS：15.7.7（24G720）
- ESP-IDF：5.5.4
- ESP-IDF Python：`idf5.5_py3.13_env`
- 目标：ESP32-S3-Touch-AMOLED-2.16
- Swift tools：6.2

当前机器未在 `/Applications`、`~/Applications` 或 Spotlight 中发现 bundle identifier 为 `com.openai.chat` 的 ChatGPT Desktop。因此，ChatGPT bundle metadata、Accessibility Tree 和真实 Codex Micro 检测必须在安装了当前 ChatGPT Desktop 的现场环境补录，不能从源码或网页推断。

## 自动化基线

### Swift

```bash
swift test --package-path macos --parallel --disable-sandbox
```

结果：退出 0，执行 382 项 XCTest。SwiftPM 因沙箱无法写用户级 cache 发出警告，不影响构建和测试结果。

### 固件 host tests

```bash
zsh firmware/test/host/run-tests.zsh all
```

结果：退出 0，以下目标全部通过：

- `test_codec`
- `test_message_codec`
- `test_device_state`
- `test_input_state`
- `test_audio_frame`
- `test_audio_runtime`
- `test_asset_state`
- `test_power_state`
- `test_ble_advertising`

### BLE golden fixtures

```bash
zsh firmware/test/host/verify-golden-fixtures.zsh
```

结果：退出 0。

### ESP-IDF build

当前登录 shell 使用 Python 3.14，而既有 ESP-IDF 环境是 Python 3.13。直接运行 `export.sh` 会错误寻找尚未安装的 `idf5.5_py3.14_env`。本次未安装或升级工具链，使用既有 3.13 环境和原 CMake build directory 完成构建：

```bash
env IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 \
  /Users/wj/.espressif/tools/cmake/3.30.2/CMake.app/Contents/bin/cmake \
  --build firmware/build
```

结果：退出 0。

- Bootloader：`0x5700` bytes，剩余 32%
- Application：`0x1dd840` bytes
- 最小 app partition：`0x800000` bytes
- App partition 剩余：`0x6227c0` bytes（77%）

沙箱内首次 CMake regeneration 因 `psutil` 无权读取进程列表失败；在获准的非沙箱构建中完成配置和编译。该问题属于执行环境限制，不是源码失败。

## 产品和协议边界

- OpenAI 官方文档确认 Codex Micro 与 ChatGPT Desktop 配合，支持蓝牙、六个 Agent 键和命令键。
- 官方文档明确 Mic 键使用电脑麦克风；Codex Micro 本身不提供麦克风音频通道。
- Report ID 6、63-byte vendor report 和 JSON-RPC 方法来自第三方兼容项目的公开技术说明，不是 OpenAI 公布的开发 API。
- 当前版本兼容性必须以真实 ChatGPT Desktop、真实 macOS 蓝牙栈和真实硬件测试为准。

## 参考

- [OpenAI Codex Micro 官方文档](https://learn.chatgpt.com/docs/features/codex-micro)
- [Codex Micro Core2 兼容项目](https://github.com/imliubo/codex-micro-4-core2)
- [Core2 技术说明](https://github.com/imliubo/codex-micro-4-core2/blob/main/docs/TECHNICAL.md)
