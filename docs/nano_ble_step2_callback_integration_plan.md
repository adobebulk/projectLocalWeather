# Nano ESP32 Block 1 Step 2: Real BLE Callback Integration Plan

This plan defines the next integration step after host-side scaffold validation.

Goal: wire real Nano ESP32 BLE receive callbacks to the existing Rust `BleAdapter` pipeline, with ACK and display output printed to serial during bring-up.

This is still pre-LCD-driver integration.

## Scope

In scope:

- real board BLE RX callback receives fragment bytes
- callback forwards bytes into `adapter.on_rx_fragment(...)`
- callback/loop checks `take_pending_ack()` and sends ACK bytes over BLE TX/notify path
- callback/loop reads `current_display_lines()` and prints lines to serial

Out of scope:

- protocol or parser changes
- formatter changes
- persistence abstraction redesign
- LCD hardware driver implementation

## Recommended File Placement

Board-facing scaffold layer (new, Nano target side):

- `board/nano_step2_ble_scaffold/README.md` (wiring notes and setup checklist)
- `board/nano_step2_ble_scaffold/src/main.rs` (setup/loop + BLE callback glue)
- `board/nano_step2_ble_scaffold/src/ble_callbacks.rs` (callback-to-adapter handoff)
- `board/nano_step2_ble_scaffold/src/time.rs` (unix timestamp helper)

Existing Rust core crate remains unchanged as the logic source of truth:

- `weather_protocol_rust/src/ble_adapter.rs`
- `weather_protocol_rust/src/core.rs`

## Responsibilities Split

Board shell (Nano-specific):

- serial initialization
- BLE service + characteristic setup
- BLE RX callback registration
- timestamp source
- BLE ACK transmit call site
- serial printing of current display lines

Rust core (`BleAdapter` + `FirmwareCore`):

- assembler, parse, validation
- ingress routing and ACK content generation
- device state and interpolation
- persistence save/restore
- deterministic display formatting

## Callback Wiring Plan

### 1. Boot

1. initialize serial
2. initialize persistence backend (temporary in-memory in this phase; flash later)
3. create `BleAdapter`
4. call `adapter.restore_on_boot(now_unix)`
5. if display lines exist, print them to serial

### 2. BLE RX callback

When BLE characteristic receives bytes:

1. read raw fragment payload bytes from callback
2. call `adapter.on_rx_fragment(fragment, now_unix)`
3. log assembler result (`NeedMore`, `PacketComplete`, or `Malformed`) to serial

### 3. ACK TX trigger

After each fragment callback:

1. call `adapter.take_pending_ack()`
2. if `Some(ack)`, send it on BLE TX/notify characteristic
3. print `SEND ACK <len> bytes` to serial

### 4. Serial display output

After each fragment callback (or in loop tick):

1. call `adapter.current_display_lines()`
2. if present, print Line 1 and Line 2 to serial
3. optional board-side dedupe to avoid repeated identical lines in serial logs

## Pseudocode

```rust
fn setup() {
    serial_init();
    ble_init_services();

    let backend = InMemoryPersistenceBackend::default(); // Step 2 only.
    ADAPTER = Some(BleAdapter::new(backend));

    if let Some(adapter) = ADAPTER.as_mut() {
        let now = now_unix();
        let _ = adapter.restore_on_boot(now);
        if let Some(lines) = adapter.current_display_lines() {
            serial_println!("LCD:");
            serial_println!("{}", lines.line1);
            serial_println!("{}", lines.line2);
        }
    }
}

fn on_ble_rx_callback(fragment: &[u8]) {
    let now = now_unix();
    let adapter = ADAPTER.as_mut().expect("adapter initialized");

    match adapter.on_rx_fragment(fragment, now) {
        Ok(state) => serial_println!("RX {:?}", state),
        Err(err) => serial_println!("RX ERROR {:?}", err),
    }

    if let Some(ack) = adapter.take_pending_ack() {
        ble_send_ack_notify(&ack);
        serial_println!("SEND ACK {} bytes", ack.len());
    }

    if let Some(lines) = adapter.current_display_lines() {
        serial_println!("LCD:");
        serial_println!("{}", lines.line1);
        serial_println!("{}", lines.line2);
    }
}
```

## Future Plug-In Points

LCD driver (future):

- replace serial display prints with `TextDisplay` hardware implementation for SparkFun 16x2 SerLCD

Flash persistence backend (future):

- replace temporary in-memory backend with board-specific non-volatile backend implementing existing persistence traits

No changes are needed to `BleAdapter` public API for either plug-in.

## Step 2 Exit Criteria

- real Nano BLE RX callback is forwarding fragments into `BleAdapter`
- ACK bytes are transmitted over BLE and logged to serial
- display lines are printed to serial when weather + position are valid
- no protocol or formatting logic duplicated in board shell
