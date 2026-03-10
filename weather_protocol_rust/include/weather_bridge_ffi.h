#ifndef WEATHER_BRIDGE_FFI_H
#define WEATHER_BRIDGE_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FirmwareBridgeHandle FirmwareBridgeHandle;

typedef enum BridgeResultCode {
    BRIDGE_OK = 0,
    BRIDGE_NO_DATA = 1,
    BRIDGE_NULL_POINTER = 2,
    BRIDGE_INVALID_ARGUMENT = 3,
    BRIDGE_BUFFER_TOO_SMALL = 4,
    BRIDGE_RUNTIME_ERROR = 5
} BridgeResultCode;

typedef enum BridgeIngestState {
    BRIDGE_INGEST_NEED_MORE = 0,
    BRIDGE_INGEST_PACKET_COMPLETE = 1,
    BRIDGE_INGEST_MALFORMED = 2
} BridgeIngestState;

typedef struct BridgeDisplayLinesC {
    uint8_t line1[16];
    uint8_t line1_len;
    uint8_t line2[16];
    uint8_t line2_len;
} BridgeDisplayLinesC;

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

#ifdef __cplusplus
}
#endif

#endif  // WEATHER_BRIDGE_FFI_H
