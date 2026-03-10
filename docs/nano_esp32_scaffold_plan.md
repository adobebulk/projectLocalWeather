# Nano ESP32 Block 1 Integration Scaffold Plan

This document defines the thinnest board shell for Arduino Nano ESP32 bring-up before full BLE and LCD hardware integration.

It preserves the existing Block 1 architecture and uses `BleAdapter` as the board-facing boundary.

## Scope

This scaffold is for:

- boot sequencing
- serial initialization and diagnostics
- BLE fragment callback connection points
- serial display output during bring-up
- persistence restore invocation

This scaffold does not add:

- full BLE stack implementation details
- real SerLCD transport implementation
- protocol changes

## Minimal Board Shell Responsibilities (Board-Specific)

Board code should own:

- Arduino setup/loop lifecycle
- serial port initialization
- wall-clock timestamp source (`now_unix`)
- BLE callback registration (future wiring)
- BLE transmit of ACK bytes (future wiring)
- temporary serial output of current `DisplayLines`

## Core Responsibilities (Rust Block 1 Stack)

Core code already owns:

- packet assembly
- parsing and validation
- ingress routing
- ACK generation semantics
- device state updates
- interpolation and confidence
- persistence save/restore behavior
- display line formatting

Board shell must treat core as source of truth and must not duplicate protocol logic.

## Boot Sequence (Scaffold)

1. Initialize serial output.
2. Construct persistence backend (temporary in-memory for host-side bring-up, board flash backend later).
3. Construct `BleAdapter`.
4. Call `adapter.restore_on_boot(now_unix)`.
5. Print restore status and initial display lines (if present).

## Loop Shape (Scaffold)

```rust
fn setup() {
    serial_init();
    adapter = BleAdapter::new(persistence_backend);
    adapter.restore_on_boot(now_unix);
}

fn loop() {
    // BLE callback wiring point:
    // when a fragment arrives, call adapter.on_rx_fragment(fragment, now_unix).

    if let Some(ack) = adapter.take_pending_ack() {
        // BLE transmit wiring point.
        serial_println!("SEND ACK {} bytes", ack.len());
        ble_send_ack(ack);
    }

    if let Some(lines) = adapter.current_display_lines() {
        // Temporary bring-up path until LCD transport is wired.
        serial_println!("LCD:");
        serial_println!("{}", lines.line1);
        serial_println!("{}", lines.line2);
    }
}
```

## BLE Callback Connection Point

When the Nano ESP32 BLE receive callback fires:

1. extract incoming fragment bytes
2. call `adapter.on_rx_fragment(fragment, now_unix)`
3. log assembler status to serial during bring-up

## Temporary Display Bring-Up Path

Until the SparkFun LCD transport is connected:

- print `DisplayLines` to serial
- optionally suppress duplicate serial prints by caching previous lines in board code

When LCD driver is ready, replace serial display prints with calls to the hardware `TextDisplay` implementation.

## Persistence Restore Connection Point

Persistence restore happens exactly once during boot via:

- `adapter.restore_on_boot(now_unix)`

No board-side state reconstruction should be implemented outside this path.
