# ESP 界面中文化与快捷键页设计

## 目标

本次改动优化 ESP32 端会话列表和详情页，并补齐方向键、固定 Slash 快捷键到 Ghostty 终端的输入链路。

验收结果如下：

- 列表页的整张卡片使用状态色，不再只显示状态色圆点。
- ESP32 页面可见文案使用简体中文。
- 详情第一页保留状态区和上下滑动交互，底部“取消”“确认”按钮宽度缩为现有宽度约一半。
- 详情页右上角可以在“状态”和“快捷键”两页之间切换。
- 快捷键页提供四个方向键和 `/new`、`/q`、`/w`、`/plan`、`/compact`。
- 点击固定 Slash 快捷键后，Mac 聚焦对应 Ghostty 终端，输入完整命令并发送 Enter。

## 列表页

列表保持每屏 2×2 卡片、最多 8 个会话和纵向滚动。每张卡片使用深色状态背景、同色系边框和高对比文字：

| 状态 | 中文 | 背景 | 边框 |
| --- | --- | --- | --- |
| idle | 空闲 | `#27272a` | `#a1a1aa` |
| working | 正在处理 | `#172d55` | `#3b82f6` |
| completeUnread | 已完成 | `#153724` | `#22c55e` |
| requiresInput | 需要输入 | `#4a3011` | `#f59e0b` |
| error | 错误 | `#4a1f23` | `#ef4444` |
| offline | 离线 | `#27272a` | `#71717a` |

卡片右上角显示中文状态。卡片标题和目录保持当前层级；目录使用状态色的浅色变体。删除左上角状态圆点，避免重复表达状态。

页头连接文案改为“Mac 已连接”和“等待 Mac...”。产品名 `CODEX REMOTE` 保留英文专名。

### 中文字体

当前固件没有启用中文字体，只替换字符串会显示方框。实现时在 `firmware/sdkconfig.defaults` 启用 LVGL 内置 `Source Han Sans SC 16 CJK`，并在根屏幕设置 `lv_font_source_han_sans_sc_16_cjk`，让页面控件继承同一字体。该字体同时覆盖界面所需 ASCII 字符，不新增字体文件或第三方依赖。

## 详情页

### 第一页：状态

第一页保留当前标题、目录、状态内容和上下滑动区域。按钮调整如下：

- 左上角：`返回`
- 右上角：`快捷键 ›`
- 左下角：`取消`，发送 Escape
- 右下角：`确认`，发送 Enter

“取消”和“确认”按钮高度保持约 48–54 px，宽度分别约 108 px 和 115 px。按钮保留左右边缘位置，中间留空，降低误触概率。

### 第二页：快捷键

第二页沿用相同标题栏：左上角“返回”返回会话列表，右上角“‹ 状态”切回第一页。

快捷键区使用以下布局：

- 左上角：`/new`
- 右上角：`/q`
- 左下角：`/w`
- 右下角：`/plan`
- 中心：`/compact`
- `/compact` 上、下、左、右分别放置 `↑`、`↓`、`←`、`→`

方向键发送真实终端方向键，不复用滚动消息。Slash 快捷键每次点击生成一个请求 ID；Mac 沿用现有请求去重机制。设备不额外实现连点队列。

如果会话不支持新增能力，右上角“快捷键”按钮显示禁用状态，第一页的确认、取消和滑动功能保持可用。

## 中文文案

| 现有文案 | 新文案 |
| --- | --- |
| Waiting for Mac... | 等待 Mac... |
| Mac connected | Mac 已连接 |
| IDLE | 空闲 |
| THINKING | 正在处理 |
| DONE | 已完成 |
| INPUT | 需要输入 |
| ERROR | 错误 |
| OFFLINE | 离线 |
| BACK | 返回 |
| CANCEL ESC | 取消 |
| CONFIRM ENTER | 确认 |
| REMOTE READY | 远程控制已就绪 |

## BLE 协议 1.1

本次修改保持 major 版本 `1`，将 minor 版本从 `0` 升为 `1`。新增能力和消息均向后兼容：旧 Mac 不声明新能力时，新固件禁用快捷键页。

### 会话能力

保留现有能力位，新增：

- `navigationKeys = 1 << 3`：支持上、下、左、右方向键。
- `terminalShortcuts = 1 << 4`：支持固定 Slash 快捷键。

Mac 1.1 在状态快照和增量中声明这两个能力。ESP32 只有在当前会话同时具备两个能力时才启用快捷键页。

### 方向键

扩展现有 `terminalKey` 枚举：

| 值 | 按键 |
| --- | --- |
| `1` | Enter |
| `2` | Escape |
| `3` | Up |
| `4` | Down |
| `5` | Left |
| `6` | Right |

消息格式保持不变：`request_id + session_key + key`。Mac 将远端按键直接映射成 `TerminalKey`，聚焦目标终端后调用 Ghostty `send key`。

### 固定快捷键消息

新增消息类型 `terminalShortcut = 0x0f`，载荷为：

```text
request_id: u32
session_key: u16
shortcut: u8
```

快捷键枚举固定为：

| 值 | 输入文本 |
| --- | --- |
| `1` | `/new` |
| `2` | `/q` |
| `3` | `/w` |
| `4` | `/plan` |
| `5` | `/compact` |

协议不接受设备提供的任意文本。Mac 根据枚举生成固定字符串，避免把 BLE 输入直接拼接进 AppleScript。

## Mac 输入链路

`MacClientCoordinator` 接收 `terminalShortcut` 后执行现有请求去重和会话选择校验。成功路径如下：

1. 用 `session_key` 解析 `remoteSessionID`。
2. 要求该会话已在设备详情页中选中。
3. `SessionService` 聚焦对应 Ghostty terminal。
4. `TerminalController` 调用 Ghostty `input text` 输入固定命令。
5. 同一控制器随后调用 `send key "enter"`。
6. Mac 返回 `actionResult(success)`；失败时返回 `unavailable`，不伪造成功。

Ghostty 1.3.1 的本机 Scripting Definition 明确提供 `input text` 命令。本实现只输入上述五个常量，不接受协议侧自由文本。

## 固件链路

`cr_ui_callbacks_t` 新增固定快捷键回调。BLE transport 新增 `cr_ble_send_terminal_shortcut(session_key, shortcut)`。UI 点击快捷键后通过回调发送消息，继续复用现有请求 ID、动作结果和去重机制。

详情页维护本地子页状态：

- 进入新会话时默认显示状态页。
- 返回列表或所选会话消失时重置为状态页。
- PTT 活跃时沿用现有交互锁，页面切换、方向键和快捷键都不发送请求。

## 错误与兼容行为

- 未选择会话：Mac 返回 `invalidState`。
- 会话已消失或映射失效：Mac 返回 `unavailable`。
- 未声明快捷键能力：ESP32 禁用快捷键页入口。
- Ghostty 文本输入或 Enter 任一步失败：Mac 返回 `unavailable`；日志保留失败边界，不记录完整终端内容。
- 旧固件连接 Mac 1.1：继续使用协议 1.0 已有功能。
- 新固件连接旧 Mac：快照不含新能力位，快捷键入口保持禁用。

## 测试与验证

### Mac Swift 测试

- `BLEMessageCodecTests`：协议 1.1、四个方向键、五个快捷键和非法枚举。
- `BLEGoldenFixtureTests`：增加方向键和固定快捷键 golden fixture，并同步 C 端解码。
- `GhosttyAppleScriptControllerTests`：固定文本使用 `input text`，随后发送 Enter；终端 ID 仍经过校验。
- `SessionServiceTests`：聚焦、输入文本和 Enter 的调用顺序。
- `MacClientCoordinatorTests`：选中校验、请求去重、快捷键映射、成功和失败结果。

### 固件测试与构建

- C codec/message 测试覆盖 `terminalShortcut` 编解码和非法值。
- UI source/wiring 测试覆盖中文文案、整卡状态色、双页切换、方向键和五个快捷键。
- 构建配置检查确认启用 `Source Han Sans SC 16 CJK`，UI 根节点使用该字体。
- 运行 firmware host tests、golden fixture 校验和 ESP-IDF build。

### 视觉检查

- 在 480×480 视口检查 2×2 卡片、长标题截断和 5–8 个会话滚动。
- 检查六种状态的文字对比度。
- 检查详情两页、禁用态、PTT 锁定态和会话消失后的返回行为。
- 若用户授权刷写固件，再在真实设备上检查点击命中区、AMOLED 色彩和 BLE 动作结果。

## 范围外

- 自定义快捷键编辑器。
- BLE 任意文本输入。
- 快捷键长按、连发或宏序列。
- 自动刷写设备、安装 Mac 应用、提交或推送代码；这些操作需要单独授权。
