# Codex Micro 会话操作页设计

日期：2026-08-09

## 目标

设备在原生 Codex Micro 模式下完成两级操作：列表页选择 Agent，操作页触发 Codex Desktop 的六个原生 Command 槽和两个标准键盘动作，并提供可自定义的旋钮与四方向摇杆。操作事件仍直接通过 HID 发送，不依赖 Mac App；Mac App 只负责读取当前 `config.toml` 并通过伴随 BLE 通道同步各控件的显示名称。

## 已确认协议

Codex Desktop 当前使用以下私有 HID 键位。协议可能随 Desktop 版本变化，固件必须把映射集中在 `codex_micro_hid`，不得在 UI 中拼接 JSON。

| 操作 | HID 键位 | UI 文案来源 | 发送方式 |
| --- | --- | --- | --- |
| Command 1...6 | `ACT06`、`ACT07`、`ACT08`、`ACT09`、`ACT10`、`ACT12` | `desktop.codex-micro-layout.slots` | press + release |
| Delete | 键盘 Report 7 | 删除 | Backspace press + release |
| Clear | 键盘 Report 7 | 清除 | Command+A、释放、Backspace、释放 |

实体按钮继续承担说话、确认和取消：长按使用 `ACT10`，短按使用 `ACT12`，双击使用 `ACT08`。操作页仍展示这六个槽的当前设置，让设备显示与 Codex Desktop 的实际布局一致。

伴随 BLE 协议 v1.3 新增 `MICRO_CONTROL_LAYOUT`（`0x10`）。消息固定携带六个 Command 文案、一个旋钮文案和按上、右、下、左顺序排列的四个摇杆文案；单项最多 48 字节 UTF-8。Mac App 在收到设备信息后读取 `[desktop.codex-micro-layout]` 的 `slots`、`encoderMode` 和 `analogStick`，完成语义化文案映射后下发。设备断开伴随通道时保留默认文案，不能因为配置暂时不可读而失去操作能力。

加入键盘 Report 后，固件把设备 release 从 `0x0101` 升到 `0x0102`，并在每次启动后的首次连接发送一次 GATT Service Changed，要求已配对的 macOS 主机重新发现报告描述符，避免继续使用只有 Vendor Report 的旧缓存。

旋钮与摇杆使用 Codex Micro 原生输入协议：旋钮按下为 `ENC_PRESS` 的 press/release，左右旋转为 `ENC_CC`/`ENC_CW` 的离散事件；摇杆使用 `v.oai.rad`。Codex 设备库要求角度和距离都归一化到 `0～1`，按上、右、下、左分别发送角度 `0.75`、`0`、`0.25`、`0.5`，并在松开或滑出时发送距离 `0`。实际动作由 Codex Desktop 设置决定，固件不得写死。

## 页面流程

1. 首页继续显示六个 Agent 卡片。
2. 用户点击卡片时，设备先发送对应 `AG00...AG05` 的 press/release。
3. 完整点击结束后，设备进入该 Agent 的操作页。操作页标题只显示 `AGENT 1...6`，不伪造会话名称。
4. 用户点击“返回”回到列表。返回不发送 Agent 或 Command 事件。
5. Codex Desktop 或 BLE 断开时，设备关闭操作页、回到列表并清除本地按压状态。

设备只记住用户最后点击的 Agent。当前私有协议没有明确的“选中 Agent”字段，因此 UI 不声称远端已经确认选择，也不绘制伪选中标记。

设备实体 GPIO18 按键沿用既有 `350 ms` 长按阈值、`250 ms` 双击窗口和 `20 ms` 去抖。在 Codex Micro 模式下，短按发送 `ACT12` 的 press/release 作为确认或发送，双击发送 `ACT08` 的 press/release 作为取消或拒绝，长按达到阈值时发送 `ACT10 act=1` 开始说话，松开时发送 `ACT10 act=0`。短按必须等待双击窗口结束后再发送，长按不得额外触发短按或双击动作。

## 操作页布局

操作页使用 480×480 全屏布局。顶部保留返回、Agent 标题和当前颜色状态；下方使用 2×5 按钮：

| 行 | 左侧 | 右侧 |
| --- | --- | --- |
| 1 | Command 1 | Command 2 |
| 2 | Command 3 | Command 4 |
| 3 | Command 5 | Command 6 |
| 4 | 删除 | 清除 |
| 5 | 旋钮 | 摇杆 |

六个 Command 的文案由 Mac 当前布局动态更新，保持中性色，避免根据槽位误判动作语义。旋钮入口同时显示当前 `encoderMode`；摇杆面板分别显示上、右、下、左当前动作。

旋钮入口打开同心圆控制面板。外圈左半区表示逆时针，右半区表示顺时针：短按发送一个离散旋转事件；持续按住时，在 LVGL 长按阈值后按 repeat 事件连续发送旋转事件。中心圆形按钮按下时发送 `ENC_PRESS act=1`，松开或滑出时发送 `act=0`，由 Codex Desktop 根据持续时间区分单击与长按。中心按钮必须位于外圈触摸区上层，避免一次触摸同时产生旋转和按键事件。

摇杆入口打开独立四方向面板。每个方向按下时发送 `d=1`，松开或滑出时发送 `d=0`。返回操作页前不得存在仍保持按下的旋钮或摇杆方向。

## 输入语义与误触边界

- Command 按钮只监听 `PRESSED`、`RELEASED` 和 `PRESS_LOST`，不使用 `CLICKED` 发送命令。
- 每次有效按压最多产生一组 press/release。重复的 release 或 `PRESS_LOST` 不得重复发送。
- 同一时刻只允许一个 Command 保持按下。第二个按钮按下时直接忽略，不抢占第一个按钮。
- 旋钮按下和摇杆方向共用按压互斥保护，防止切页或多点触控产生粘键。
- 六个 Command 均直接发送，不增加软件确认框；这与实体 Codex Micro 按键语义一致。
- 删除和清除作用于 Mac 当前聚焦的输入控件；设备触摸不会改变 Mac 当前焦点。
- 断连时不伪造成功；UI 退回列表，transport 负责报告不可用错误。
- 状态刷新不能把仍然连接的操作页强制切回列表。

## 测试门禁

### 协议测试

- 六个原生 Command 的 press/release 分别编码为 `ACT06`、`ACT07`、`ACT08`、`ACT09`、`ACT10`、`ACT12`。
- press 的 `act=1`，release 的 `act=0`。
- 越界 Command 返回 `CR_MICRO_RPC_INVALID_REQUEST`。
- 键盘 HID 使用独立 Report 7；删除编码为 Backspace/释放，清除编码为 Command+A/释放/Backspace/释放。
- `MICRO_CONTROL_LAYOUT` 对六键、旋钮和四方向文案进行跨端编解码，拒绝缺项、超长文本和错误协议版本。

### UI 结构测试

- UI 声明独立的 `micro_action_page` 和 `micro_control_key` callback。
- 操作页包含六个动态 Command、“删除”“清除”和返回入口。
- 操作页包含旋钮和摇杆入口；旋钮页包含左右旋转、按下/长按，摇杆页包含上、右、下、左。
- Mac 配置解析覆盖 `slots`、`encoderMode` 和 `analogStick` 四个方向，并在设备信息握手后下发布局。
- Command 按钮注册 `PRESSED`、`RELEASED`、`PRESS_LOST`，并保存当前按压项防止重复 release。
- `app_main` 将 UI callback 分别连接到 `cr_codex_micro_hid_send_control_key` 和 `cr_codex_micro_hid_send_keyboard_action`。
- Codex Micro 状态刷新保留已打开的操作页；断连关闭操作页。

### 真机验收

- 点击六个 Agent 均能切换并进入对应操作页。
- 六个 Command 各执行一次，Codex Desktop 行为与设置一致。
- 修改 Codex Desktop 的六键、旋钮或任一摇杆方向设置并重连后，设备显示同步更新。
- 删除只移除当前输入的一个字符；清除移除当前输入的全部内容。
- 实体长按说话、短按确认、双击取消保持有效。
- 快速重复点击不产生卡死按键或重复动作。
- 操作页停留期间状态颜色继续更新。
- 重启 Codex Desktop、关闭蓝牙和重新连接后，设备恢复到可操作状态。
