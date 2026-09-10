# 充电初始化修正与诊断

当前状态：已按用户明确要求将充电上限提高到 500 mA（1000 mAh 电池的 0.5C），完成构建、烧录和芯片参数读回。100 mA 中间版本未烧录。

## 显示 100% 后的曲线检查（11:28）

- 使用不复位设备的串口监视读取，11:26:32–11:28:32 的五组配对采样均为 `battery=100% charging=yes stage=cv`，电池电压 4196–4198 mV。最新运行时间 1473298 ms，与此前烧录后的运行时间连续。
- 当前处于恒压收尾，尚未采到 `stage=done`；显示 100% 不等于芯片已经终止充电。VBUS 为 5099–5105 mV，五次采样均 `vbus_good=1 vindpm=0 current_limited=0 thermal_regulation=0`。
- 11:04:00 为 90% / 4163 mV / CC，11:04:31 已转 CV，11:05:31 为 91% / 4181 mV。11:05:31 到 11:26:32 没有电量及电池电压采样，因此无法确定首次显示 100% 的时刻，图中不连接这个缺口。
- [实测趋势图](2026-09-07-charging-curve.svg)及[原始充电采样](2026-09-07-charging-curve.log)已保存。图表示电压与电量趋势；没有实测电流，无法给出实际电流曲线或积分充入容量。
- 本次没有修改或烧录固件，采样结束后已退出串口监视。监视工具第一次因自身 Logger 异常退出，修正监视参数后成功采样；该异常不属于设备重启。

## 500 mA 最终验证

- 全部 17 个主机测试目标、ESP-IDF 5.5.4 构建及 `git diff --check` 通过。固件大小 `0x1f7200` 字节，SHA-256：`12e6873640af1e8981e19213f583cc224297c9e505afb4e5870d673485b9392b`。
- 串口 `/dev/cu.usbmodem1101`，ESP32-S3 rev v0.2，三段烧录均 `Hash of data verified`，退出码 0。使用上文恢复后的 16/32 KiB 缓存、单 LVGL 绘制线程配置。
- 11:03:59–11:05:39 采集约 100 秒，ELF SHA 前缀 `c7cd484df`；音频、设备及 Mac companion/HID ready，无后续 panic/OOM 重启。
- 芯片读回 `cc_limit_ma=500 target_mv=4200 cc=0x0b`，输入上限仍为 1500 mA，保护和终止配置保持不变。
- 充电阶段从 `cc` 转为 `cv`；末次采样 `uptime_ms=92270 battery=91% voltage=4181mV charging=yes`。VBUS 约 5.01–5.04 V，采样期间 `vindpm=0 current_limited=0 thermal_regulation=0`。
- 90% -> 91% 和电压变化为短时读数，不能外推完整充电曲线。500 mA 是配置上限，不是实测电流；恒压阶段自动降流。历史 `charge_timeout_latched=1` 仍保留，当前并未停止充电。
- 日志路径：`/tmp/esp32-charging-500ma-20260907.log`。此次未验证充满时间、长期温升或待机屏幕关闭；没有 commit/push。

100 mA 中间版本已通过全部 17 个主机测试目标、ESP-IDF 构建和 `git diff --check`，但当时设备 USB 断开，未写入设备。有效配置仍为 16/32 KiB 指令/数据缓存、1 个 LVGL 绘制线程，省电与 tickless 开启。

## 问题与证据

用户报告连续插电三天、未使用，电量仅到 88%。诊断窗口读到 `battery=88% voltage=4037mV charging=yes`，但没有连续三天的日志和实测电流，尚不能确认完整根因或充电效率。

原初始化只清除了 `0x30[1]`（TS ADC），没有设置 `0x50[4]`（TS 是否影响充电）和 TS 电流源。Waveshare 此板的官方示例明确要求关闭无电池温度检测接线的 TS 功能；XPowersLib 实现同时处理 `0x50` 和 `0x30`。

- [Waveshare 示例](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.16/blob/main/examples/esp-idf/01_AXP2101/main/port_axp2101.cpp)
- [XPowersLib TS 配置实现](https://github.com/lewisxhe/XPowersLib/blob/master/src/XPowersAXP2101.hpp)
- [板卡原理图](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-2.16/ESP32-S3-Touch-AMOLED-2.16-Schematic.pdf)
- [AXP2101 寄存器手册](https://files.waveshare.com/wiki/common/X-power-AXP2101_SWcharge_V1.0.pdf)

## 改动

- 将 `0x50[4:0]` 设为 `0x10`，关闭未接电池 NTC 的充电影响和 TS 电流源；保留其他位。
- 关闭 TS ADC，启用电池及 VBUS ADC。对所有初始化写入的目标位执行读回校验，失败明确上报。
- 初始化前后打印 `charger_config`，记录输入限流、恒流上限、目标电压及原始配置。
- 每次电池轮询打印 `charger_sample`，包含阶段、VBUS 电压、输入限流、输入电压调节、芯片温度调节及锁存 IRQ。
- `power_sample` 每 30 秒输出，即使电量、电压没有变化也保留趋势；BLE 发布仍沿用变化检测。日志只走现有输出通道，不写 Flash。

首轮诊断版不改充电电流。用户随后确认电池为额定 1000 mAh、3.7 Wh、标称 3.7 V、充电限制 4.2 V，并明确要求 500 mA 上限。将 `0x62[4:0]` 设为 `0x0b`；先核对现有目标电压为 4.2 V，否则明确失败并拒绝调整电流；恒流寄存器写入后读回校验，保留高位。

充电目标电压、终止电流、芯片过温保护、安全定时器和 BLE 契约保持不变；不清除 IRQ，不重置电量计。500 mA 为用户指定值；电池标签没有注明最大允许充电电流，0.5C 的换算不替代电池制造商的完整充电规范。

## 日志解释

| 字段 | 含义 |
| --- | --- |
| `phase=before/after` | 初始化前后配置，核对 TS 变化及其余充电参数保持不变 |
| `input_limit_ma / cc_limit_ma` | 配置上限，**不是实测电流**；`-1` 表示本实现不解码的编码，需结合原始寄存器确认 |
| `target_mv` | 配置的截止电压，`-1` 表示保留编码 |
| `stage` | `trickle / precharge / cc / cv / done / stopped`；未定义值明确显示 `reserved` |
| `vbus_mv` | 14 位 ADC 电压，`-1` 表示无效采样；需结合 `vbus_good`，不能单靠残留 ADC 值判断插电 |
| `vindpm / current_limited / thermal_regulation` | 当前输入电压调节、限流及芯片温度调节状态 |
| `irq_latched` | `0x48/0x49/0x4a` 锁存值，可能包含历史事件，不代表故障持续发生 |
| `charge_timeout_latched` | `0x4a[1]` 充电超时锁存位，不能当作当前是否仍在充电的判断 |

## 本地验证

`zsh firmware/test/host/run-tests.zsh test_power_telemetry` 在修复前于 TS 功能位断言失败，修复后通过。该测试验证初始化遗漏，不模拟三天的物理充电过程。

测试直接编译实际 `power_telemetry.c`，仅替代 I2C 和日志边界，覆盖 TS/ADC 配置、写入读回不一致、读写失败、88% / 4037 mV 采样、所有阶段、限流/温度/超时状态、缺电池、无效 ADC、电量非法值和保留编码。25 -> 500 mA 回归断言先在旧实现失败，修改后通过；同时检查非 4.2 V 配置不得调整电流、充电电流寄存器高位保留及其他保护寄存器不被写入。

定向测试及 `IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 zsh firmware/test/host/run-tests.zsh all` 均通过（17 个目标，C17 严格警告、ASan、UBSan）。`git diff --check` 通过。

首次 ESP-IDF 5.5.4 构建通过，但该产物烧录后启动失败，已由恢复正确配置后的产物替代。初次构建被沙箱对进程信息读取的限制阻断，获准在沙箱外运行后完成；未更换或升级依赖。构建提示组件仓库不可达，使用现有依赖。

### 烧录后的构建配置纠正

初次烧录于创建 `micro_ui` 任务时出现 `ESP_ERR_NO_MEM`，位于 `app_main.c:876`，持续 panic 重启。虽然省电选项已开启，但重配置时项目 defaults 将缓存从 16/32 KiB 改为 32/64 KiB、LVGL 绘制线程从 1 改为 2，并开启了 LVGL IRAM/style cache 等选项。仅检查省电选项不足以验证可运行配置。

恢复方式：从保留的 `firmware/sdkconfig` 复制到 `/tmp/esp32-charging-sdkconfig-20260907`，仅启用 `CONFIG_PM_ENABLE`、`CONFIG_PM_SLP_IRAM_OPT`、`CONFIG_PM_RTOS_IDLE_OPT`、`CONFIG_FREERTOS_USE_TICKLESS_IDLE`，并使用空的 `/tmp/esp32-charging-empty-20260907.defaults` 避免 defaults 再覆盖已有配置。仓库根配置及依赖未修改。

```sh
idf.py -D SDKCONFIG=/tmp/esp32-charging-sdkconfig-20260907 \
    -D SDKCONFIG_DEFAULTS=/tmp/esp32-charging-empty-20260907.defaults build
```

恢复配置后的诊断版构建成功，大小 `0x1f7080` 字节，应用分区剩余 75%，SHA-256 为 `29965a3379b848c6f3fcdf80255eecac034bc91e8314bdaef18daa21e32fd0e1`。这是早先 25 mA 诊断版的哈希，后续充电电流调整的构建会更新 `firmware/build/codex_remote.bin`。

生成配置确认：省电、tickless 均开启，指令/数据缓存恢复为 `0x4000/0x8000`，LVGL 绘制线程数为 1、刷新周期 33 ms。以上临时配置文件是本次构建输入，后续重建需保存或按上述方式重建；不要直接用项目 defaults 重新生成全部配置。

## 25 mA 诊断版的真机结果

用户明确授权后，最终固件已通过 `/dev/cu.usbmodem1101` 烧录到 ESP32-S3 QFN56 rev v0.2。bootloader、app、partition table 均返回 `Hash of data verified`，工具退出码 0。最终启动日志 ELF SHA 前缀 `1b07bbf34`，音频初始化可用内部堆 `102735` 字节，设备报告 ready、Mac host connected、HID 与 companion channels ready。

实测初始化前后：`input_limit_ma=1500 cc_limit_ma=25 target_mv=4200 ts=0x10 cc=0x01 termination=0x11 timer=0xe6`。采样为 `stage=cc vbus_mv≈5165–5169 vbus_good=1 vindpm=0 current_limited=0 thermal_regulation=0`，电量 90%、电池电压约 4056 mV。

**慢充的关键配置已查明：恒流上限仅 25 mA。** TS 在首次修正前已是 `0x10`，所以本次 TS 修正并非这台设备当前慢充的解释。日志有 `charge_timeout_latched=1`，只说明有历史超时事件，当前仍在充电。1000 mAh / 25 mA = 40 小时；1000 mAh / 100 mA = 10 小时，两者只是理想恒流估算，未考虑实际起始电量、充电末期降流、定时器和损耗，不是充满时间承诺。

最终采集日志：`/tmp/esp32-charging-20260907-verified.log`；初次失败采集保留在 `/tmp/esp32-charging-20260907-postflash.log`。接入串口时的 `reset_reason=11` 是 USB 外设复位，不能当作此前三天的重启证据。

连续采集从 10:37:25 启动到最后一条 10:40:27，运行时间达到 `182360 ms`。此窗口只有首次 USB 启动记录，无后续 panic、OOM 或重启；电池读数为 90%，电压从 4056 mV 到 4058 mV，变化很小，不能据此声称充电速度改善。

观察到 `mode=0 -> 1 -> 2 -> 0`，没有采到 `mode=3` 或 `audio power=off`。回到亮屏可能来自交互/PTT，也可能来自 Agent 状态触发的短暂唤醒；当前筛选日志不能区分。短暂 urgent 唤醒不会重置交互时间，不能仅根据回到 mode=0 认定待机计时已重置。

随后串口读取报 `Device not configured`，再次枚举已无 `/dev/cu.usbmodem*`，采集被硬件连接中断。未判定为设备崩溃，也未完成五分钟待机验收。需设备重新连接后继续验证。启动时 BLE 栈提示蓝牙启用期间无法应用 light sleep，不能仅凭 `CONFIG_PM_ENABLE` 宣称 CPU 已进入轻睡眠。仍需长时间物理充电验证才能声称速度改善或恢复充满。
