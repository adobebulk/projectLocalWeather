# Arduino Nano ESP32 Serial Bring-Up Plan (Block 1)

This plan describes how to validate the Block 1 firmware stack over serial output before the real LCD driver is connected.

It uses the existing runtime boundaries:

- `BleAdapter` for ingress and ACK lifecycle
- `FirmwareCore` (owned by `BleAdapter`) for assembly, parsing, state, interpolation, persistence, and display line updates
- `DisplayLines` as the display output contract

## Purpose

Use serial output as a temporary observability path during board bring-up so firmware behavior can be validated without the SparkFun 16x2 display hardware.

## Bring-Up Flow

1. Boot and restore:
- call `adapter.restore_on_boot(now_unix)`
- print success/failure and whether display lines are immediately available

2. Receive BLE fragments:
- board BLE callback receives chunk bytes
- callback calls `adapter.on_rx_fragment(fragment, now_unix)`
- log assembler state (`NeedMore`, `PacketComplete`, `Malformed`)

3. Send ACKs:
- after each fragment, call `adapter.take_pending_ack()`
- if present, transmit via BLE and print `SEND ACK <len> bytes`

4. Render display lines to serial:
- call `adapter.current_display_lines()`
- if present and changed, print:
  - `line1`
  - `line2`

This validates the full software path while LCD hardware integration is pending.

## Temporary Runtime Shape (Board Side)

```rust
// boot
adapter.restore_on_boot(now_unix)?;

loop {
    if let Some(fragment) = ble_receive_fragment() {
        adapter.on_rx_fragment(&fragment, now_unix)?;
    }

    if let Some(ack) = adapter.take_pending_ack() {
        ble_send_ack(&ack);
        serial_println!("SEND ACK {} bytes", ack.len());
    }

    if let Some(lines) = adapter.current_display_lines() {
        serial_println!("LCD:");
        serial_println!("{}", lines.line1);
        serial_println!("{}", lines.line2);
    }
}
```

## What to Validate Over Serial

- Boot restore path executes without panic.
- Fragmented weather packet produces assembler `NeedMore` states before completion.
- Completed packets produce ACK activity for both accepted and rejected cases.
- Display lines appear only once weather + position are both valid.
- Display lines update deterministically as new packets are applied.

## Existing Reference Example

Use this repo example as the software reference implementation of the serial bring-up loop:

- `weather_protocol_rust/examples/firmware_loop_skeleton.rs`

Run it with:

```bash
cd weather_protocol_rust
cargo run --example firmware_loop_skeleton
```

This example demonstrates:

- boot restore call
- fragmented packet delivery through `BleAdapter`
- ACK activity printing
- serial rendering of `DisplayLines`
- clear connection points for future BLE callback wiring, flash persistence backend, and LCD driver transport
