#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

// 只替代 I2C 和日志边界，运行实际的 PMU 初始化及采样实现。
#include "../../main/power_telemetry.c"

static uint8_t registers[256];
static int failed_read = -1;
static int failed_write = -1;
static int ignored_write = -1;
static char log_output[16384];

void test_esp_log(const char *tag, const char *format, ...)
{
    (void)tag;
    size_t used = strlen(log_output);
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(log_output + used, sizeof(log_output) - used, format, arguments);
    va_end(arguments);
    assert(count >= 0 && (size_t)count < sizeof(log_output) - used - 1);
    strcat(log_output, "\n");
}

i2c_master_bus_handle_t bsp_i2c_get_handle(void)
{
    return registers;
}

esp_err_t i2c_master_bus_add_device(i2c_master_bus_handle_t bus,
    const i2c_device_config_t *config, i2c_master_dev_handle_t *device)
{
    assert(bus == registers && config->device_address == 0x34);
    *device = registers;
    return ESP_OK;
}

esp_err_t i2c_master_transmit_receive(i2c_master_dev_handle_t device,
    const uint8_t *address, size_t address_size, uint8_t *data, size_t size, int timeout_ms)
{
    assert(device == registers && address_size == 1 && timeout_ms > 0);
    assert((size_t)*address + size <= sizeof(registers));
    if (failed_read >= *address && failed_read < (int)(*address + size)) {
        return ESP_ERR_TIMEOUT;
    }
    memcpy(data, registers + *address, size);
    return ESP_OK;
}

esp_err_t i2c_master_transmit(i2c_master_dev_handle_t device,
    const uint8_t *data, size_t size, int timeout_ms)
{
    assert(device == registers && size == 2 && timeout_ms > 0);
    // 仅允许将恒流上限设为 500 mA；不改电压、过温保护、定时器或故障记录。
    assert(data[0] == 0x30 || data[0] == 0x50 || data[0] == 0x68 || data[0] == 0x62);
    if (data[0] == 0x62) assert((data[1] & 0x1f) == 11);
    if (data[0] == failed_write) return ESP_ERR_TIMEOUT;
    if (data[0] != ignored_write) registers[data[0]] = data[1];
    return ESP_OK;
}

static void reset_pmu(void)
{
    memset(registers, 0, sizeof(registers));
    registers[0x03] = 0x4a;
    registers[0x30] = 0xfa;
    registers[0x50] = 0x07;
    registers[0x68] = 0xa0;
    registers[0x16] = 1;
    registers[0x18] = 2;
    registers[0x61] = 2;
    registers[0x62] = 1;
    registers[0x63] = 0x11;
    registers[0x64] = 3;
    pmu_handle = NULL;
    failed_read = failed_write = ignored_write = -1;
    log_output[0] = '\0';
}

int main(void)
{
    reset_pmu();
    assert(cr_power_telemetry_init() == ESP_OK);
    assert((registers[0x50] & 0x1f) == 0x10);
    assert(registers[0x30] == 0xfd);
    assert(registers[0x68] == 0xa1);
    assert(strstr(log_output, "phase=before input_limit_ma=500 cc_limit_ma=25 target_mv=4200") != NULL);
    assert(registers[0x62] == 11);
    assert(strstr(log_output, "phase=after input_limit_ma=500 cc_limit_ma=500 target_mv=4200") != NULL);
    assert(strstr(log_output, "ts=0x07") != NULL);
    assert(strstr(log_output, "phase=after") != NULL);
    assert(strstr(log_output, "ts=0x10") != NULL);
    assert(cr_power_telemetry_init() == ESP_ERR_INVALID_STATE);

    // 复现用户的 88% / 4037 mV；充电方向与 CC/CV/完成阶段分别保留。
    registers[0x00] = 0x28;
    registers[0x01] = 0x23;
    registers[0x34] = 0xef; // 高位保留位不能污染电压。
    registers[0x35] = 0xc5;
    registers[0x38] = 0xd3;
    registers[0x39] = 0x88;
    registers[0xa4] = 88;
    cr_power_telemetry_t sample;
    assert(cr_power_telemetry_read(&sample) == ESP_OK);
    assert(sample.battery_present && sample.charging);
    assert(sample.battery_percent == 88 && sample.battery_voltage_mv == 4037);
    assert(sample.vbus_voltage_mv == 5000);
    assert(sample.pmu_status[0] == 0x28 && sample.pmu_status[1] == 0x23);
    assert(strstr(log_output, "stage=cv vbus_mv=5000 vbus_good=1 vindpm=0") != NULL);

    log_output[0] = '\0';
    registers[0x00] |= 3;
    registers[0x01] |= 8;
    registers[0x4a] = 2;
    assert(cr_power_telemetry_read(&sample) == ESP_OK);
    assert(strstr(log_output, "vindpm=1 current_limited=1 thermal_regulation=1") != NULL);
    assert(strstr(log_output, "charge_timeout_latched=1") != NULL);
    assert(registers[0x4a] == 2); // 诊断不得清除锁存故障。
    assert(sample.irq_latched[2] == 2);
    assert(cr_power_telemetry_read(&sample) == ESP_OK);
    const char *first_log = strstr(log_output, "charger_sample");
    assert(first_log != NULL && strstr(first_log + 1, "charger_sample") != NULL);

    const char *expected_stages[] = {"trickle", "precharge", "cc", "cv", "done", "stopped", "reserved", "reserved"};
    for (unsigned stage = 0; stage < 8; ++stage) {
        log_output[0] = '\0';
        registers[0x01] = (uint8_t)stage;
        assert(cr_power_telemetry_read(&sample) == ESP_OK);
        assert(!sample.charging && strstr(log_output, expected_stages[stage]) != NULL);
    }
    registers[0x00] = 0;
    registers[0x38] = 0x20;
    registers[0x39] = 0;
    assert(cr_power_telemetry_read(&sample) == ESP_OK);
    assert(!sample.battery_present && sample.battery_percent == 0);
    assert(sample.vbus_voltage_mv == -1);
    assert(strstr(log_output, "vbus_mv=-1") != NULL);
    assert(cr_power_telemetry_read(NULL) == ESP_ERR_INVALID_STATE);

    registers[0x00] = 8;
    registers[0xa4] = 101;
    sample.battery_percent = 42;
    assert(cr_power_telemetry_read(&sample) == ESP_ERR_INVALID_RESPONSE);
    assert(sample.battery_percent == 42);
    registers[0xa4] = 88;
    const int sample_reads[] = {0x00, 0x38, 0x48, 0x34, 0xa4};
    for (size_t index = 0; index < sizeof(sample_reads) / sizeof(sample_reads[0]); ++index) {
        failed_read = sample_reads[index];
        assert(cr_power_telemetry_read(&sample) == ESP_ERR_TIMEOUT);
        assert(sample.battery_percent == 42);
    }

    const int configured_registers[] = {0x50, 0x30, 0x68, 0x62};
    for (size_t index = 0; index < sizeof(configured_registers) / sizeof(configured_registers[0]); ++index) {
        reset_pmu();
        failed_write = configured_registers[index];
        assert(cr_power_telemetry_init() == ESP_ERR_TIMEOUT);
        reset_pmu();
        ignored_write = configured_registers[index];
        assert(cr_power_telemetry_init() == ESP_ERR_INVALID_RESPONSE);
    }
    reset_pmu();
    failed_read = 0x62;
    assert(cr_power_telemetry_init() == ESP_ERR_TIMEOUT);
    assert(registers[0x50] == 7); // 配置快照失败时不修改芯片。
    reset_pmu();
    registers[0x03] = 0;
    assert(cr_power_telemetry_init() == ESP_ERR_NOT_FOUND);
    assert(registers[0x50] == 7);

    reset_pmu();
    registers[0x16] = 7;
    registers[0x62] = 31;
    registers[0x64] = 7;
    assert(cr_power_telemetry_init() == ESP_ERR_INVALID_RESPONSE);
    assert(registers[0x62] == 31);
    assert(strstr(log_output, "input_limit_ma=-1 cc_limit_ma=-1 target_mv=-1") != NULL);

    reset_pmu();
    registers[0x64] = 4; // 电池只允许 4.2 V，发现 4.35 V 配置必须拒绝。
    assert(cr_power_telemetry_init() == ESP_ERR_INVALID_RESPONSE);
    assert(registers[0x62] == 1);
    reset_pmu();
    registers[0x62] = 0xe1;
    assert(cr_power_telemetry_init() == ESP_OK);
    assert(registers[0x62] == 0xeb);
    puts("test_power_telemetry: PASS");
    return 0;
}
