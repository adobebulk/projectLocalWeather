# Nano Block 1.0 First Board Attempt

This scaffold is the first real board-side integration attempt for Block 1.0:

- Arduino/Nano shell owns serial + BLE callback hooks.
- Rust static library owns protocol/runtime logic through the C ABI.

## Intended Layout

- `src/main.cpp`: thin board shell calling Rust ABI
- `../../weather_protocol_rust/include/weather_bridge_ffi.h`: ABI header

## Build Artifact From Rust

Build the Rust static library:

```bash
cd weather_protocol_rust
cargo build --release
```

Expected artifact:

- `weather_protocol_rust/target/release/libweather_protocol_rust.a`

## Arduino-Side Include/Link Plan

Include in board build:

- header: `weather_protocol_rust/include/weather_bridge_ffi.h`
- static lib: `weather_protocol_rust/target/release/libweather_protocol_rust.a`

For first attempt, copy/symlink these into the board project structure expected by your local Arduino build tooling.

## First Board Test Goal

1. Flash shell with serial enabled.
2. Confirm boot logs:
- bridge constructed
- `restore_on_boot` call result
3. Send BLE fragment to RX callback hook.
4. Confirm serial output shows:
- ingest state
- ACK length when pending
- display lines once weather + position become available

LCD transport and flash backend remain deferred in this step.
