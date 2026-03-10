# Nano ESP32 Block 1 Step 1: BLE RX -> Core Integration

This document defines the first real on-hardware integration step now that Nano ESP32 BLE bring-up is proven.

Scope is intentionally narrow:

- receive BLE fragments on Nano ESP32
- pass fragment bytes into `BleAdapter`
- observe ACK and display behavior over serial
- keep LCD transport unimplemented for now

## Objective

Validate the board-shell handoff into the existing Rust Block 1 runtime without changing protocol or formatting behavior.

Runtime path under test:

BLE RX fragment  
-> `BleAdapter::on_rx_fragment(...)`  
-> `FirmwareCore` pipeline  
-> ACK pending check  
-> serial ACK log  
-> current display lines check  
-> serial display log

## Responsibilities Split

Board shell responsibilities (Nano-specific):

- initialize serial
- initialize BLE stack and RX callback
- provide current unix timestamp for calls into adapter
- call `on_rx_fragment` with raw received bytes
- send ACK bytes over BLE when available
- print ACK and display lines to serial for bring-up validation

Rust core responsibilities (already implemented):

- packet assembly, parse, and validation
- ingress routing and ACK creation semantics
- device state update and interpolation
- persistence save/restore behavior
- display line formatting

## Step 1 Board-Loop Scaffold

```rust
// setup
serial_init();
let mut adapter = BleAdapter::new(persistence_backend);
adapter.restore_on_boot(now_unix)?;

// BLE callback (board glue)
fn on_ble_fragment(fragment: &[u8], now_unix: u32, adapter: &mut BleAdapter<...>) {
    match adapter.on_rx_fragment(fragment, now_unix) {
        Ok(result) => serial_println!("RX {:?}", result),
        Err(err) => serial_println!("RX ERROR {:?}", err),
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

Notes:

- This step does not add board-side parsing.
- This step does not add LCD transport writes.
- This step does not alter ACK behavior.

## Serial Validation Checklist

Run with Python-generated fixtures sent from phone/test sender and verify:

1. Fragmented weather packet:
- multiple receives may show `NeedMore`
- packet completion eventually occurs
- ACK is emitted

2. Position packet after valid weather:
- ACK is emitted
- display lines become available and print to serial

3. Invalid packet:
- rejection ACK is emitted
- runtime remains stable (no panic/reset)

## Exit Criteria for Step 1

Step 1 is complete when:

- BLE callback forwards real fragments into `BleAdapter`
- ACK bytes are sent/logged for accepted and rejected packets
- display lines are visible over serial after weather + position are present
- no protocol or formatter logic is duplicated in board code

## Next Step After Step 1

Implement hardware `TextDisplay` transport for SparkFun 16x2 SerLCD and replace serial display prints with real LCD writes.
