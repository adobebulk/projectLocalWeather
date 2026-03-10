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

Important:

- `target/release/libweather_protocol_rust.a` is host-built in local desktop development.
- it is useful for ABI/symbol checks, but not sufficient for Nano link validation.
- for target-compatible build strategy, see:
  - `docs/block1_nano_rust_target_build_strategy.md`

Useful verification:

```bash
cd weather_protocol_rust
nm -g target/release/libweather_protocol_rust.a | rg "bridge_(new_in_memory|restore_on_boot|push_ble_fragment|take_pending_ack|get_display_lines|free)"
```

Expected symbols include:

- `bridge_new_in_memory`
- `bridge_free`
- `bridge_restore_on_boot`
- `bridge_push_ble_fragment`
- `bridge_take_pending_ack`
- `bridge_get_display_lines`

## Arduino-Side Include/Link Plan

Include in board build:

- header: `weather_protocol_rust/include/weather_bridge_ffi.h`
- static lib: `weather_protocol_rust/target/release/libweather_protocol_rust.a`

For first attempt, copy/symlink these into the board project structure expected by your local Arduino build tooling.

Minimum expectations:

- C++ compile can resolve `#include "weather_bridge_ffi.h"`
- linker sees `libweather_protocol_rust.a`
- no unresolved `bridge_*` symbols at link time

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

## Expected Serial Output (Boot-Only)

On successful boot-only run with no packets received:

```text
BOOT start
BOOT bridge_new_in_memory ok
BOOT restore rc=0
DISPLAY none
```

## Expected Serial Output (First Fragment Ingest)

After one fragment reaches `on_ble_fragment_received(...)`, expected shape:

```text
RX len=<N> rc=0 state=<0|1|2>
ACK <none|bytes=...>
DISPLAY <none|lines>
```

Examples:

- partial packet: likely `state=0`, `ACK none`, `DISPLAY none`
- complete rejected packet: likely `state=1`, `ACK bytes=32`
- complete accepted packet: likely `state=1`, `ACK bytes=32`, and display lines when weather+position state exists

## Likely Failure Points

- static library built for host architecture instead of target architecture
- include path not configured for `weather_bridge_ffi.h`
- linker not including `libweather_protocol_rust.a`
- missing transitive runtime/startup flags required by the Arduino toolchain
- callback not wired, so no `RX ...` logs appear
