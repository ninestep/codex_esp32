# 第二阶段验证报告

日期：2026-08-03

范围：冻结 Codex Remote BLE 协议 v1，实现平台无关的二进制 codec、分片与重组、独立帧 IMA-ADPCM、图片资源集原子同步和字节级模拟设备，并建立可供后续 ESP-IDF/Windows 实现复用的 golden fixtures。

本阶段只提供共享协议和模拟证据。没有使用 CoreBluetooth，没有连接 ESP32 实物，没有安装依赖，也没有验证真实 BLE 的 MTU、连接间隔、吞吐、加密配对、功耗、麦克风、触摸或 AMOLED。

## 实施结果

### BLE v1 envelope

逻辑消息采用固定二进制 envelope：

| 字段 | 长度 | 编码 |
| --- | ---: | --- |
| Magic | 2 字节 | ASCII `CR` |
| Major / Minor | 1 + 1 字节 | 当前为 `1.0` |
| Message Type | 1 字节 | v1 固定枚举 |
| Flags | 1 字节 | v1 必须为 0 |
| Sequence | 4 字节 | little-endian `UInt32` |
| Payload Length | 4 字节 | little-endian `UInt32` |
| Payload | 可变 | 消息类型对应的确定性二进制结构 |
| CRC | 4 字节 | CRC32/IEEE，覆盖 header 和 payload |

固定开销为 18 字节，单个重组后 envelope 上限为 256 KiB。解码器显式拒绝错误 magic、不兼容大版本、未知消息类型、非零 flags、截断、长度不一致、CRC 错误、无效 UTF-8、字符串越界和尾随字节。

### v1 消息

已实现并 round-trip 验证 14 类消息：

- 会话与控制：`selectSession`、`scroll`、`terminalKey`、`actionResult`。
- PTT 与音频：`pttBegin`、`pttEnd`、`audioFrame`。
- 状态同步：`stateSnapshot`、`stateDelta`、`resyncRequired`。
- 图片同步：`assetManifest`、`assetChunk`、`assetAcknowledgement`。
- 设备能力：`deviceInfo`。

设备会话投影最多包含八个会话，只发送连接期 `sessionKey`、显示标题、目录简称、状态、受限摘要、未读标记、能力和更新时间。测试证明 BLE 编码结果不包含 `terminalTargetID`、`launcherInstanceID`、`providerSessionID` 或 `remoteSessionID`。

### ATT 分片与重组

envelope 编码后再分片。每个分片使用 8 字节 header：`messageID UInt32`、`fragmentIndex UInt16`、`fragmentCount UInt16`，全部为 little-endian。

重组器的限制和行为：

- 最多 1,024 个分片、256 KiB 重组数据。
- 每个逻辑 channel 同时只保留一个未完成消息。
- 重复、乱序、跨 message ID、分片总数变化、无效 index 和超限均明确失败。
- 失败时清除当前不可信的部分数据；连接 reset 也显式清除。
- 已验证最大 packet 为 20、64 和 185 字节时的切分与重组。

### IMA-ADPCM

音频帧固定为 16 kHz、单声道、20 ms：每帧 320 个 `Int16` PCM 样本编码为 160 字节。每帧独立携带 predictor 和 step index，使用标准 89 项 step table 与 16 项 index adjustment table，低 nibble 对应较早样本。

测试向量包括静音、脉冲、升序斜坡、降序斜坡和正负极值交替。脉冲及斜坡平均绝对误差门限为 1,500，极值交替门限为 8,000。后一帧在不解码前一帧的情况下得到完全相同的输出，证明丢帧后可以从下一独立帧恢复。

### 图片资源集

图片资源采用 pending/active 双状态：

- v1 每组最多八张，模拟内存上限 4 MiB，宽高元数据上限 480×480。
- manifest 必须具有唯一 asset ID、正确总长度、非零尺寸和逐图 CRC。
- chunk 必须连续；重复且字节完全一致的 chunk 幂等，冲突重复、offset gap、越界和错误 set ID 明确失败。
- 只有全部图片长度和 CRC 均通过后才用新集合原子替换 active set。
- 传输中断或取消只清除 pending set，旧 active set 保持不变。

本阶段没有执行 JPEG 像素解码，仅验证 v1 baseline JPEG 的传输元数据、字节长度和 CRC；实际 JPEG 解码峰值内存留到设备端阶段验证。

### 字节级模拟设备

模拟设备只接收经过 message codec 和 fragmentation 的字节包，不绕过协议直接调用内部状态。已验证：

- 连接后分片发送 `deviceInfo`。
- 收到完整 snapshot 前拒绝 delta 并请求 resync。
- generation/sequence 正确时应用 delta；旧 generation 或 sequence gap 请求 resync。
- 选择存在的 session 成功，未知 session 返回 unavailable。
- scroll sequence 去重。
- Enter/Esc `requestID` 去重，同一个请求只执行一次并返回相同结果。
- 未进入会话时拒绝 PTT；进入会话后完成 begin、音频、丢帧统计和 end。
- 畸形分片不应用部分状态，返回 malformed-fragment resync。
- 中断图片同步保留旧 active set，完整替换后才切换新 set。
- 断线清除 session key、选中会话、sequence、请求缓存、录音状态和 pending 图片，但保留已激活图片集。

## Golden fixtures

`macos/Fixtures/ble-v1` 中保存 13 个声明向量：

1. 空详情的成功 action result。
2. 选择会话。
3. Enter 按键。
4. 四会话 snapshot。
5. 八会话 snapshot。
6. 单会话 delta。
7. ADPCM 静音帧。
8. 图片 manifest。
9. 图片 chunk。
10. device info。
11. 错误 CRC。
12. 不兼容 major version。
13. 两分片消息。

`manifest.json` 固定协议版本、字节序、CRC 类型、message type、sequence 和预期结果。`ble-golden-fixtures.zsh` 在私有临时目录重新生成全部文件，再与仓库内容执行递归字节比较；未声明文件、缺失文件或任一字节漂移都会失败。脚本不改写仓库 fixture。

## 测试驱动证据

每个组件均先运行缺少生产类型或 fixture 的定向测试并观察预期失败，再实现最小生产代码并恢复通过：

| 组件 | RED 证据 | GREEN 证据 |
| --- | --- | --- |
| Envelope/CRC | `BLEEnvelopeCodec` 等类型不存在，编译失败 | 7 项定向测试通过 |
| v1 消息 codec | `BLEMessageCodec`、`DeviceSession` 等不存在，编译失败 | 5 项定向测试通过 |
| 分片与重组 | `BLEFragmentCodec`、reassembler 不存在，编译失败 | 6 项定向测试通过 |
| IMA-ADPCM | `IMAADPCMCodec` 不存在，编译失败 | 4 项定向测试通过 |
| 图片集状态机 | `AssetTransferState` 不存在，编译失败 | 5 项定向测试通过 |
| 模拟设备 | `SimulatedRemoteDevice` 和 channel 类型不存在，编译失败 | 6 项定向测试通过 |
| Golden fixtures | `manifest.json` 不存在 | 13 个向量读取验证和临时再生比较通过 |

fixture 再生脚本首次运行发现仓库根计算少一级，形成错误路径 `macos/macos`。修正 `${0:A:h:h:h}` 为 `${0:A:h:h:h:h}` 后，脚本退出码为 0 且无输出。

## 最终验证

| 检查项 | 命令 | 退出码 | 结果 |
| --- | --- | ---: | --- |
| 完整 Swift 测试 | `cd macos && swift test --parallel` | 0 | XCTest 从 `[1/153]` 枚举至 `[153/153]`，无失败、无跳过 |
| Swift 构建 | `cd macos && swift build` | 0 | `Build complete! (0.20s)` |
| 第一阶段 Codex shim 回归 | `zsh macos/Tests/Scripts/codex-shim.zsh` | 0 | 无输出，原有 shim 行为未回归 |
| BLE fixture 再生 | `zsh macos/Tests/Scripts/ble-golden-fixtures.zsh` | 0 | 无输出，临时生成内容与仓库 fixture 逐字节一致 |
| Core 平台边界 | `rg -n 'import (AppKit|SwiftUI|CoreBluetooth|CoreAudio)|Ghostty|AppleScript' macos/Sources/CodexRemoteCore` | 1 | 无匹配，Core 未耦合平台框架或 Ghostty |
| BLE 私有 ID 边界 | `rg -n 'terminalTargetID|launcherInstanceID|providerSessionID' macos/Sources/CodexRemoteCore/BLE macos/Fixtures/ble-v1` | 1 | 无匹配，BLE contract 和 fixture 不暴露内部映射标识 |
| 差异空白检查 | `git diff --check` | 0 | 干净 |

## 未验证项与残余风险

- 尚未使用 CoreBluetooth，因此 characteristic 权限、indication/notify/write 行为、真实 ATT MTU、连接间隔、吞吐、调度优先级和重连时序均未验证。
- 尚未实现 ESP-IDF/C codec。golden fixtures 已冻结 Swift 侧字节结果，但必须在第三阶段由 C 端解码和再编码同一向量，才能证明跨端一致。
- IMA-ADPCM 只通过确定性 PCM 向量验证；未验证 ES7210 的真实噪声、增益、双麦转单声道或豆包识别率。
- 图片状态机目前只使用内存模拟；未验证 ESP32 flash 分区、断电原子性、JPEG 解码内存和真实可容纳图片数量。
- 本阶段没有实现 BLE bonding、加密 characteristic、单主机绑定或恢复出厂设置。
- 第一阶段留下的 `PermissionRequest → requiresInput` 现场专项映射仍需在安装后的正常前台 App 流程复验，与本阶段模拟协议通过无关。

## 第三阶段准入结论

结论：第二阶段共享协议与模拟设备核心链路通过（GO）。

可以在取得下一次明确授权后进入第三阶段，为 ESP32-S3-Touch-AMOLED-2.16 建立 ESP-IDF/BSP 工程，并用本阶段 golden fixtures 实现 C 端跨协议验证。本报告不授权安装 ESP-IDF、引入 BSP/组件依赖、修改分区表、开始 CoreBluetooth/BlackHole 集成、提交或推送 Git。
