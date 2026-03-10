# Block 1.0 First Real On-Board Integration Attempt

This note defines the first concrete build/link/test attempt for running the Rust Block 1 core behind a thin Nano C++ shell.

## 1. Scope of This Attempt

Included now:

- build Rust crate as static library
- call C ABI from Nano-side C++ shell
- serial logging for ingest state, ACK activity, and display lines

Deferred:

- LCD transport driver
- real flash persistence backend
- full BLE library wiring details

## 2. Rust Build Artifact Shape

`weather_protocol_rust` is configured to emit:

- `rlib` (existing Rust use)
- `staticlib` (C/C++ linking)

Build command:

```bash
cd weather_protocol_rust
cargo build --release
```

Expected static library artifact:

- `weather_protocol_rust/target/release/libweather_protocol_rust.a`

ABI header:

- `weather_protocol_rust/include/weather_bridge_ffi.h`

## 3. Arduino/Nano Shell Mapping

The shell uses these ABI functions:

- `bridge_new_in_memory`
- `bridge_restore_on_boot`
- `bridge_push_ble_fragment`
- `bridge_take_pending_ack`
- `bridge_get_display_lines`
- `bridge_free` (for completeness)

Board scaffold entry point:

- `board/nano_block1_attempt/src/main.cpp`

## 4. First Board-Side File Structure

Minimal structure for first attempt:

```text
board/nano_block1_attempt/
  README.md
  src/
    main.cpp
weather_protocol_rust/
  include/
    weather_bridge_ffi.h
  target/release/
    libweather_protocol_rust.a
```

## 5. Exact First Real Test Sequence

1. Build Rust static library:
- `cd weather_protocol_rust`
- `cargo build --release`

2. Prepare board project:
- include `weather_bridge_ffi.h`
- link `libweather_protocol_rust.a`
- use `board/nano_block1_attempt/src/main.cpp` scaffold

3. Flash Nano shell and open serial monitor.

4. Verify boot sequence logs:
- shell boot message
- bridge init success/failure
- restore call result

5. Feed a BLE fragment through callback hook `on_ble_fragment_received(...)`.

6. Verify serial output shows:
- ingest state (`NeedMore`, `PacketComplete`, or `Malformed`)
- pending ACK byte length when available
- display lines when weather + position data exist

## 6. Pass Criteria for This Attempt

- Rust static library links into board shell build.
- ABI calls execute from board shell without crash.
- serial shows ACK and display data paths through Rust core.

## 7. Assumptions

- first pass uses in-memory bridge constructor (`bridge_new_in_memory`)
- timestamp source is temporary placeholder
- BLE TX and RX callbacks are integrated incrementally with current serial-first validation strategy
