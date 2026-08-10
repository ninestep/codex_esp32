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
#define AXP2101_REG_BAT_DETECT_CTRL UINT8_C(0x68)
#define AXP2101_REG_BAT_PERCENT UINT8_C(0xa4)
#define AXP2101_BATTERY_PRESENT_BIT UINT8_C(0x08)
#define AXP2101_CHARGE_STATE_MASK UINT8_C(0xe0)
#define AXP2101_CHARGING_STATE UINT8_C(0x20)
#define AXP2101_BAT_ADC_ENABLE_BIT UINT8_C(0x01)
#define AXP2101_TS_ADC_ENABLE_BIT UINT8_C(0x02)
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
    return write_register(address, value);
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

    ESP_RETURN_ON_ERROR(
        update_register(
            AXP2101_REG_ADC_CHANNEL_CTRL,
            AXP2101_BAT_ADC_ENABLE_BIT,
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
