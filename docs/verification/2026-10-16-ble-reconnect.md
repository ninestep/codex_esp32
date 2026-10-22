# 蓝牙断线后无法重连排查

## 现场证据

- Mac 保留 `Codex Micro` 配对，系统显示未连接；USB 串口为本次发现的 `/dev/cu.usbmodem1101`。
- App 日志连续出现 `CBErrorDomain Code=14: Peer removed pairing information`。
- 用 CoreBluetooth 扫描可发现设备，但保留旧配对直接连接在 18 秒内未成功。
- 已备份设备 NVS。仅检查记录状态和类型，没有输出配对密钥。`our_sec_1`、`peer_sec_1` 有已删除记录，但没有有效记录；旧 CCCD 和 CSFC 记录仍存在。
- ESP-IDF 5.5.4 的 `ble_store_util_status_rr` 在安全记录溢出时删除最旧配对，在 CCCD/CSFC 溢出时尝试删除其他配对。现有现场证据尚不能确认具体是哪次回调删除了密钥。
- 用户重新配对后，NVS 恢复有效 `our_sec_1` 和 `peer_sec_1`，8 条 CCCD 全部占满，其中 2 条属于旧主机身份。旧固件第一次重启成功自动重连，串口收到 HID RPC 和 Agent 状态更新。这说明故障不是每次重启必现。

## 容量修正

原配置允许保存 3 台主机的配对，持久化 CCCD 总容量仅为 8。Codex Micro 的 HID 输入、Boot Keyboard、Battery、Service Changed 和伴侣服务合计每台主机最多需要 8 条订阅记录。

将默认 CCCD 容量设为 24，并在 CMake 中检查容量至少为配对数量的 8 倍。现有本地 `sdkconfig` 也须同步设置；仅修改 defaults 不会覆盖已生成配置。

该改动覆盖容量不足的问题，不代表已确认本次密钥删除的完整原因。已经丢失的密钥不能由增加容量恢复。

## 验证与待办

- 原 `sdkconfig` 为 8 时，`idf.py -D SDKCONFIG_DEFAULTS=sdkconfig.defaults reconfigure` 被新增检查拒绝，提示至少需要 24 条 CCCD。
- 本地配置更新为 24 后，ESP-IDF 5.5.4 构建成功，生成配置确认 `CONFIG_BT_NIMBLE_MAX_CCCDS=24`。
- `IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 zsh firmware/test/host/run-tests.zsh all` 通过；`git diff --check` 通过。
- 后续操作中旧固件再次出现配对错误，新固件初次启动沿用该失效状态时，App 报 Code 14，设备反复连接后断开，未收到 HID RPC。
- 已备份旧应用分区至本机临时目录；新固件只写应用分区 `0x10000`，esptool 校验成功。二进制 SHA-256 为 `69abf480fb06a321815d90e05441065232821cdc2ffc1f8e8750fa007dc2d221`。
- 尝试恢复本轮成功配对时的 NVS 备份后，CoreBluetooth 仍连接超时。用户随后在新固件上重新建立配对。

## 新固件实机结果

新配对建立后，串口确认伴侣通道就绪、HID 通知就绪、收到主机 RPC 并发出响应。随后连续执行 3 次 USB 重启；每轮先读取 NVS 快照，再重启并捕获 28 秒串口日志。

| 验证 | 伴侣通道与 HID 通知就绪时间（设备启动后） | 结果 |
| --- | --- | --- |
| 第一次重启 | 约 3.95 秒 | 自动重连，HID RPC 请求与响应成功 |
| 第二次重启 | 约 5.58 秒 | 首次连接超时，自动重试后成功 |
| 第三次重启 | 约 5.77 秒 | 自动重连，HID RPC 请求与响应成功 |
| 系统设置主动断开 | 断开后约 1.05 秒 | 自动重连，约 2.50 秒后收到 HID RPC 并响应 |

以上过程没有再次忽略设备或重新配对。三份 NVS 快照均保留 1 条本端和 1 条对端安全记录。第一、第二轮快照中均有 9 条有效 CCCD，超过旧配置的 8 条上限，证实现场确实需要更大的订阅容量。

主动断开测试的串口证据（设备 uptime）：

```text
23676  Codex Micro host disconnected: 531
24125  Codex Micro host connected
24725  Mac companion channels ready
24725  HID input notifications ready
25831  host RPC received
25837  RPC response sent
```

最终系统蓝牙显示 `Codex Micro 已连接`。本轮覆盖设备重启和系统主动断开；未做长时间待机、跨电脑配对或语音输入验证。第二轮 App 曾记录 Code 15 加密超时，自动重试后恢复；本轮新固件连续验证未再出现 Code 14 配对丢失。旧固件删除密钥的具体存储回调没有被直接捕获，因此容量不足有现场与修正后的验证支持，但不能声称已完整观测其内部删除过程。
