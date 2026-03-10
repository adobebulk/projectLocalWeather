// First real on-board integration attempt scaffold for Block 1.0.
//
// This file shows the Nano shell shape that calls the Rust C ABI.
// BLE + LCD transport are intentionally hooks only in this step.

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "weather_bridge_ffi.h"

namespace {

FirmwareBridgeHandle* g_bridge = nullptr;

uint32_t now_unix() {
    // Step-1 placeholder timestamp source.
    // Replace with RTC/system/GPS source when available.
    static uint32_t t = 1'700'000'000u;
    return ++t;
}

void serial_print_line(const uint8_t* bytes, uint8_t len) {
    char buffer[17];
    size_t n = (len <= 16) ? len : 16;
    memcpy(buffer, bytes, n);
    buffer[n] = '\0';
    Serial.println(buffer);
}

void print_display_if_available() {
    if (g_bridge == nullptr) {
        return;
    }

    BridgeDisplayLinesC lines{};
    BridgeResultCode rc = bridge_get_display_lines(g_bridge, &lines);
    if (rc != BRIDGE_OK) {
        if (rc == BRIDGE_NO_DATA) {
            Serial.println("DISPLAY none");
        } else {
            Serial.print("DISPLAY error rc=");
            Serial.println((int)rc);
        }
        return;
    }

    Serial.println("DISPLAY lines");
    serial_print_line(lines.line1, lines.line1_len);
    serial_print_line(lines.line2, lines.line2_len);
}

void send_ack_if_available() {
    if (g_bridge == nullptr) {
        return;
    }

    uint8_t ack_buf[64];
    size_t ack_len = 0;
    BridgeResultCode rc = bridge_take_pending_ack(
        g_bridge,
        ack_buf,
        sizeof(ack_buf),
        &ack_len);

    if (rc == BRIDGE_NO_DATA) {
        Serial.println("ACK none");
        return;
    }

    if (rc == BRIDGE_BUFFER_TOO_SMALL) {
        Serial.print("ACK buffer too small, required=");
        Serial.println((unsigned long)ack_len);
        return;
    }

    if (rc != BRIDGE_OK) {
        Serial.println("ACK retrieval error");
        return;
    }

    // BLE TX hook for next step:
    // ble_notify_ack(ack_buf, ack_len);
    Serial.print("ACK bytes=");
    Serial.println((unsigned long)ack_len);
}

}  // namespace

// Callback hook shape for BLE RX data.
void on_ble_fragment_received(const uint8_t* fragment, size_t len) {
    if (g_bridge == nullptr) {
        return;
    }
    if (fragment == nullptr && len > 0) {
        return;
    }

    BridgeIngestState ingest_state = BRIDGE_INGEST_NEED_MORE;
    BridgeResultCode rc = bridge_push_ble_fragment(
        g_bridge,
        fragment,
        len,
        now_unix(),
        &ingest_state);

    Serial.print("RX len=");
    Serial.print((unsigned long)len);
    Serial.print(" rc=");
    Serial.print((int)rc);
    Serial.print(" state=");
    Serial.println((int)ingest_state);

    if (rc != BRIDGE_OK) {
        Serial.println("bridge_push_ble_fragment error");
        return;
    }

    send_ack_if_available();
    print_display_if_available();
}

void setup() {
    Serial.begin(115200);
    while (!Serial) {
    }
    Serial.println("BOOT start");

    g_bridge = bridge_new_in_memory();
    if (g_bridge == nullptr) {
        Serial.println("bridge_new_in_memory failed");
        return;
    }
    Serial.println("BOOT bridge_new_in_memory ok");

    BridgeResultCode rc = bridge_restore_on_boot(g_bridge, now_unix());
    Serial.print("BOOT restore rc=");
    Serial.println((int)rc);
    if (rc != BRIDGE_OK) {
        Serial.println("restore_on_boot error");
    }

    print_display_if_available();

    // BLE setup hook:
    // register callback to call on_ble_fragment_received(fragment, len).
}

void loop() {
    // Event-driven RX is expected; keep loop thin.
    delay(250);
}
