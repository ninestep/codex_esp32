# ESP-IDF Firmware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 ESP32-S3-Touch-AMOLED-2.16 建立可编译的 ESP-IDF 固件，实现 BLE v1 跨端协议、会话 UI、实体键/PTT、音频、屏保和图片资源状态机，并明确区分主机模拟证据与真机证据。

**Architecture:** `firmware/components/codex_remote_core` 保持 ESP-IDF/LVGL/NimBLE 无关，承载确定性 codec 和设备状态机，可由 macOS 的 clang 主机测试直接编译。`codex_remote_ble`、`codex_remote_ui`、`codex_remote_audio` 和 `codex_remote_platform` 分别适配 NimBLE、LVGL、Waveshare 音频与板级 BSP；`main` 只负责装配。固件依赖官方 managed component `waveshare/esp32_s3_touch_amoled_2_16 ^2.0.1`、LVGL 9 和 ESP-IDF v5.5.4，第三阶段不烧录设备，也不声称真机通过。

**Tech Stack:** ESP-IDF v5.5.4、C17、ESP-IDF NimBLE、LVGL 9、Waveshare managed BSP、Unity/主机 clang 测试、Swift BLE v1 golden fixtures。

---

## 范围与门禁

- 官方板卡资料要求 ESP-IDF v5.5 或更高；本计划固定 v5.5.4，与官方仓库当前 CI 支持版本一致。
- BSP 基线固定到官方仓库提交 `713f8bdcc0fc2356ac22335ed4f381096e45ceea` 所示的 managed component `waveshare/esp32_s3_touch_amoled_2_16 ^2.0.1`。
- 可以新增仓库内 `idf_component.yml`、`sdkconfig.defaults` 和 `partitions.csv`，但安装 ESP-IDF、下载 managed components、修改用户 shell/IDE 配置仍需单独明确确认。
- 无实物，本阶段只做主机测试、跨端 golden fixtures、ESP-IDF 完整构建和静态边界检查；BLE 射频、加密配对、显示、触摸、麦克风、GPIO、PMU、功耗均不得标记为真机通过。
- 不实现 OTA、Wi-Fi、Classic Bluetooth、microSD 浏览器、PNG/GIF、生产签名或恢复出厂设置 UI。
- 不修改第二阶段 BLE v1 shared contract；如果 C 端 fixture 证明 contract 有矛盾，停止并先报告 shared contract 变更需求。

## 文件结构

```text
firmware/
├── CMakeLists.txt
├── partitions.csv
├── sdkconfig.defaults
├── main/
│   ├── CMakeLists.txt
│   ├── idf_component.yml
│   └── app_main.c
├── components/
│   ├── codex_remote_core/
│   │   ├── CMakeLists.txt
│   │   ├── include/codex_remote/{protocol.h,codec.h,crc32.h,device_state.h,input_state.h,power_state.h,asset_state.h,audio_frame.h}
│   │   └── src/{codec.c,crc32.c,device_state.c,input_state.c,power_state.c,asset_state.c,audio_frame.c}
│   ├── codex_remote_ble/
│   │   ├── CMakeLists.txt
│   │   ├── include/codex_remote/ble_transport.h
│   │   └── src/ble_transport.c
│   ├── codex_remote_ui/
│   │   ├── CMakeLists.txt
│   │   ├── include/codex_remote/ui.h
│   │   └── src/ui.c
│   ├── codex_remote_audio/
│   │   ├── CMakeLists.txt
│   │   ├── include/codex_remote/audio_capture.h
│   │   └── src/audio_capture.c
│   └── codex_remote_platform/
│       ├── CMakeLists.txt
│       ├── include/codex_remote/platform.h
│       └── src/platform_waveshare.c
├── test/host/
│   ├── run-tests.zsh
│   ├── test_codec.c
│   ├── test_device_state.c
│   ├── test_input_state.c
│   ├── test_power_state.c
│   ├── test_asset_state.c
│   └── test_audio_frame.c
└── Docs/phase-3-verification.md
```

每个 production 文件只承担一个职责。`codex_remote_core` 禁止包含 `esp_*`、FreeRTOS、NimBLE、LVGL 或 Waveshare BSP header；主机测试直接复用它，避免另写一套协议实现。

### Task 1: 建立主机可测的 C 核心与 BLE envelope codec

**Files:**
- Create: `firmware/components/codex_remote_core/CMakeLists.txt`
- Create: `firmware/components/codex_remote_core/include/codex_remote/protocol.h`
- Create: `firmware/components/codex_remote_core/include/codex_remote/codec.h`
- Create: `firmware/components/codex_remote_core/include/codex_remote/crc32.h`
- Create: `firmware/components/codex_remote_core/src/codec.c`
- Create: `firmware/components/codex_remote_core/src/crc32.c`
- Create: `firmware/test/host/test_codec.c`
- Create: `firmware/test/host/run-tests.zsh`

- [x] **Step 1: 写 envelope 与 golden fixture 失败测试**

`test_codec.c` 必须读取 `macos/Fixtures/ble-v1` 中的 `empty-action-result.hex`、`select-session.hex`、`terminal-enter.hex`、`bad-crc.hex` 和 `incompatible-major.hex`，断言 magic `CR`、版本 `1.0`、little-endian sequence/payload length、message type、CRC32/IEEE 和显式错误码；再将前三个有效 envelope 解码后逐字节重编码。

- [x] **Step 2: 运行测试并确认 RED**

Run: `zsh firmware/test/host/run-tests.zsh test_codec`

Expected: 编译失败，原因是 `codex_remote/codec.h` 尚不存在，而不是脚本路径或 clang 配置错误。

- [x] **Step 3: 定义固定 wire 类型与错误边界**

`protocol.h` 定义 `CR_PROTOCOL_MAJOR 1`、`CR_PROTOCOL_MINOR 0`、18 字节固定 envelope 开销、256 KiB 上限、14 个 message type 数值以及 `cr_result_t`。公开类型只使用 `<stdint.h>`、`<stddef.h>`、`<stdbool.h>`。

- [x] **Step 4: 实现 CRC32 与 bounded envelope codec**

`cr_crc32_ieee` 使用 reflected polynomial `0xEDB88320`、初始值和 final XOR 均为 `0xFFFFFFFF`。`cr_envelope_decode` 在返回 payload view 前验证 magic、major、minor/flags、message type、长度、CRC 和尾随字节；`cr_envelope_encode` 先计算所需长度，目标缓冲不足时不写入部分结果。

- [x] **Step 5: 运行定向测试并确认 GREEN**

Run: `zsh firmware/test/host/run-tests.zsh test_codec`

Expected: `test_codec: PASS`，并且 AddressSanitizer/UndefinedBehaviorSanitizer 无报告。

### Task 2: 实现全部 BLE v1 payload codec 与跨端 golden fixtures

**Files:**
- Modify: `firmware/components/codex_remote_core/include/codex_remote/protocol.h`
- Modify: `firmware/components/codex_remote_core/include/codex_remote/codec.h`
- Modify: `firmware/components/codex_remote_core/src/codec.c`
- Modify: `firmware/test/host/test_codec.c`
- Create: `firmware/test/host/verify-golden-fixtures.zsh`

- [x] **Step 1: 增加失败测试覆盖 13 个 fixture**

测试有效向量的字段值、四/八会话 snapshot、state delta、ADPCM frame、asset manifest/chunk、device info 和两分片消息；错误向量必须分别返回 CRC 与 incompatible-version。字符串必须按 UTF-8 字节长度检查，会话数超过八、无效枚举、尾随 payload 和整数越界必须失败。

- [x] **Step 2: 验证 RED**

Run: `zsh firmware/test/host/run-tests.zsh test_codec`

Expected: 首个尚未实现的 payload case 返回 `CR_ERR_UNSUPPORTED_MESSAGE` 或字段断言失败。

- [x] **Step 3: 实现确定性 reader/writer 与 14 类消息**

使用显式 cursor 结构读写 `u8/u16/u32/i16/u64/UTF-8 bytes`，所有整数 little-endian。公开 API 采用 caller-owned buffers，不动态分配；snapshot 固定最多八项，title/detail 上限分别为 64/192 字节。

- [x] **Step 4: 实现 8 字节 ATT fragment header**

fragment header 固定为 `message_id u32`、`fragment_index u16`、`fragment_count u16`；重组器上限 1,024 片和 256 KiB，每 channel 只允许一个 active message，重复/乱序/跨 ID/总数变化都清除不可信状态并返回明确错误。

- [x] **Step 5: 验证 C 与 Swift fixtures 一致**

Run: `zsh firmware/test/host/verify-golden-fixtures.zsh`

Expected: 13 个声明 fixture 全部由 C 端解码；可重编码向量逐字节一致；脚本退出 0 且不改写仓库。

### Task 3: 实现设备会话、控制去重和连接状态机

**Files:**
- Create: `firmware/components/codex_remote_core/include/codex_remote/device_state.h`
- Create: `firmware/components/codex_remote_core/src/device_state.c`
- Create: `firmware/test/host/test_device_state.c`

- [x] **Step 1: 写 snapshot/delta/select/control 失败测试**

覆盖：连接后 snapshot 前拒绝 delta；generation 与 sequence 严格递增；最多八会话；选择成功后才允许 scroll/key/PTT；未知 session 返回 unavailable；Enter/Esc request ID exactly-once；scroll sequence 去重；断线清除 keys、selection、sequence、request cache 和 PTT，但保留 active asset set。

- [x] **Step 2: 验证 RED**

Run: `zsh firmware/test/host/run-tests.zsh test_device_state`

Expected: 编译失败，因为 `device_state.h` 不存在。

- [x] **Step 3: 实现固定容量状态机**

状态结构只使用固定数组和 caller-provided callbacks。`cr_device_apply_message` 返回需要上行的 action result/resync 事件，不直接调用 BLE；request cache 保存有限数量已完成副作用请求，并在连接 reset 清空。

- [x] **Step 4: 验证 GREEN**

Run: `zsh firmware/test/host/run-tests.zsh test_device_state`

Expected: `test_device_state: PASS`。

### Task 4: 实现 GPIO18 短按、双击、长按 PTT 状态机

**Files:**
- Create: `firmware/components/codex_remote_core/include/codex_remote/input_state.h`
- Create: `firmware/components/codex_remote_core/src/input_state.c`
- Create: `firmware/test/host/test_input_state.c`

- [x] **Step 1: 写确定性时序失败测试**

使用单调毫秒时间覆盖：20 ms 去抖；按住不足 350 ms 后进入 250 ms 单击窗口并发 Enter；窗口内第二次完整点击发 Esc；达到 350 ms 只发一次 PTT_BEGIN；松手发 PTT_END；首页、无 selection、PTT 中、息屏首次唤醒均不误发 Enter/Esc/PTT；临界值 349/350/351 ms 有明确结果。

- [x] **Step 2: 验证 RED**

Run: `zsh firmware/test/host/run-tests.zsh test_input_state`

Expected: 编译失败，因为 `input_state.h` 不存在。

- [x] **Step 3: 实现无硬件依赖输入 reducer**

输入为页面、selection、屏幕状态、GPIO edge 和 timestamp，输出为零或一个 `CR_INPUT_ACTION_*`。按下时输出 `PRE_ROLL_BEGIN`，点击判定时输出 `PRE_ROLL_DISCARD`，长按阈值时输出 `PTT_BEGIN`；唤醒消费整个 press/release cycle。

- [x] **Step 4: 验证 GREEN**

Run: `zsh firmware/test/host/run-tests.zsh test_input_state`

Expected: `test_input_state: PASS`。

### Task 5: 实现音频帧、图片资源与省电/屏保核心状态

**Files:**
- Create: `firmware/components/codex_remote_core/include/codex_remote/audio_frame.h`
- Create: `firmware/components/codex_remote_core/src/audio_frame.c`
- Create: `firmware/components/codex_remote_core/include/codex_remote/asset_state.h`
- Create: `firmware/components/codex_remote_core/src/asset_state.c`
- Create: `firmware/components/codex_remote_core/include/codex_remote/power_state.h`
- Create: `firmware/components/codex_remote_core/src/power_state.c`
- Create: `firmware/test/host/test_audio_frame.c`
- Create: `firmware/test/host/test_asset_state.c`
- Create: `firmware/test/host/test_power_state.c`

- [x] **Step 1: 写三个独立失败测试**

音频覆盖双声道 16 kHz PCM 平均成单声道、320 samples/20 ms IMA-ADPCM、每帧独立 predictor/index 和丢帧恢复；图片覆盖 manifest/chunk/CRC、重复一致 chunk 幂等、冲突/缺口失败、整组原子激活和中断保留旧集；省电覆盖 60 s 低亮、120 s 屏保、300 s 息屏、30 s 轮播、琥珀/红事件点亮 8 s、PTT 禁止省电。

- [x] **Step 2: 逐项验证 RED**

Run: `zsh firmware/test/host/run-tests.zsh test_audio_frame test_asset_state test_power_state`

Expected: 三个目标均因对应 header 不存在而编译失败。

- [x] **Step 3: 实现最小固定容量核心**

音频编码结果必须与 `adpcm-silence.hex` payload 相容；图片 pending/active metadata 分离，数据写入通过 storage callback，core 不直接依赖 NVS/partition API；power reducer 只输出 `NORMAL/DIM/SCREENSAVER/OFF` 与当前 asset index，不直接控制背光。

- [x] **Step 4: 验证 GREEN 与 sanitizers**

Run: `zsh firmware/test/host/run-tests.zsh test_audio_frame test_asset_state test_power_state`

Expected: 全部 PASS，无 sanitizer 报告。

### Task 6: 建立 ESP-IDF 工程、官方 BSP 和平台 adapters

**Files:**
- Create: `firmware/CMakeLists.txt`
- Create: `firmware/sdkconfig.defaults`
- Create: `firmware/partitions.csv`
- Create: `firmware/main/CMakeLists.txt`
- Create: `firmware/main/idf_component.yml`
- Create: `firmware/main/app_main.c`
- Create: `firmware/components/codex_remote_platform/CMakeLists.txt`
- Create: `firmware/components/codex_remote_platform/include/codex_remote/platform.h`
- Create: `firmware/components/codex_remote_platform/src/platform_waveshare.c`

- [ ] **Step 1: 写工程结构检查脚本并确认 RED**

脚本断言 target 为 `esp32s3`、flash 为 16 MiB QIO、Octal 8 MiB PSRAM、NimBLE only、LVGL FreeRTOS、480×480 BSP、factory app 8 MiB 和 screensaver data 7 MiB；缺任一配置失败。

- [x] **Step 2: 新增最小工程与受控依赖**

`idf_component.yml` 精确声明 `waveshare/esp32_s3_touch_amoled_2_16: ^2.0.1` 和 `lvgl/lvgl: 9.*`。`partitions.csv` 沿用官方 16 MiB 基线：NVS 0x6000、PHY 0x1000、factory 8 MiB、screensaver 7 MiB；报告中明确该容量只完成构建验证，未验证真实 JPEG 峰值内存。

- [ ] **Step 3: 装配 BSP 显示、触摸、GPIO18、PMU 与存储边界**

`platform_waveshare.c` 只负责 BSP 调用和事件转发；所有 LVGL 操作必须在 `bsp_display_lock/unlock` 内。硬件初始化失败明确记录并禁用相应 capability，不伪造成功。

- [ ] **Step 4: 运行结构检查**

Run: `zsh firmware/test/host/verify-project-structure.zsh`

Expected: `verify-project-structure: PASS`。

### Task 7: 实现 NimBLE GATT、LVGL UI 和音频 adapter

**Files:**
- Create: `firmware/components/codex_remote_ble/CMakeLists.txt`
- Create: `firmware/components/codex_remote_ble/include/codex_remote/ble_transport.h`
- Create: `firmware/components/codex_remote_ble/src/ble_transport.c`
- Create: `firmware/components/codex_remote_ui/CMakeLists.txt`
- Create: `firmware/components/codex_remote_ui/include/codex_remote/ui.h`
- Create: `firmware/components/codex_remote_ui/src/ui.c`
- Create: `firmware/components/codex_remote_audio/CMakeLists.txt`
- Create: `firmware/components/codex_remote_audio/include/codex_remote/audio_capture.h`
- Create: `firmware/components/codex_remote_audio/src/audio_capture.c`
- Modify: `firmware/main/app_main.c`

- [ ] **Step 1: 定义 adapter contract 编译测试**

用 ESP-IDF component requirements 验证 adapters 只能通过 `codex_remote_core` 公共 header 交互，禁止直接访问 core 内部结构。BLE characteristic 固定为 ControlToHost、ControlToDevice、StateToDevice、AudioToHost、AssetToDevice 和 DeviceInfo 六条方向明确的通道。

- [ ] **Step 2: 实现 NimBLE peripheral 与安全属性**

仅启用 BLE，要求 bonding/MITM/secure connections；控制、音频和图片 characteristic 要求加密连接。重连调用 core reset 并等待完整 snapshot；音频 notify 不重传，严格控制用 indication/write response。

- [ ] **Step 3: 实现 480×480 首页与详情页**

首页 2×2 卡片首屏显示 1–4，纵向滚动到 5–8；颜色同时配合圆点和状态文字。详情页含返回、标题、目录、摘要、滚动区、“取消 Esc”和“确定 Enter”；PTT 时锁定滚动、按键和会话切换；mapping 丢失退出详情。

- [ ] **Step 4: 实现屏保与 JPEG 激活 adapter**

状态屏保、自定义 JPEG 轮播和息屏均由 power reducer 驱动；只在 manifest 全部完成、长度和 CRC 通过后切换 active set。PTT 时暂停 asset 传输和 JPEG decode，结束后恢复。

- [x] **Step 5: 实现 ES7210/I2S 采集 adapter**

复用官方 16 kHz 双声道采样路径；按下即开始 RAM pre-roll，短按/双击丢弃，长按从 pre-roll 起编码独立 20 ms ADPCM frame。不得写 flash 或日志记录 PCM。

### Task 8: 完整构建、回归与中文验证报告

**Files:**
- Create: `firmware/Docs/phase-3-verification.md`
- Modify: `docs/superpowers/specs/2026-08-02-codex-remote-control-design.md` only if verified evidence disproves an assumption

- [x] **Step 1: 运行全部主机测试和跨端 fixtures**

Run:

```bash
zsh firmware/test/host/run-tests.zsh all
zsh firmware/test/host/verify-golden-fixtures.zsh
zsh macos/Tests/Scripts/ble-golden-fixtures.zsh
cd macos && swift test --parallel
```

Expected: 全部退出 0；C/Swift 两端读取相同 13 个 golden fixtures。

- [x] **Step 2: 使用 ESP-IDF v5.5.4 完整构建**

Run:

```bash
. "$IDF_PATH/export.sh"
cd firmware
idf.py set-target esp32s3
idf.py build
```

Expected: 生成 app ELF/BIN、bootloader.bin 和 partition-table.bin；不执行 flash/monitor。

- [x] **Step 3: 检查边界和产物**

Run:

```bash
rg -n '#include "(esp_|freertos|host/ble|nimble|lvgl|bsp/)' firmware/components/codex_remote_core
rg -n 'terminalTargetID|launcherInstanceID|providerSessionID|remoteSessionID' firmware
git diff --check
```

Expected: core 无平台 header；固件不含 Mac/Ghostty 私有 ID；无空白错误。

- [ ] **Step 4: 编写第三阶段中文验证报告**

报告必须记录：官方 BSP 来源与版本、ESP-IDF 版本、依赖锁定结果、13 个 fixture 跨端证据、主机测试数、ELF/BIN/分区表路径与大小、UI/按键/PTT/音频/屏保模拟范围，以及全部真机未验证项。不能用“编译通过”替代 BLE、触摸、音频或功耗真机验收。

- [ ] **Step 5: 停在第四阶段门禁**

呈交报告。本任务不授权烧录、修改系统级配置、提交或推送 Git；真机到手后需再次明确授权才能进入第四阶段。

## 完成标准

- C 端可独立解码/重编码 Swift 冻结的 BLE v1 golden fixtures，且 shared contract 无漂移。
- 固件 core 可在主机 clang + sanitizers 下测试，不依赖 ESP-IDF、LVGL 或 BSP。
- 会话、selection、ACK 去重、PTT、GPIO18、屏保、图片原子激活和断线清理均有确定性测试。
- ESP-IDF v5.5.4 对 esp32s3 的完整构建生成 ELF、BIN、bootloader 和 partition table。
- 验证报告清楚区分主机模拟、固件编译与真机未验证证据。
