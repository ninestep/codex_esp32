#include "power_log.h"
#include "esp_log.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef ESP_PLATFORM
#include "esp_partition.h"
#include "esp_random.h"
#include "esp_spiffs.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "hal/usb_serial_jtag_ll.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#endif

#ifndef CR_POWER_LOG_PATH
#define CR_POWER_LOG_PATH "/powerlog"
#endif
#ifndef CR_POWER_LOG_FILE_LIMIT
#define CR_POWER_LOG_FILE_LIMIT (1024 * 1024)
#endif
#define ACTIVE_FILE CR_POWER_LOG_PATH "/power-current.csv"
#define PREVIOUS_FILE CR_POWER_LOG_PATH "/power-previous.csv"
#define FLUSH_INTERVAL_MS UINT64_C(300000)

static const char *TAG = "power_log";
static const char *HEADER = "boot_id,uptime_ms,reset_reason,mode,read_error,battery_present,battery_percent,battery_mv,charging,vbus_mv,stage,status0,status1,irq0,irq1,irq2";
#define PENDING_CAPACITY 2048
#ifdef ESP_PLATFORM
static char *pending;
#else
static char pending[PENDING_CAPACITY];
#endif
static size_t pending_size;
static uint64_t boot_id;
static unsigned reset_reason;
static uint64_t last_flush_ms;
static bool ready;
static bool have_previous;
static bool previous_charging;
static uint8_t previous_stage;
static bool previous_vbus_good;
static bool previous_present;
#ifndef ESP_PLATFORM
static int console_fd = -1;
#endif

static bool flush_pending(void)
{
    if (pending_size == 0) return true;
    struct stat info;
    if (stat(ACTIVE_FILE, &info) == 0) {
        if ((size_t)info.st_size + pending_size + 1 > CR_POWER_LOG_FILE_LIMIT) {
            if (unlink(PREVIOUS_FILE) != 0 && errno != ENOENT) return false;
            if (rename(ACTIVE_FILE, PREVIOUS_FILE) != 0) return false;
        }
    } else if (errno != ENOENT) {
        return false;
    }
    FILE *file = fopen(ACTIVE_FILE, "ab");
    if (file == NULL) return false;
    // 批次前加换行，避免断电留下的半行与下次记录粘连。
    bool ok = fputc('\n', file) != EOF
        && fwrite(pending, 1, pending_size, file) == pending_size
        && fflush(file) == 0 && fsync(fileno(file)) == 0;
    if (fclose(file) != 0) ok = false;
    if (ok) pending_size = 0;
    return ok;
}

static void storage_failed(void)
{
    ready = false;
    ESP_LOGE(TAG, "persistent logging stopped; storage error errno=%d", errno);
}

void cr_power_log_record(uint64_t uptime_ms, unsigned mode,
                         const cr_power_telemetry_t *sample, esp_err_t result)
{
    if (!ready) return;
    bool valid = result == ESP_OK && sample != NULL;
    unsigned stage = valid ? sample->pmu_status[1] & 7 : 255;
    char row[192];
    int length = snprintf(row, sizeof(row),
        "%016" PRIx64 ",%" PRIu64 ",%u,%u,%d,%d,%d,%d,%d,%d,%u,%d,%d,%d,%d,%d\n",
        boot_id, uptime_ms, reset_reason, mode, result,
        valid ? sample->battery_present : -1,
        valid && sample->battery_present ? sample->battery_percent : -1,
        valid && sample->battery_present ? sample->battery_voltage_mv : -1,
        valid ? sample->charging : -1, valid ? sample->vbus_voltage_mv : -1, stage,
        valid ? sample->pmu_status[0] : -1, valid ? sample->pmu_status[1] : -1,
        valid ? sample->irq_latched[0] : -1, valid ? sample->irq_latched[1] : -1,
        valid ? sample->irq_latched[2] : -1);
    if (length < 0 || (size_t)length >= sizeof(row)) {
        storage_failed();
        return;
    }
    if (pending_size + (size_t)length > PENDING_CAPACITY && !flush_pending()) {
        storage_failed();
        return;
    }
    memcpy(pending + pending_size, row, (size_t)length);
    pending_size += (size_t)length;
    bool urgent = !have_previous || !valid
        || (valid && (sample->charging != previous_charging
                     || ((sample->pmu_status[0] & 0x20) != 0) != previous_vbus_good
                     || sample->battery_present != previous_present
                     || stage != previous_stage
                     || (sample->battery_present && sample->battery_percent <= 5)));
    if (urgent || uptime_ms - last_flush_ms >= FLUSH_INTERVAL_MS) {
        if (!flush_pending()) {
            storage_failed();
            return;
        }
        last_flush_ms = uptime_ms;
    }
    if (valid) {
        previous_charging = sample->charging;
        previous_stage = (uint8_t)stage;
        previous_vbus_good = (sample->pmu_status[0] & 0x20) != 0;
        previous_present = sample->battery_present;
    }
    have_previous = true;
}

static bool export_file(const char *path, uint32_t *checksum, unsigned *rows)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) return errno == ENOENT;
    char line[192];
    bool ok = true;
    while (fgets(line, sizeof(line), file) != NULL) {
        if (strcmp(line, "\n") == 0) continue;
        size_t length = strlen(line);
        if (length == 0 || line[length - 1] != '\n') { ok = false; break; }
        if (fputs(line, stdout) == EOF) { ok = false; break; }
        for (size_t i = 0; i < length; ++i) {
            *checksum = (*checksum ^ (uint8_t)line[i]) * UINT32_C(16777619);
        }
        ++*rows;
#ifdef ESP_PLATFORM
        if ((*rows & 31) == 0) vTaskDelay(1);
#endif
    }
    if (ferror(file)) ok = false;
    if (fclose(file) != 0) ok = false;
    return ok;
}

static void export_log(void)
{
    // 写入失败后拒绝导出成功标记，不把缺失数据包装成完整日志。
    if (!ready || !flush_pending()) {
        puts("POWERLOG_ERROR storage_unavailable");
        return;
    }
    puts("POWERLOG_BEGIN v=1");
    puts(HEADER);
    uint32_t checksum = UINT32_C(2166136261);
    unsigned rows = 0;
    bool ok = export_file(PREVIOUS_FILE, &checksum, &rows)
        && export_file(ACTIVE_FILE, &checksum, &rows);
    if (ok) printf("POWERLOG_END rows=%u fnv1a=%08" PRIx32 "\n", rows, checksum);
    else puts("POWERLOG_ERROR read_failed");
    fflush(stdout);
}

void cr_power_log_poll_export(void)
{
#ifndef ESP_PLATFORM
    if (console_fd < 0) return;
#endif
    static char command[32];
    static size_t used;
    static bool overflow;
    char bytes[64];
#ifdef ESP_PLATFORM
    // 仅有一个 RX 消费者，每 30 秒取最多一个 64 字节包；无需常驻中断驱动。
    ssize_t count = (ssize_t)usb_serial_jtag_ll_read_rxfifo((uint8_t *)bytes, sizeof(bytes));
#else
    ssize_t count = read(console_fd, bytes, sizeof(bytes));
#endif
    for (ssize_t i = 0; i < count; ++i) {
        if (bytes[i] == '\n' || bytes[i] == '\r') {
            command[used] = '\0';
            if (!overflow && strcmp(command, "powerlog dump") == 0) export_log();
            used = 0;
            overflow = false;
        } else if (used + 1 < sizeof(command)) {
            command[used++] = bytes[i];
        } else {
            overflow = true;
        }
    }
}

#ifdef ESP_PLATFORM
esp_err_t cr_power_log_init(void)
{
    esp_vfs_spiffs_conf_t config = {
        .base_path = CR_POWER_LOG_PATH, .partition_label = "screensaver",
        .max_files = 2, .format_if_mount_failed = false,
    };
    esp_err_t result = esp_vfs_spiffs_register(&config);
    if (result == ESP_FAIL) {
        const esp_partition_t *partition = esp_partition_find_first(
            ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, "screensaver");
        if (partition == NULL) return ESP_ERR_NOT_FOUND;
        uint8_t bytes[512];
        // 只初始化全空白分区；已有数据或损坏文件系统绝不自动格式化。
        for (size_t offset = 0; offset < partition->size; offset += sizeof(bytes)) {
            if ((offset & 0xffff) == 0) vTaskDelay(1);
            result = esp_partition_read(partition, offset, bytes, sizeof(bytes));
            if (result != ESP_OK) return result;
            for (size_t i = 0; i < sizeof(bytes); ++i) {
                if (bytes[i] != 0xff) return ESP_ERR_INVALID_STATE;
            }
        }
        config.format_if_mount_failed = true;
        result = esp_vfs_spiffs_register(&config);
    }
    if (result != ESP_OK) return result;
    pending = heap_caps_malloc(PENDING_CAPACITY, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (pending == NULL) return ESP_ERR_NO_MEM;
    esp_fill_random(&boot_id, sizeof(boot_id));
    reset_reason = (unsigned)esp_reset_reason();
    ready = true;
    ESP_LOGI(TAG, "offline logging ready: sample=30s flush=300s files=2x1MiB boot=%016" PRIx64, boot_id);
    return ESP_OK;
}
#endif
