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
    assert(strstr(source, "return append_device_info_packet(ctxt->om);") != NULL);
    assert(strstr(source, "const uint16_t fragment_count = 1;") != NULL);
    assert(strstr(source, "CR_FRAGMENT_HEADER_BYTES") != NULL);
    assert(strstr(source, "Codex Remote 0.1.0") == NULL);
    return 0;
}
