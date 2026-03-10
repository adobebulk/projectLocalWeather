// Block 1.0 Arduino/Nano shell usage stub for Rust C ABI bridge.
//
// This is a scaffold example only:
// - no real BLE library integration
// - no LCD transport integration
// - no protocol logic in C++
//
// The shell stays thin and forwards bytes into Rust.

#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Include Arduino.h in real firmware:
// #include <Arduino.h>

extern "C" {

// Opaque Rust-owned handle.
struct FirmwareBridgeHandle;

enum BridgeResultCode : int32_t {
    BRIDGE_OK = 0,
    BRIDGE_NO_DATA = 1,
    BRIDGE_NULL_POINTER = 2,
    BRIDGE_INVALID_ARGUMENT = 3,
    BRIDGE_BUFFER_TOO_SMALL = 4,
    BRIDGE_RUNTIME_ERROR = 5,
};

enum BridgeIngestState : int32_t {
    BRIDGE_INGEST_NEED_MORE = 0,
    BRIDGE_INGEST_PACKET_COMPLETE = 1,
    BRIDGE_INGEST_MALFORMED = 2,
};

struct BridgeDisplayLinesC {
    uint8_t line1[16];
    uint8_t line1_len;
    uint8_t line2[16];
    uint8_t line2_len;
};

FirmwareBridgeHandle* bridge_new_in_memory(void);
void bridge_free(FirmwareBridgeHandle* handle);

BridgeResultCode bridge_restore_on_boot(
    FirmwareBridgeHandle* handle,
    uint32_t now_unix_timestamp);

BridgeResultCode bridge_push_ble_fragment(
    FirmwareBridgeHandle* handle,
    const uint8_t* fragment_ptr,
    size_t fragment_len,
    uint32_t now_unix_timestamp,
    BridgeIngestState* out_ingest_state);

BridgeResultCode bridge_take_pending_ack(
    FirmwareBridgeHandle* handle,
    uint8_t* out_buf,
    size_t out_capacity,
    size_t* out_ack_len);

BridgeResultCode bridge_get_display_lines(
    const FirmwareBridgeHandle* handle,
    BridgeDisplayLinesC* out_lines);
}

namespace {

FirmwareBridgeHandle* g_bridge = nullptr;

uint32_t now_unix() {
    // Board hook:
    // Replace with RTC/GPS/system time source when available.
    // Placeholder monotonic-style value for scaffold.
    static uint32_t t = 1'700'000'000u;
    return ++t;
}

void print_ascii_line(const uint8_t* bytes, uint8_t len) {
    char buf[17];
    size_t n = (len <= 16) ? len : 16;
    memcpy(buf, bytes, n);
    buf[n] = '\0';
    // Serial.println(buf);
    (void)buf; // remove when Serial is enabled
}

void log_display_lines_if_available() {
    if (g_bridge == nullptr) {
        return;
    }

    BridgeDisplayLinesC lines{};
    BridgeResultCode rc = bridge_get_display_lines(g_bridge, &lines);
    if (rc != BRIDGE_OK) {
        return;
    }

    // Serial.println("LCD:");
    print_ascii_line(lines.line1, lines.line1_len);
    print_ascii_line(lines.line2, lines.line2_len);
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
        return;
    }

    if (rc == BRIDGE_BUFFER_TOO_SMALL) {
        // Serial.print("ACK buffer too small, need ");
        // Serial.println((int)ack_len);
        return;
    }

    if (rc != BRIDGE_OK) {
        // Serial.println("ACK retrieval error");
        return;
    }

    // BLE TX hook:
    // ble_send_notify(ack_buf, ack_len);
    // Serial.print("SEND ACK bytes=");
    // Serial.println((int)ack_len);
    (void)ack_buf;
}

}  // namespace

// Arduino setup scaffold.
void setup() {
    // Serial.begin(115200);
    // while (!Serial) { }
    // Serial.println("Boot");

    g_bridge = bridge_new_in_memory();
    if (g_bridge == nullptr) {
        // Serial.println("bridge_new_in_memory failed");
        return;
    }

    BridgeResultCode rc = bridge_restore_on_boot(g_bridge, now_unix());
    if (rc != BRIDGE_OK) {
        // Serial.println("restore_on_boot failed");
    }

    log_display_lines_if_available();

    // BLE setup hook:
    // register RX callback that calls on_ble_fragment_received(...)
}

// Arduino loop scaffold.
void loop() {
    // Real shell can remain mostly event-driven via BLE callback.
    // Optional periodic display poll can happen here:
    log_display_lines_if_available();

    // delay(100);
}

// BLE RX callback shape for real board integration.
void on_ble_fragment_received(const uint8_t* data, size_t len) {
    if (g_bridge == nullptr) {
        return;
    }
    if (data == nullptr && len > 0) {
        return;
    }

    BridgeIngestState ingest_state = BRIDGE_INGEST_NEED_MORE;
    BridgeResultCode rc = bridge_push_ble_fragment(
        g_bridge,
        data,
        len,
        now_unix(),
        &ingest_state);

    if (rc != BRIDGE_OK) {
        // Serial.println("bridge_push_ble_fragment error");
        return;
    }

    // Serial diagnostics for bring-up:
    // Serial.print("ingest_state=");
    // Serial.println((int)ingest_state);

    send_ack_if_available();
    log_display_lines_if_available();
}
