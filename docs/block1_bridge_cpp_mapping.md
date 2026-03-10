# Block 1.0 Arduino C++ Shell Mapping to Rust FirmwareBridge

This note defines how a future Arduino/Nano C++ shell should call the current Rust `FirmwareBridge` without changing runtime behavior.

## 1. Bridge Calls Used by the Arduino Shell

The shell should map to these Rust bridge calls:

- create/init: `FirmwareBridge::new(backend)`
- boot restore: `restore_on_boot(now_unix_timestamp)`
- ingest BLE fragment: `push_ble_fragment(fragment_bytes, now_unix_timestamp)`
- ACK retrieval: `take_pending_ack_bytes()`
- display retrieval: `current_display_lines_snapshot()`

The shell should treat this as the only runtime boundary for protocol/state/display logic.

## 2. Data Crossing the Seam

Incoming data (shell -> Rust):

- BLE fragment bytes (`&[u8]` equivalent), passed directly from RX callback payload
- current unix timestamp (`u32`) for each call that requires time

Outgoing data (Rust -> shell):

- ACK bytes as owned `Vec<u8>` when `take_pending_ack_bytes()` returns `Some(...)`
- display snapshot as `BridgeDisplayLines` when `current_display_lines_snapshot()` returns `Some(...)`

`BridgeDisplayLines` fields:

- `line1_bytes: [u8; 16]`
- `line1_len: u8`
- `line2_bytes: [u8; 16]`
- `line2_len: u8`

## 3. Arduino-Side Handling of Display Lines

Arduino-side handling should be byte/length based:

- each line is a fixed 16-byte ASCII-compatible buffer
- `line*_len` indicates the valid prefix length
- no Unicode/UTF processing is required for Block 1 display output

This is suitable for both:

- serial output (print first `line*_len` bytes)
- LCD output (write first `line*_len` bytes, optionally pad to 16 columns in transport layer)

The shell should not reinterpret wording, truncate, or reformat confidence.

## 4. Thin Shell Runtime Pattern

The shell loop/callback should remain minimal:

1. BLE callback receives fragment bytes.
2. Call `push_ble_fragment(fragment, now_unix)`.
3. Call `take_pending_ack_bytes()`:
- if ACK exists, send over BLE TX/notify characteristic.
4. Call `current_display_lines_snapshot()`:
- if display lines exist, print to serial now and later send to LCD transport.

The shell must not duplicate parser, validation, interpolation, or formatting logic.

## 5. Future C ABI Note

This mapping can later be exposed through a minimal C ABI wrapper without changing the high-level bridge shape.

Expected future C ABI wrapper scope:

- constructor/init bridge handle
- boot restore call
- fragment push call
- pending ACK retrieval call
- display snapshot retrieval call

The current Rust `FirmwareBridge` interface is already aligned to that narrow ABI surface.
