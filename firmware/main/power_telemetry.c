#include "power_telemetry.h"

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_check.h"
#include "esp_log.h"

#define AXP2101_ADDRESS UINT8_C(0x34)
#define AXP2101_CHIP_ID UINT8_C(0x4a)
#define AXP2101_REG_STATUS1 UINT8_C(0x00)
#define AXP2101_REG_STATUS2 UINT8_C(0x01)
#define AXP2101_REG_IC_TYPE UINT8_C(0x03)
#define AXP2101_REG_ADC_CHANNEL_CTRL UINT8_C(0x30)
#define AXP2101_REG_BAT_VOLTAGE_H UINT8_C(0x34)
#define AXP2101_REG_VBUS_VOLTAGE_H UINT8_C(0x38)
#define AXP2101_REG_IRQ_STATUS UINT8_C(0x48)
#define AXP2101_REG_TS_PIN_CTRL UINT8_C(0x50)
#define AXP2101_REG_CHARGE_CURRENT UINT8_C(0x62)
#define AXP2101_REG_CHARGE_VOLTAGE UINT8_C(0x64)
#define AXP2101_CHARGE_CURRENT_500MA UINT8_C(0x0b)
#define AXP2101_CHARGE_CURRENT_MASK UINT8_C(0x1f)
#define AXP2101_REG_BAT_DETECT_CTRL UINT8_C(0x68)
#define AXP2101_REG_BAT_PERCENT UINT8_C(0xa4)
#define AXP2101_BATTERY_PRESENT_BIT UINT8_C(0x08)
#define AXP2101_CHARGE_STATE_MASK UINT8_C(0xe0)
#define AXP2101_CHARGING_STATE UINT8_C(0x20)
#define AXP2101_BAT_ADC_ENABLE_BIT UINT8_C(0x01)
#define AXP2101_TS_ADC_ENABLE_BIT UINT8_C(0x02)
#define AXP2101_VBUS_ADC_ENABLE_BIT UINT8_C(0x04)
#define AXP2101_TS_EXTERNAL_INPUT_BIT UINT8_C(0x10)
#define AXP2101_BAT_DETECT_ENABLE_BIT UINT8_C(0x01)
#define AXP2101_I2C_TIMEOUT_MS 100

static const char *TAG = "power_telemetry";
static i2c_master_dev_handle_t pmu_handle;

static esp_err_t read_registers(uint8_t address, uint8_t *values, size_t length)
{
    return i2c_master_transmit_receive(
        pmu_handle,
        &address,
        sizeof(address),
        values,
        length,
        AXP2101_I2C_TIMEOUT_MS
    );
}

static esp_err_t write_register(uint8_t address, uint8_t value)
{
    uint8_t payload[] = {address, value};
    return i2c_master_transmit(
        pmu_handle,
        payload,
        sizeof(payload),
        AXP2101_I2C_TIMEOUT_MS
    );
}

static esp_err_t update_register(uint8_t address, uint8_t set_bits, uint8_t clear_bits)
{
    uint8_t value;
    ESP_RETURN_ON_ERROR(read_registers(address, &value, 1), TAG, "PMU register read failed");
    value = (uint8_t)((value | set_bits) & (uint8_t)~clear_bits);
    ESP_RETURN_ON_ERROR(write_register(address, value), TAG, "PMU register write failed");
    uint8_t actual;
    ESP_RETURN_ON_ERROR(read_registers(address, &actual, 1), TAG, "PMU readback failed");
    ESP_RETURN_ON_FALSE(
        (actual & (set_bits | clear_bits)) == (value & (set_bits | clear_bits)),
        ESP_ERR_INVALID_RESPONSE, TAG,
        "PMU register 0x%02x verification failed: expected=0x%02x actual=0x%02x",
        (unsigned)address, (unsigned)value, (unsigned)actual
    );
    return ESP_OK;
}

static esp_err_t log_charger_config(const char *phase)
{
    const uint8_t addresses[] = {0x13, 0x15, 0x16, 0x18, 0x50, 0x61, 0x62, 0x63, 0x64, 0x65, 0x67};
    uint8_t values[sizeof(addresses)];
    for (size_t index = 0; index < sizeof(addresses); ++index) {
        ESP_RETURN_ON_ERROR(
            read_registers(addresses[index], &values[index], 1),
            TAG, "charger config read failed at 0x%02x", (unsigned)addresses[index]
        );
    }
    // -1 表示保留编码；这是配置上限，不能当作实测充电电流。
    const int input_limits_ma[] = {100, 500, 900, 1000, 1500, 2000, -1, -1};
    const int target_voltages_mv[] = {-1, 4000, 4100, 4200, 4350, 4400, -1, -1};
    unsigned cc_code = values[6] & 0x1f;
    int cc_ma = cc_code <= 8 ? (int)cc_code * 25
        : cc_code <= 16 ? 200 + ((int)cc_code - 8) * 100 : -1;
    ESP_LOGI(TAG,
        "charger_config phase=%s input_limit_ma=%d cc_limit_ma=%d target_mv=%d"
        " die_ctrl=0x%02x vindpm_cfg=0x%02x input_cfg=0x%02x enable=0x%02x"
        " ts=0x%02x precharge=0x%02x cc=0x%02x termination=0x%02x cv=0x%02x"
        " thermal_cfg=0x%02x timer=0x%02x",
        phase, input_limits_ma[values[2] & 7], cc_ma, target_voltages_mv[values[8] & 7],
        (unsigned)values[0], (unsigned)values[1], (unsigned)values[2], (unsigned)values[3],
        (unsigned)values[4], (unsigned)values[5], (unsigned)values[6], (unsigned)values[7],
        (unsigned)values[8], (unsigned)values[9], (unsigned)values[10]
    );
    return ESP_OK;
}

static esp_err_t log_charger_sample(const uint8_t status[2], cr_power_telemetry_t *sample)
{
    uint8_t vbus[2];
    uint8_t irq[3];
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_VBUS_VOLTAGE_H, vbus, sizeof(vbus)),
        TAG, "VBUS voltage read failed"
    );
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_IRQ_STATUS, irq, sizeof(irq)),
        TAG, "charger IRQ status read failed"
    );
    const char *stages[] = {"trickle", "precharge", "cc", "cv", "done", "stopped", "reserved", "reserved"};
    unsigned vbus_raw = ((unsigned)(vbus[0] & 0x3f) << 8) | vbus[1];
    // 0x2000 是无效 ADC 结果；保留 VINDPM 时的实测电压，不伪装为 0 V。
    int vbus_mv = vbus_raw == 0x2000 ? -1 : (int)vbus_raw;
    sample->vbus_voltage_mv = (int16_t)vbus_mv;
    for (size_t i = 0; i < 2; ++i) sample->pmu_status[i] = status[i];
    for (size_t i = 0; i < 3; ++i) sample->irq_latched[i] = irq[i];
    ESP_LOGI(TAG,
        "charger_sample stage=%s vbus_mv=%d vbus_good=%u vindpm=%u"
        " current_limited=%u thermal_regulation=%u status=0x%02x%02x"
        " irq_latched=0x%02x%02x%02x charge_timeout_latched=%u",
        stages[status[1] & 7], vbus_mv, (unsigned)((status[0] >> 5) & 1),
        (unsigned)((status[1] >> 3) & 1), (unsigned)(status[0] & 1),
        (unsigned)((status[0] >> 1) & 1), (unsigned)status[0], (unsigned)status[1],
        (unsigned)irq[0], (unsigned)irq[1], (unsigned)irq[2], (unsigned)((irq[2] >> 1) & 1)
    );
    return ESP_OK;
}

esp_err_t cr_power_telemetry_init(void)
{
    ESP_RETURN_ON_FALSE(pmu_handle == NULL, ESP_ERR_INVALID_STATE, TAG, "PMU already initialized");

    i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP2101_ADDRESS,
        .scl_speed_hz = 400000,
    };
    ESP_RETURN_ON_ERROR(
        i2c_master_bus_add_device(bsp_i2c_get_handle(), &config, &pmu_handle),
        TAG,
        "failed to attach AXP2101"
    );

    uint8_t chip_id;
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_IC_TYPE, &chip_id, 1),
        TAG,
        "failed to read AXP2101 chip ID"
    );
    ESP_RETURN_ON_FALSE(
        chip_id == AXP2101_CHIP_ID,
        ESP_ERR_NOT_FOUND,
        TAG,
        "unexpected PMU chip ID: 0x%02x",
        chip_id
    );

    ESP_RETURN_ON_ERROR(log_charger_config("before"), TAG, "initial charger config unavailable");
    uint8_t charge_voltage;
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_CHARGE_VOLTAGE, &charge_voltage, 1),
        TAG, "charge voltage config unavailable"
    );
    ESP_RETURN_ON_FALSE(
        (charge_voltage & 7) == 3, ESP_ERR_INVALID_RESPONSE, TAG,
        "expected 4.2 V charge target for this battery, config=0x%02x",
        (unsigned)charge_voltage
    );
    // 此板无电池 NTC。仅关闭 ADC 不能解除 TS 对充电的影响；同步配置 TS 功能及电流源。
    // 对齐 Waveshare 01_AXP2101 / XPowersLib::disableTSPinMeasure，保留芯片自身过温保护。
    ESP_RETURN_ON_ERROR(
        update_register(AXP2101_REG_TS_PIN_CTRL, AXP2101_TS_EXTERNAL_INPUT_BIT, 0x0f),
        TAG, "failed to configure TS external input"
    );
    ESP_RETURN_ON_ERROR(
        update_register(
            AXP2101_REG_ADC_CHANNEL_CTRL,
            AXP2101_BAT_ADC_ENABLE_BIT | AXP2101_VBUS_ADC_ENABLE_BIT,
            AXP2101_TS_ADC_ENABLE_BIT
        ),
        TAG,
        "failed to configure battery ADC"
    );
    ESP_RETURN_ON_ERROR(
        update_register(
            AXP2101_REG_BAT_DETECT_CTRL,
            AXP2101_BAT_DETECT_ENABLE_BIT,
            0
        ),
        TAG,
        "failed to enable battery detection"
    );
    // 用户指定 500 mA；对已确认的 1000 mAh / 3.7 V / 4.2 V 电池为 0.5C。
    ESP_RETURN_ON_ERROR(
        update_register(
            AXP2101_REG_CHARGE_CURRENT,
            AXP2101_CHARGE_CURRENT_500MA,
            AXP2101_CHARGE_CURRENT_MASK & (uint8_t)~AXP2101_CHARGE_CURRENT_500MA
        ),
        TAG, "failed to configure 500 mA charge current"
    );
    ESP_RETURN_ON_ERROR(log_charger_config("after"), TAG, "configured charger state unavailable");
    ESP_LOGI(TAG, "AXP2101 battery telemetry ready");
    return ESP_OK;
}

esp_err_t cr_power_telemetry_read(cr_power_telemetry_t *telemetry)
{
    ESP_RETURN_ON_FALSE(
        telemetry != NULL && pmu_handle != NULL,
        ESP_ERR_INVALID_STATE,
        TAG,
        "PMU telemetry is unavailable"
    );

    uint8_t status[2];
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_STATUS1, status, sizeof(status)),
        TAG,
        "failed to read PMU status"
    );
    cr_power_telemetry_t sample = {
        .battery_present = (status[0] & AXP2101_BATTERY_PRESENT_BIT) != 0,
        .charging = (status[1] & AXP2101_CHARGE_STATE_MASK) == AXP2101_CHARGING_STATE,
    };
    ESP_RETURN_ON_ERROR(log_charger_sample(status, &sample), TAG, "charger diagnostics unavailable");
    if (!sample.battery_present) {
        *telemetry = sample;
        return ESP_OK;
    }

    uint8_t voltage[2];
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_BAT_VOLTAGE_H, voltage, sizeof(voltage)),
        TAG,
        "failed to read battery voltage"
    );
    sample.battery_voltage_mv = (uint16_t)(((uint16_t)(voltage[0] & 0x1f) << 8) | voltage[1]);

    uint8_t percent;
    ESP_RETURN_ON_ERROR(
        read_registers(AXP2101_REG_BAT_PERCENT, &percent, 1),
        TAG,
        "failed to read battery percentage"
    );
    ESP_RETURN_ON_FALSE(
        percent <= 100,
        ESP_ERR_INVALID_RESPONSE,
        TAG,
        "invalid battery percentage: %u",
        (unsigned)percent
    );
    sample.battery_percent = percent;
    *telemetry = sample;
    return ESP_OK;
}
