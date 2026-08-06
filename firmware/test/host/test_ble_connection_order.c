#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static void read_source(const char *path, char *buffer, size_t capacity)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    size_t length = fread(buffer, 1, capacity - 1, file);
    assert(!ferror(file));
    assert(feof(file));
    buffer[length] = '\0';
    fclose(file);
}

int main(void)
{
    char source[32768];
    read_source("firmware/components/codex_remote_ble/src/ble_transport.c", source, sizeof(source));

    assert(strstr(source, "queue_device_info(event->subscribe.conn_handle)") != NULL);
    assert(strstr(source, "send_device_info(event->subscribe.conn_handle)") == NULL);
    assert(strstr(source, "xTaskCreatePinnedToCore(") != NULL);
    assert(strstr(source, "device_info_task, \"device_info\"") != NULL);
    assert(strstr(source, "NIMBLE_CORE") != NULL);
    return 0;
}
