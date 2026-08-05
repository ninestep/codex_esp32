# 第三阶段 ESP32-S3 固件验证报告

## 结论

固件已使用 ESP-IDF v5.5.4、Waveshare BSP 2.0.1 和 LVGL 9.5.0 完成构建，生成可烧录的 bootloader、分区表和应用镜像。本轮严格未执行烧录或 monitor，因此结论是“构建准入”，不是“真机通过”。

## 已实现

- NimBLE peripheral 和冻结的 BLE v1 六 characteristic GATT 服务。
- 480×480 LVGL 首页：首屏 2×2 四张卡，最多八会话纵向滚动。
- 会话详情、触摸滚动、触摸 Enter/Esc，以及 GPIO18 单击 Enter、双击 Esc、长按 PTT、松开结束。
- ES7210 16 kHz 音频采集、400 ms RAM pre-roll、独立 20 ms IMA-ADPCM 帧和 BLE notify 输出，不写入 flash。
- 60 秒降亮、120 秒内置状态屏保、300 秒息屏；实体键唤醒、PTT 保持常亮、琥珀/红状态唤醒 8 秒。
- 图片 manifest/chunk/CRC、重复 chunk 幂等、冲突/缺口拒绝、pending/active 原子状态核心。平台 flash 双区存储、JPEG 显示和 Mac 发送 UI 尚未接入。

## 验证证据

| 验证 | 结果 |
| --- | --- |
| `zsh firmware/test/host/run-tests.zsh all` | 7 个 C17 + ASan/UBSan 目标全部 PASS |
| `idf.py build` | 成功生成 ESP32-S3 镜像 |
| 应用镜像 | `firmware/build/codex_remote.bin`，大小 `0xe7ee0` |
| 应用分区余量 | `0x718120`，89% free |
| bootloader | `0x5700`，32% free |

构建依赖解析记录：ESP-IDF 5.5.4、`waveshare/esp32_s3_touch_amoled_2_16` 2.0.1、LVGL 9.5.0、`esp_codec_dev` 1.5.11。

## 产物

```text
firmware/build/bootloader/bootloader.bin
firmware/build/partition_table/partition-table.bin
firmware/build/codex_remote.bin
```

## 未验证与风险

- 未烧录，因此显示初始化、触控坐标、GPIO18 电平、ES7210 通道、BLE 广播、配对和功耗均待真实设备验证。
- GATT 要求加密且启用 bonding/Secure Connections；当前为 Just Works，因设备尚无数字确认 UI，MITM 未启用。
- 自定义 JPEG 只有协议和原子状态核心；7 MiB 分区的双区持久化、断电恢复、JPEG 解码显示和 Mac 上传尚未实现。
- 电量当前上报固定值 100%，尚未接入真实 PMU/电池测量。
- 多分片 indication 的真实控制流、音频丢包率和长时稳定性必须在真机上测量。
