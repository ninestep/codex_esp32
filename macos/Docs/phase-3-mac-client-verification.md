# 第三阶段 Mac 客户端验证报告

## 结论

Mac 客户端已达到“应用可构建、可打包，一键配置流程可进入，等待用户授权和真机联调”的状态。首次安装向导、长期“安装与诊断”页、Ghostty/Codex 检查、shim、PATH、hooks、BlackHole、系统权限、豆包快捷键测试和综合功能清单已接通。

本轮没有安装 BlackHole、修改真实 `~/.zshrc` 或 `~/.codex/hooks.json`、申请系统权限、发送真实快捷键、切换系统音频设备或烧录 ESP32。未获得这些现场证据前，不能声称语音识别和真机控制已通过。

## 已实现

- App 启动时自动启动本地 IPC 和 BLE 扫描，不依赖用户先打开菜单栏。
- 首次启动向导包含“基础环境、自动配置、功能测试、完成”四个阶段；设置页保留同源的“安装与诊断”入口。
- 自动配置会先展示实际目标并要求确认；依次处理固定安装位置、透明 `codex` shim、shell PATH 和 Codex hooks。
- 应用复制到 `/Applications/Codex Remote.app` 后不会从临时位置自重启，而是明确要求用户关闭当前实例并从稳定位置重新打开。
- hooks 写入采用合并方式，保留非本工具配置；写入后暂停，要求用户在 Codex `/hooks` 中审查并启动测试会话形成信任证据。
- BlackHole 2ch 永远不随自动配置静默安装；只有用户在独立确认框中同意后，才执行固定的 `brew install --cask blackhole-2ch`。
- 蓝牙、麦克风和辅助功能权限均由用户分别触发；只读检查不会弹出权限请求。
- 豆包语音快捷键支持直接输入、格式校验、按住/切换模式、保存即用于下一次 PTT，以及三秒倒计时后的发送测试。
- CoreBluetooth 固定使用 BLE v1 的 1 个 service 和 6 个 characteristic UUID；最多同步 8 个会话。
- 设备选择会话后聚焦对应 Ghostty terminal，并支持滚动、Enter、Esc。PTT 仅允许当前已进入会话。
- Mac 解码独立 IMA-ADPCM 帧，丢帧补静音，将音频输出到 BlackHole 2ch；结束后松开豆包快捷键并恢复原默认输入。BLE 断开、App 停止或音频错误也会中止 PTT 并执行恢复。

## 自动化验证证据

验证日期：2026-08-03。

| 验证 | 结果 |
| --- | --- |
| `swift test --parallel --disable-sandbox` | 322 个测试用例执行完成，命令退出 0 |
| `swift build --disable-sandbox` | debug 全目标构建成功 |
| `zsh Tests/Scripts/codex-shim.zsh` | 退出 0 |
| `zsh Tests/Scripts/ble-golden-fixtures.zsh` | 退出 0 |
| `zsh Scripts/package-app.zsh release /tmp/codex-remote-setup-build` | release App 生成成功 |
| `codesign --verify --deep --strict` | 本机稳定签名 App 的校验通过 |
| `plutil -lint` | `Info.plist: OK` |
| 打包资源权限 | `codex`、`codex-remote-hook` 为 755；hooks JSON 为 644 |
| Core 层平台 import 扫描 | 无匹配 |
| BLE/Transport 安装层耦合扫描 | 无匹配 |
| `git diff --check` | 退出 0 |

SwiftPM 因沙箱不能写用户级缓存而打印警告，但没有影响测试或构建结果。临时验证产物位于 `/tmp/codex-remote-setup-build/Codex Remote.app`；常规打包默认产物为 `macos/dist/Codex Remote.app`。

## 临时目录配置写入验证

真实用户目录未作为写入测试目标。配置类测试使用注入的临时目录和替身执行器，已覆盖：

- 应用复制、目标替换、备份校验、失败回滚和必须手工重启；
- shim 与 PATH 首次安装、重复执行幂等、标记冲突、符号链接/权限拒绝和恢复；
- hooks 合并、已有内容保留、非法 JSON/结构拒绝、原子替换失败保护和受控恢复；
- BlackHole 缺失、Homebrew 缺失、固定参数、并发拒绝、取消、失败日志和安装后复查；
- 自动配置依赖顺序、并发防重入、失败即停、hooks 信任暂停、BlackHole 独立确认门禁；
- 豆包快捷键解析、标准化、倒计时发送、取消、权限失败，以及 `keyUp` 失败后的输入状态恢复。

这些证据证明写入器和流程控制在隔离环境中的行为，不等同于真实 HOME 已完成配置。

## 只读 UI smoke

从临时 release App 启动了客户端，只做辅助功能树读取和导航，不确认任何系统变更：

- 安装窗口真实创建，标题为“Codex Remote 安装配置”，四阶段导航可切换；
- 基础环境页识别到 Ghostty 1.3.1 和 Codex CLI 0.146.0，并如实提示应用不在稳定位置；
- 自动配置页显示 shim、PATH、hooks、hooks 信任、BlackHole、蓝牙、麦克风和辅助功能状态；
- 点击“开始自动配置”只打开确认框，确认框列出 `/Applications/Codex Remote.app`、`~/.zshrc`、`~/.codex-remote/bin/codex` 和 `~/.codex/hooks.json`，并明确 BlackHole 需要后续独立确认；
- 现场点击的是“取消”，确认框关闭且没有进入自动配置；
- 功能测试页包含豆包快捷键输入与触发模式、本地 IPC、ESP32，以及会话发现、Ghostty 聚焦、页面滚动、Enter、Esc、豆包快捷键、设备音频和 BLE 控制清单；
- 完成页把 Mac 就绪与 ESP32 真机验收分开计算，当前未满足项没有被误报为成功；
- 设置代码入口包含“常规”和“安装与诊断”两个页签，菜单栏提供“设置…”入口。

现场同时发现后台型 `LSUIElement` 应用创建窗口时可能排在当前活动应用下方。`SetupWindowController` 已调整为先激活应用，再显示并强制置前。辅助功能窗口树确认窗口存在；当前图形会话的像素截图仍只捕获桌面，因此没有把截图记为通过证据。

## 本机只读状态

- Codex CLI：0.146.0。
- Ghostty：1.3.1。
- 当前未检测到 BlackHole 2ch。
- 临时 App 不在 `/Applications`，因此向导要求安装到稳定位置后手工重新打开。
- shim、PATH、hooks 信任、蓝牙、麦克风和辅助功能均仍处于待配置或待用户确认状态。

## 尚未授权的真实变更

以下操作仍需用户在向导中明确确认，本轮没有执行：

- 复制或替换 `/Applications/Codex Remote.app`；
- 修改 `~/.zshrc`，创建 `~/.codex-remote/bin/codex`；
- 合并写入 `~/.codex/hooks.json`，并在 `/hooks` 中信任；
- 通过 Homebrew 安装 BlackHole 2ch；
- 申请蓝牙、麦克风、辅助功能权限；
- 保存并发送豆包语音快捷键测试事件。

## 真机验收门禁与风险

- 未运行真实 CoreBluetooth 连接；ATT MTU、重连、indication/notify 时序和持续音频吞吐待真机验证。
- 未烧录 ESP32；屏幕、触控、GPIO18、麦克风、背光、休眠唤醒和功耗待真机验证。
- 未安装 BlackHole，未验证“设备音频 → BlackHole → 豆包输入法”的真实识别结果。
- 未验证 Ghostty 多标签页下的真实会话映射、聚焦、滚动、Enter/Esc 完整链路。
- App 默认使用 `Codex Remote Local Code Signing` 本机稳定签名，适合当前 Mac 的持续更新；它仍不是 Developer ID 签名和公证版本，不适合作为第三方下载分发物。
- 自定义 JPEG 屏保传输、持久化和轮播尚未实现；当前固件只有内置状态屏保。
- SwiftPM 最终汇总行在本机显示“0 tests in 0 suites”，但逐项输出明确列出 `[1/322]` 至 `[322/322]` 且命令退出 0；后续若接入 CI，应继续以进程退出码和逐项结果共同判定。
