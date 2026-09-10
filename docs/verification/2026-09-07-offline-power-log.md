# 离线充放电日志

## 状态与使用

已按用户授权清理已备份的 `screensaver` 分区并烧录最终修复版，**离线记录已启用，真机 CSV 导出与跨重启记录保留已验证**。

- 仅擦除 `0x810000` 起的 `0x700000` 字节，命令返回成功，耗时 8.7 秒。固件、NVS 及配对配置不在擦除范围。
- 最终固件 SHA-256：`8e1c30838a998d7825c4c40ce366b51eb22312ef9f34ed6d9638ddfb8f409e52`，大小 `0x1fe1a0`；构建及三段烧录哈希校验通过。
- 设备报告 `offline logging ready`。首次成功导出 5 条记录，含 4 个启动标识；校验结束标记为 `POWERLOG_END rows=5 fnv1a=ca910577`，证明前几个启动的已写入记录在重新烧录应用及重启后仍存在。
- 串口接入在此设备上会触发 `reset_reason=11`。导出工具延后 10 秒发送命令，随后最多等待一个 30 秒采样周期；刚重启前尚未批量保存的 RAM 数据可能丢失，已落盘数据保留。
- 首次空白分区检查曾阻塞超过看门狗周期，最终版每检查 64 KiB 让出 CPU。最终版使用已有周期直接读取 USB RX FIFO，避免 IDF 非阻塞 VFS 无接收驱动时读不到命令，以及完整 USB 驱动引入 IRAM 占用导致任务创建失败。
- 最终构建、烧录及首次校验导出日志：`/tmp/esp32-powerlog-final-build.log`、`/tmp/esp32-powerlog-final-flash.log`、`/tmp/powerlog-verified-20260907.raw.log`。
- 第二次重连导出 7 条记录、5 个启动标识；程序逐条核对前一次的 5 条记录全部保留。当前启动采样达到 34903 ms，未见 panic/OOM/WDT，电量 100%、4197 mV、CV。结果保存为 [CSV](2026-09-07-offline-power-log.csv)，原始串口日志 `/tmp/powerlog-reconnected-20260907.raw.log`。

## 中间版本排障记录（已被最终版替代）

- 初版烧录三段哈希验证成功，但真机在创建 `detail_timeout` 任务时出现内部 RAM 不足并重启。将 2 KiB 日志缓冲改为启动后从 PSRAM 分配，存储初始化延后到主任务释放启动栈之后，避免挤占业务任务的内部 RAM。
- 第一轮内存修复版重新构建并烧录，三段均 `Hash of data verified`，退出码 0。该中间固件 SHA-256：`6c0e37a1559d005d3d55bde3cdc9759c4ecad8ae28d6634c5d3770f98eeb5fb3`。
- 修复后约 45 秒串口观察中设备报告 `Codex Remote ready`，采样运行时间达到 33233 ms，无后续 panic/OOM 重启；电池 100%、4197–4198 mV，仍为 CV。日志 `/tmp/esp32-powerlog-recovery-runtime.log`。
- 预留分区范围 `0x810000–0xf0ffff`（7 MiB），其中 4205522 字节不是擦除态，无法识别为当前 SPIFFS；尚不能确定旧数据用途。完整只读备份 `/tmp/esp32-screensaver-before-powerlog-20260907.bin`，大小 7340032 字节，SHA-256：`c86caf5d3b06f80286008b872753adb5927254d74eed57eadf1301f1589fdfb6`。
- 用户确认清理前没有擦除旧分区，当时启动有 `offline power logging unavailable: ESP_ERR_INVALID_STATE`。首次导出超时，其原始日志保存在 `/tmp/powerlog-first-flash-20260907.raw.log`。
- 定向 C 测试在内存修复后通过；修复构建及烧录日志分别为 `/tmp/esp32-powerlog-recovery-build.log`、`/tmp/esp32-powerlog-recovery-flash.log`。

烧录后，设备自动在 Flash 保存电量采样，不依赖串口或 Mac App。拔掉 USB 即可进行耗电测试，测试结束后接回 USB，退出占用串口的 monitor，再导出：

```sh
/Users/wj/.espressif/python_env/idf5.5_py3.13_env/bin/python \
    firmware/export-power-log.py /tmp/power-test-20260907.csv
```

只有一个 `/dev/cu.usbmodem*` 时自动选择，否则使用 `--port` 明确指定。命令等待下次采样周期处理，最多约 30 秒开始；大日志传输需要更长时间，默认总超时 600 秒。导出过程会占用电量任务，应在耗电测试结束后进行。脚本使用 ESP-IDF 已有的 pyserial，不安装依赖，不覆盖已有输出文件。

输出 CSV 必须通过设备发送的行数和 FNV-1a 校验；原始串口内容另存为同名 `.raw.log`。传输中断、坏行或设备存储错误不会伪报导出成功，原始内容保留供排查。脚本不主动复位设备；USB 重新连接本身可能导致重启，已写入 Flash 的记录不依赖 RAM。

## 记录与保存策略

- 沿用现有 30 秒采样任务，每条记录含启动标识、启动后毫秒数、复位原因、运行模式、采样错误码、电池是否存在、电量、电池电压、充电方向、VBUS 电压、充电阶段、PMU 原始状态和锁存 IRQ。
- PMU 读取失败也保存一行，测量字段为 `-1`、阶段为 `255`，避免将缺失读数当成真实 0%。没有实测电池电流，不能从 CSV 直接积分出耗电量或充入容量。
- 时间采用 `boot_id + uptime_ms`；随机启动标识区分重启前后。没有新增时钟同步，无法还原设备关机期间的时长，也不能把不同启动的 uptime 直接连成绝对时间曲线。
- RAM 批量缓冲通常每 5 分钟落盘。首条记录、电源/电池连接及充电阶段变化、采样错误和电量 ≤5% 时提前落盘；导出前也保存缓冲。电量变化仍每 30 秒保留，批量保存不会只留下 5 分钟一个点。
- 正常批量策略中，突然掉电可能丢失末尾约 5 分钟尚未写入的记录；低电量时缩短到采样周期量级。这不是文件系统断电安全保证：Flash 写入中断仍可能造成文件损坏，须真机验证。遇到损坏不自动格式化，导出保留原始串口证据。
- 使用既有 `screensaver` SPIFFS 分区，不改分区表、不占用配对配置 NVS、不新增 BLE 协议。只在确认整个分区全为 `0xff` 后初始化空白文件系统，首次初始化可能较慢；非空且无法挂载时明确报错，保护已有内容。
- 循环使用 `power-current.csv` 和 `power-previous.csv` 两个文件，每个上限 1 MiB。写满后淘汰最旧文件，只轮换本功能的两个文件；保存跨度取决于每行长度及实际采样频率，通常为数天，不承诺固定天数。
- 写入错误会停止记录并输出 `persistent logging stopped`；导出返回 `POWERLOG_ERROR`，不得把这类测试判为数据完整。常规烧录应用不会主动清除日志；全片擦除或重新烧录该数据分区会丢失记录。

## 验证与边界

- C 主机测试使用真实临时文件，验证周期批量保存、充电状态和低电量提前保存、RAM 状态重建后继续追加、双文件轮换、命令触发导出以及文件写入失败。
- PMU 定向测试核对传递到日志的 VBUS、电池电压、原始状态与 IRQ；原充电参数及保护配置不变。
- Python 导出测试覆盖完整传输、夹杂运行日志、丢行、数值损坏、缺少结束标记、存储报错和不完整 CSV 行。
- 所有 18 个 C 主机测试目标通过，启用严格警告、ASan、UBSan。导出 Python 测试通过。
- 初版 ESP-IDF 5.5.4 构建通过，固件大小 `0x1fe1c0` 字节，应用分区剩余 75%；该初版 SHA-256 为 `4e1b728048e5e4ed63e2d51bcb33ac3249549021b7b53046f2326bb36055e63e`。最终交付版本以本文顶部 SHA-256 为准，`git diff --check` 通过。
- 沿用已验证的 `/tmp/esp32-charging-sdkconfig-20260907` 和空 defaults 构建，避免项目 defaults 改变缓存/LVGL 内存配置。电量任务栈从 3072 增至 4096 字节以容纳文件系统调用；无新增周期任务。
- 已验证正常挂载、短时运行、跨 USB 复位保留和小规模 CSV 导出。长时间拔线耗电、每 5 分钟自动落盘的连续真机观测、写入途中突然断电恢复、大日志导出及实际耗电增量尚未验证。

验证命令：

```sh
IDF_PATH=/Users/wj/esp/esp-idf-v5.5.4 zsh firmware/test/host/run-tests.zsh all
python3 firmware/test/host/test_power_log_export.py
```
