# Codex Remote

Codex Remote 由 macOS App 和 ESP32-S3 设备组成。设备通过 480×480 AMOLED 屏幕显示 Codex Agent 状态，并提供触摸、实体按键、旋钮、摇杆和语音输入。Mac App 负责伴随 BLE 通道、Codex Micro 布局同步、语音识别和文本注入。

## 当前工作模式

### Codex Micro 增强模式

ESP32 通过原生 HOGP/HID 接入 ChatGPT Desktop：

- 首页以 2×3 卡片显示 6 个 Agent，无需滚动。
- Agent 状态支持空闲、正在处理、已完成、需要输入、错误和离线。
- 点击 Agent 后进入操作页，显示当前六个 Command、删除、清除、旋钮和摇杆入口。
- 六个 Command 直接发送 `ACT06`、`ACT07`、`ACT08`、`ACT09`、`ACT10`、`ACT12`。
- 删除发送 Backspace；清除发送 Command+A 后再发送 Backspace。
- 旋钮支持左右旋转、中心点击和长按；摇杆支持上、右、下、左。
- 实体键长按开始语音输入，单击发送 Enter，双击发送 Escape。
- Agent 状态变化会点亮屏幕；已完成和需要输入使用不同提示音。

Mac App 读取 `~/.codex/config.toml` 中的 `[desktop.codex-micro-layout]`，将六个 Command、`encoderMode` 和 `analogStick` 四个方向的当前设置转换为显示文案，再通过伴随 BLE 通道同步到设备。设备操作仍通过原生 HID 发送；Mac App 只负责布局显示和语音链路。

### Mac 会话模式

仓库仍保留基于 Codex hooks、Ghostty 映射和 BLE 会话同步的 Mac 会话模式。该模式最多显示 8 个会话，因此列表保留垂直滚动。Codex Micro 的 6 卡首页固定在顶部并关闭滚动。

## 语音输入

语音链路不依赖豆包输入法、虚拟麦克风或 BlackHole：

1. ESP32 采集麦克风音频并编码为 ADPCM。
2. 伴随 BLE 通道将音频帧发送给 Mac App。
3. Mac App 使用已登录的豆包 Web 会话进行流式识别。
4. 松开实体键后，App 等待最终结果并将完整文本输入当前焦点。

首次使用时，在 Mac App 中登录豆包，并授予辅助功能权限。BLE 音频到达、登录成功或出现权限提示都不等于语音链路验收完成；真机验收必须确认最终文字完整进入目标输入框。

## 项目结构

```text
macos/      SwiftPM 工程、SwiftUI App、macOS 集成、测试和 BLE fixtures
firmware/   ESP-IDF 固件、可复用组件、设备入口和 C17 host tests
docs/       架构设计、实施计划、验证记录和设备启用手册
```

跨端 BLE v1.4 协议由 Swift 与 C 共同实现。修改消息类型、布局、UUID、字段限制或能力位时，必须同步更新两端代码和 `macos/Fixtures/ble-v1/` 中的 golden fixtures。

## 环境要求

- macOS 15 或更高版本
- Swift 6.2 工具链
- ESP-IDF 5.5.x
- Waveshare ESP32-S3-Touch-AMOLED-2.16
- ChatGPT Desktop；Mac 会话模式还需要 Ghostty 和 Codex CLI

仓库构建不会自动安装 `/Applications/Codex Remote.app`、烧录设备、修改用户级 hooks，也不会代替系统权限授权。

## 构建与测试

在仓库根目录运行：

```bash
swift build --package-path macos --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox

zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh

# 先激活 ESP-IDF 环境
(cd firmware && idf.py build)
```

生成本机验证用 App：

```bash
zsh macos/Scripts/package-app.zsh release /tmp/codex-remote-build
```

脚本优先使用已配置的本机签名身份；CI 使用 ad-hoc 签名。测试构建不等于 Developer ID 签名、公证或第三方分发版本。

## 真机验收

自动化测试覆盖协议、状态机、布局解析、配置流程和构建。发布前仍需在真实设备上检查：

- 6 个 Agent 卡片、状态变化、20 秒详情页返回和唤醒逻辑。
- 六键、删除、清除、旋钮、摇杆及实体键操作。
- Mac App 自动重连及六键、旋钮、摇杆布局同步。
- 完整语音输入、最终文本、连续输入和失败恢复。
- 已完成与需要输入的提示音。

现场安装和联调步骤见[设备到位启用手册](docs/设备到位启用手册.md)。

## 提交与发布

提交前阅读 [Repository Guidelines](AGENTS.md)。提交信息采用 Conventional Commits，例如 `feat(firmware): 同步 Codex Micro 控件布局`。只提交当前任务相关文件，并记录实际测试和未覆盖的硬件风险。

推送 `v*` tag 会触发 GitHub Release workflow，构建 macOS DMG、ESP32-S3 固件包和 checksums。只有 workflow 与 GitHub Release 均成功后，才能认定版本发布完成。

## License

本项目使用仓库根目录 [LICENSE](LICENSE) 中声明的许可证。
