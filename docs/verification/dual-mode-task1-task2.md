# 双模式 Task 1 / Task 2 验证记录

验证日期：2026-08-08

## 范围

- Task 1：连接模式 reducer、独立 NVS schema、首次启动模式选择/确认、启动分流。
- Task 2 软件部分：Codex Micro vendor HID framing、最小 RPC、ESP-IDF NimBLE HOGP adapter。
- 不包含：macOS 配对、Codex Desktop 检测、实体按键事件验收。

## 已验证行为

- 未配置和非法模式值不会启动 BLE transport，也不能接收普通输入。
- 模式变更必须二次确认，确认后锁定输入、结束活跃 PTT、保存并重启。
- Mac App 增强模式继续使用已有自定义 BLE/ADPCM transport。
- 原生模式只启动新 HOGP transport，不会误启动旧自定义 BLE service。
- HID descriptor 使用 Vendor Usage Page `0xFF00`、Application Usage `0x01`、Report ID `6`、63-byte input/output report。
- vendor report 使用 type `2`、最多 61-byte UTF-8 JSON payload、换行终止和 4096-byte 累积上限。
- 最小 host method 白名单为 `sys.version` 和 `device.status`；未知 method 返回 `-32601`。
- 已提供 `AG00` 至 `AG05` press/release 事件编码 API，Task 3 再接设备 UI。

## 自动验证

```text
zsh firmware/test/host/run-tests.zsh test_connection_mode
result: PASS

zsh firmware/test/host/run-tests.zsh test_codex_micro_vendor_frame
result: PASS

zsh firmware/test/host/run-tests.zsh all
result: exit 0

env IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 \
  /Users/wj/.espressif/tools/cmake/3.30.2/CMake.app/Contents/bin/cmake --build build
result: exit 0
image: codex_remote.bin 0x1ea620 bytes
smallest app partition: 0x800000 bytes
free: 0x6159e0 bytes, 76%
```

基线镜像为 `0x1dd840` bytes；启用 NimBLE HID service、DIS PnP 字段和最小协议实现后增加 `0xcde0` bytes（52,704 bytes）。

## 兼容性依据

- OpenAI Codex Micro 用户文档：<https://learn.chatgpt.com/docs/features/codex-micro>
- 独立兼容实现：<https://github.com/imliubo/codex-micro-4-core2>
- 兼容实现技术说明：<https://github.com/imliubo/codex-micro-4-core2/blob/main/docs/TECHNICAL.md>
- ESP-IDF 5.5.4 本机源码：`examples/bluetooth/esp_hid_device` 与 `components/esp_hid`。

上述 vendor HID identity 和 JSON-RPC 行为不是 OpenAI 公开稳定协议。当前实现只说明“可构建且纯协议测试通过”，不能在没有实体配对证据时声称 ChatGPT Desktop 已识别。

## 硬件门禁

当前桌面应用已确认改名为 Codex：

- Path: `/Applications/Codex.app`
- Bundle ID: `com.openai.codex`
- Version: `26.803.41515`
- Build: `6321`

用户已单独授权刷机。2026-08-08 通过 `/dev/cu.usbmodem101` 刷写成功：

- USB VID/PID: `303A:1001`
- USB serial: `28:84:85:90:77:04`
- Chip: ESP32-S3 revision v0.2, 8 MB PSRAM, 16 MB flash
- bootloader、partition table、应用镜像均通过写后 hash 校验。
- 启动日志确认显示、触摸和 LVGL task 正常初始化。
- 首次启动输出 `waiting for first connection mode selection; BLE is disabled`，证明选择模式前没有启动歧义 BLE 广播。

用户已在首次启动页选择 `CODEX MICRO` 并二次确认。重启日志确认 NVS 保留原生模式，且只启动 HOGP：

```text
codex_micro_hid: Codex Micro HOGP ready VID=303A PID=8360 report=6
NimBLE: GAP procedure initiated: advertise
codex_micro_hid: Codex Micro host connected
```

macOS 蓝牙现场枚举已通过：

```text
Connected:
    Codex Micro:
        Address: 28:84:85:90:77:06
        Vendor ID: 0x303A
        Product ID: 0x8360
        RSSI: -42
        Services: 0x400000 < BLE >
```

首次发现时 macOS 曾用同一地址显示历史缓存名 `Codex Remote`；完成连接后名称刷新为 `Codex Micro`。连接过程出现一次配对握手重连（disconnect reason 531），随后保持连接。

以下门禁仍未执行：

- 在 Codex Desktop 中确认出现 Codex Micro 设置入口。
- 抓取至少一条 `sys.version` 或 `device.status` 请求并验证响应。
- 触发一组 Agent key press/release 并确认 ChatGPT 接收。

当前 Codex 进程已运行，但连接后 15 秒串口观察期内尚未收到 output report。macOS 拒绝 `osascript` 读取 Codex 辅助功能树，因此设置入口需要用户在 Codex 界面人工确认；该权限失败不作为设备协议失败证据。

用户确认 Codex 界面没有出现 Micro 图标、引导或设置入口。进一步检查已安装 Codex 的实际识别逻辑：

```text
VID: 12346 (0x303A)
PID: 33632 (0x8360)
PrimaryUsagePage: 65280 (0xFF00)
transport: Bluetooth
```

固件 HID report descriptor 与 `codex-micro-4-core2` 的已验证实现逐字节一致，但 `ioreg -r -c IOHIDDevice` 中不存在 `VendorID = 12346` 的设备。这说明当前连接只完成 BLE/GATT 层，macOS 没有把新 HOGP descriptor 注册成 Codex 可扫描的 IOHID 接口。

首次扫描时，同一地址 `28:84:85:90:77:06` 曾显示历史名称 `Codex Remote`，证明 macOS 沿用了模式切换前的配对/GATT 缓存。参考实现的故障排查也明确要求：HID descriptor 发生变化后，先在蓝牙设置中忽略旧设备，再重新配对；若仍未识别，再确认输入监控权限并完全重启 Codex。

用户忽略旧设备并重新配对后，macOS `bluetoothd` 已完成 HID Service、Report Map、PnP ID 和 Report Reference 的读取，并记录：

```text
LE HID connection complete for address: 28:84:85:90:77:06 (VID:0x303A/PID:0x8360)
Device "Codex Micro" is Compatible LE HID
```

但是 `hidutil list` 与 `ioreg -r -c IOHIDDevice` 仍未出现该设备。进一步对照参考仓库使用的 Arduino `BLEHIDDevice` 后确认：参考实现的 HID Report characteristic 要求加密读写，而当前 ESP-IDF NimBLE 配置为 `CONFIG_BT_NIMBLE_SM_LVL=0`，没有给 HID characteristic 添加 Level 2 加密访问要求。这不符合 HOGP 对 HID Device 使用 LE Security Mode 1、Security Level 2 或 3 的要求。

经用户确认，已将 `firmware/sdkconfig.defaults` 和当前 `firmware/sdkconfig` 调整为：

```text
CONFIG_BT_NIMBLE_SM_LVL=2
```

生成配置已验证为 `#define CONFIG_BT_NIMBLE_SM_LVL 2`。调整后的自动验证结果：

```text
zsh firmware/test/host/run-tests.zsh all
result: 11 tests PASS

zsh firmware/test/host/verify-golden-fixtures.zsh
result: exit 0

idf.py build
result: exit 0
image: codex_remote.bin 0x1ea640 bytes
smallest app partition: 0x800000 bytes
free: 0x6159c0 bytes, 76%
```

新镜像尚未刷写。刷写后必须再次忽略旧设备并重新配对，现场确认连接已加密且 IOHID 节点出现，才能继续判断 Codex Desktop 设置入口。

若 Codex Desktop 不识别，必须记录 App 版本、HID descriptor、PnP ID、配对状态和串口请求日志，并停止 Task 3；不得用普通键盘快捷键伪装成功。

## Task 2 现场补跑与 Task 3 软件验证

安全等级修复镜像刷写并重新配对后，macOS 已注册原生 HID 节点；`hidutil list` 显示：

```text
VID 0x303a  PID 0x8360  UsagePage 65280  Usage 1
Transport: Bluetooth Low Energy
Product: Codex Micro
```

用户已确认 Codex Desktop 能识别 Codex Micro。随后 Codex Desktop 日志持续出现：

```text
Error calling RPC ... method: v.oai.rgbcfg ... code: TIMEOUT
Codex Micro control-plane initialization failed
```

对照当前 Codex App 内置 Work Louder 客户端和 Arkey 兼容实现后，确认 host 的完整 JSON
不保证以换行结束；旧 reassembler 只能靠换行交付消息，导致 `v.oai.rgbcfg` 从未进入 RPC
codec。Task 3 本轮修复并覆盖以下行为：

- JSON 结构闭合时即可交付，同时保留换行兼容和 UTF-8、长度边界校验。
- 接收并确认 `v.oai.rgbcfg`、`v.oai.thstatus`、`host.focused_app`。
- 建立独立 `cr_micro_state_t`，保存六槽灯光状态、全局灯光和连接状态。
- 提供 `AG00...AG05`、`ACT06/07/08/09/10/12`、旋钮和四方向的原生事件编码。
- 原生模式 UI 固定显示六个 Agent 槽位及真实颜色/亮度；协议没有标题时不生成假标题。
- 触摸槽位只发送 press/release，由 Codex Desktop 解释单击、双击或长按。

自动验证：

```text
zsh firmware/test/host/run-tests.zsh test_codex_micro_vendor_frame test_codex_micro_state
result: 2 tests PASS

zsh firmware/test/host/run-tests.zsh all
result: exit 0

zsh firmware/test/host/verify-golden-fixtures.zsh
result: exit 0

git diff --check
result: exit 0

env IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 \
  /Users/wj/.espressif/tools/cmake/3.30.2/CMake.app/Contents/bin/cmake --build firmware/build
result: exit 0
image: codex_remote.bin 0x1ead80 bytes
smallest app partition: 0x800000 bytes
free: 0x615280 bytes, 76%
```

本镜像尚未刷写。`rgbcfg` timeout 是否消失、六槽状态是否与 Codex Desktop 一致，以及实体
触摸 press/release 是否被接收，仍属于下一次刷写后的硬件门禁。

## Task 3 原生 HID 控制面真机闭环

2026-08-09 已将最终镜像写入 `/dev/cu.usbmodem101`，bootloader、partition table 和应用镜像均通过写后 hash 校验：

```text
image: codex_remote.bin 0x1ebe40 bytes
sha256: 445354030d3482f0692508f0b811b0b5d1f3d8b26fe2f6b30d0fe945ee43f08c
smallest app partition: 0x800000 bytes
free: 0x6141c0 bytes, 76%
```

现场确认 ESP-IDF 5.5.4 的 NimBLE HIDD 不投递 `ESP_HIDD_OUTPUT_EVENT`，而是把 host 写入保存在 HID service 的 output report 缓冲区。本项目增加适配桥接任务读取该缓冲区，并兼容 macOS IOHID 实际写入的 64 字节原始报告（首字节为 report ID 6）。

最后一个阻塞点是事件时序竞态：NimBLE 先投递订阅事件并建立 `0x002e` output report 桥接，随后才投递 `BLE_GAP_EVENT_CONNECT`。旧 connect 分支在桥接建立后把指针清空，导致 Codex 的 GATT 写入虽然成功，固件却永远看不到报告。现已只在 disconnect 时清理桥接状态，避免晚到 connect 事件破坏已建立的订阅。

最终固件串口证据：

```text
HID output bridge ready: handle=0x002e
HID input notifications ready: handle=0x002a
Codex Micro host connected
host HID report received: 64 bytes       # 3 fragments
host RPC received: 134 bytes
RPC response sent: 24 bytes
host HID report received: 64 bytes       # 7 fragments
host RPC received: 372 bytes
RPC response sent: 24 bytes
host HID report received: 64 bytes       # 1 fragment
host RPC received: 48 bytes
RPC response sent: 119 bytes
```

Codex Desktop 同步日志确认控制面不再超时：

```text
Received answer ... method: v.oai.rgbcfg
Received answer ... method: v.oai.thstatus
Received answer ... method: device.status
{"version":"0.2.0-codex-remote","profile_index":0,"layer_index":1,"battery":100,"is_charging":false}
```

连接保持后，Codex Desktop 的 60 秒 `device.status` 轮询继续收到响应。自动回归结果：

```text
zsh firmware/test/host/run-tests.zsh all
result: 12 tests PASS

zsh firmware/test/host/verify-golden-fixtures.zsh
result: exit 0

ESP-IDF incremental build
result: exit 0

git diff --check
result: exit 0
```

至此原生 HID 的发现、订阅、host RPC 接收、分片重组、RPC 响应和周期状态查询已完成真机闭环。实体屏幕触摸的短按、双击和长按语义仍需人工触摸验收；自动协议和烧录验证不能替代该物理输入门禁。
