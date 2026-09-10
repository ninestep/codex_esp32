#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define CR_POWER_LOG_PATH "."
#define CR_POWER_LOG_FILE_LIMIT 1024
#include "../../main/power_log.c"

#include <assert.h>
#include <stdarg.h>
#include <stdlib.h>

void test_esp_log(const char *tag, const char *format, ...)
{
    (void)tag;
    (void)format;
}

static size_t file_size(const char *path)
{
    struct stat info;
    assert(stat(path, &info) == 0);
    return (size_t)info.st_size;
}

int main(void)
{
    char directory[] = "/tmp/cr-power-log.XXXXXX";
    assert(mkdtemp(directory) != NULL);
    assert(chdir(directory) == 0);
    ready = true;
    boot_id = 1;
    reset_reason = 3;
    cr_power_telemetry_t sample = {
        .battery_present = true, .battery_percent = 80, .battery_voltage_mv = 3900,
        .vbus_voltage_mv = -1, .pmu_status = {8, 5},
    };
    cr_power_log_record(0, 3, &sample, ESP_OK);
    assert(pending_size == 0); // 首次采样即保存。
    size_t first = file_size(ACTIVE_FILE);
    for (uint64_t t = 30000; t < 300000; t += 30000) {
        --sample.battery_percent;
        cr_power_log_record(t, 3, &sample, ESP_OK);
    }
    assert(pending_size > 0 && file_size(ACTIVE_FILE) == first);
    cr_power_log_record(300000, 3, &sample, ESP_OK);
    assert(pending_size == 0 && file_size(ACTIVE_FILE) > first);
    sample.charging = true;
    sample.pmu_status[1] = 3;
    cr_power_log_record(330000, 3, &sample, ESP_OK);
    assert(pending_size == 0); // 充电状态变化立即保存。
    sample.battery_percent = 5;
    cr_power_log_record(360000, 3, &sample, ESP_OK);
    assert(pending_size == 0);
    cr_power_log_record(390000, 3, NULL, ESP_FAIL);
    assert(pending_size == 0);
    // 模拟进程重启：丢弃 RAM 缓冲，已保存记录保持不变。
    sample.battery_percent = 70;
    cr_power_log_record(420000, 3, &sample, ESP_OK);
    size_t saved = file_size(ACTIVE_FILE);
    pending_size = 0;
    have_previous = false;
    last_flush_ms = 0;
    boot_id = 2;
    cr_power_log_record(0, 3, &sample, ESP_OK);
    assert(file_size(ACTIVE_FILE) > saved);
    for (uint64_t t = 300000; t < 30000000; t += 300000) {
        cr_power_log_record(t, 3, &sample, ESP_OK);
        assert(ready && pending_size == 0);
        assert(file_size(ACTIVE_FILE) <= CR_POWER_LOG_FILE_LIMIT);
    }
    assert(file_size(PREVIOUS_FILE) <= CR_POWER_LOG_FILE_LIMIT);
    // 使用真实文件和管道验证串口命令触发导出。
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    console_fd = descriptors[0];
    assert(fcntl(console_fd, F_SETFL, O_NONBLOCK) == 0);
    assert(freopen("export.txt", "w+", stdout) != NULL);
    assert(write(descriptors[1], "powerlog dump\n", 14) == 14);
    cr_power_log_poll_export();
    assert(fflush(stdout) == 0);
    rewind(stdout);
    char line[256];
    assert(fgets(line, sizeof(line), stdout) != NULL);
    assert(strcmp(line, "POWERLOG_BEGIN v=1\n") == 0);
    bool ended = false;
    while (fgets(line, sizeof(line), stdout) != NULL) {
        if (strncmp(line, "POWERLOG_END rows=", 18) == 0) ended = true;
    }
    assert(ended);
    assert(close(descriptors[0]) == 0 && close(descriptors[1]) == 0);
    console_fd = -1;
    // 写入失败显式停用记录，不能伪报成功。
    assert(unlink(ACTIVE_FILE) == 0);
    assert(mkdir(ACTIVE_FILE, 0700) == 0);
    sample.battery_percent = 1;
    cr_power_log_record(40000000, 3, &sample, ESP_OK);
    assert(!ready && pending_size > 0);
    assert(rmdir(ACTIVE_FILE) == 0);
    assert(unlink(PREVIOUS_FILE) == 0);
    assert(unlink("export.txt") == 0);
    assert(chdir("/") == 0 && rmdir(directory) == 0);
    return 0;
}
