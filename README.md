# Codex Remote

Codex Remote 是一个由 macOS 客户端和 ESP32-S3 设备端组成的远程会话控制原型。Mac 端负责发现 Codex 会话、映射 Ghostty 终端、同步状态并处理语音输入；设备端通过 480×480 AMOLED 屏幕展示会话，并提供触摸、实体键和 PTT 操作。

## 项目结构

```text
macos/      SwiftPM 工程、SwiftUI App、辅助进程、测试和 BLE fixtures
firmware/   ESP-IDF 固件、可复用组件和 C17 host tests
docs/       设计说明、实施计划和设备启用手册
```

跨端 BLE 协议由 Swift 与 C 共同实现。修改消息布局、UUID、字段限制或能力位时，必须同步更新两端代码及 `macos/Fixtures/ble-v1/` 中的 golden fixtures。

## 环境要求

- macOS 15 或更高版本
- Swift 6.2 工具链
- ESP-IDF 5.5.x
- Waveshare ESP32-S3-Touch-AMOLED-2.16
- Ghostty 与 Codex CLI

设备烧录、系统权限申请以及用户级 hooks 或 shell 配置修改均属于现场操作，不会由普通仓库构建自动执行。

## 语音输入

设备 PTT 不依赖豆包输入法或 BlackHole。按住设备语音键后，ESP32 将 ADPCM 音频通过 BLE 发送给 Mac；Mac 客户端解码为 PCM，交给 macOS `Speech` 框架以 `zh-CN` 识别，并在松开按键后将最终文本输入当前焦点。

使用语音功能前需要：

- 在设备上进入一个已同步的 Codex 会话；未选择会话时 PTT 请求会被拒绝。
- 首次启动新版 App 时允许“语音识别”权限。
- 允许“辅助功能”权限，供 App 向当前焦点注入识别结果。

语音识别服务不可用、权限被拒绝或识别结束超过等待上限时，PTT 会返回失败，不会伪造识别成功。自动化测试不能替代真机说话和焦点文本输入验收。

## 构建与测试

在仓库根目录运行：

```bash
# 构建并测试 macOS 工程
swift build --package-path macos --disable-sandbox
swift test --package-path macos --parallel --disable-sandbox

# 运行固件 host tests 和跨端协议 fixture 校验
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh

# 在已激活 ESP-IDF 环境中构建固件
(cd firmware && idf.py build)
```

生成本机验证用 App：

```bash
zsh macos/Scripts/package-app.zsh release /tmp/codex-remote-build
```

该脚本生成 ad-hoc 签名的 `Codex Remote.app`，适合本机测试，不是面向第三方分发的签名与公证版本。

## 运行与验收

自动化测试只能验证协议、状态机、配置流程和可构建性。屏幕、触控、GPIO18、麦克风、BLE 时序、功耗及完整语音链路必须在真实设备上验收。语音验收应确认设备 PTT 后的最终文本实际进入目标焦点，而非仅检查 BLE 传输或系统权限。现场安装和联调步骤见 [设备到位启用手册](docs/设备到位启用手册.md)。

## 贡献

提交修改前，请阅读 [Repository Guidelines](AGENTS.md)。提交信息采用 Conventional Commits，例如 `fix(mac): 修复会话控制`。只提交本次任务相关文件，并在变更说明中列出实际运行的验证命令和未覆盖的硬件风险。

## License

本项目使用仓库根目录 [LICENSE](LICENSE) 中声明的许可证。
