# 整机电流与休眠状态核验

用户确认没有电流测量设备。当前没有可读取的外部电流仪器；不能交付整机电流、实测电池容量或日志写入电流增量。此前约 70 mA 是按标称 1000 mAh/14.286 h 的估算，不能作为测量结果。

## 已确认的休眠阻碍

- 当前构建产物 SHA-256 为 `8e1c30838a998d7825c4c40ce366b51eb22312ef9f34ed6d9638ddfb8f409e52`，与已烧录并验证的版本一致。
- 生效构建配置 `/tmp/esp32-charging-sdkconfig-20260907`：`CONFIG_PM_ENABLE=y`、tickless 开启；`CONFIG_BT_CTRL_MODEM_SLEEP` 未启用、`CONFIG_BT_CTRL_SLEEP_MODE_EFF=0`；`CONFIG_PM_PROFILING` 未启用。CPU 最大配置 240 MHz，应用配置最低为 40 MHz。
- 当天真机启动日志 `/tmp/power-drain-20260908-retry.raw.log` 明确输出 `light sleep mode will not be able to apply when bluetooth is enabled.`。
- ESP-IDF 5.5.4 蓝牙控制器源码 `components/bt/controller/esp32c3/bt.c`（ESP32-S3 使用该控制器实现）1776–1781 创建 `btLS` 禁止轻睡眠锁及 `bt` APB 最大频率锁；2079–2082 在控制器启用时获取锁。当前应用灭屏路径没有禁用蓝牙控制器。
- 因此，当前 BLE 控制器保持启用时，灭屏不解除禁止自动轻睡眠的锁。APB 最大频率锁也限制降频；不能将应用配置了 40 MHz 下限等同于真机已经降至 40 MHz。没有 CPU 频率/休眠时间统计，不能给出各频率或睡眠状态的实测占比。

## 电流和容量测量边界

AXP2101 手册 6.10/6.11 列出的 ADC 为电压/温度，电量计对外给出电量百分比及电池电压，现有公开接口没有可供本任务使用的电池瞬时充放电电流读数。500 mA 寄存器是充电上限，不能替代电流传感器。

实测实际容量需要在指定条件下积分电池电流与时间；电量百分比本身不能独立验证电量计准确性。USB 电流混入设备供电、充电及转换损耗，不能直接当作电池放电电流。

日志写入影响需要相同电池电压、BLE 状态和工作负载下，比较记录开启/关闭的电流积分。无仪器时只能做重复续航对照，得到相对续航差；不能由单次曲线分别算出容量、基础耗电和写入耗电。

本次完成配置、已采集真机启动证据及驱动锁行为核验，未改动/烧录固件；仪器电流测试未进行。可优先处理蓝牙省电和轻睡眠阻碍，再通过低开销状态统计及重复续航实验验证软件优化。连接/断开、HID 和 PTT 唤醒需同时回归。

依据：[Espressif ESP32-S3 电源管理](https://docs.espressif.com/projects/esp-idf/en/v5.5.4/esp32s3/api-reference/system/power_management.html)、[AXP2101 手册](https://files.waveshare.com/wiki/common/X-power-AXP2101_SWcharge_V1.0.pdf)。
