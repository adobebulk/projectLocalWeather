# Weather Computer

## Project Direction (Block 1.0)

Block 1.0 now uses a single product-oriented firmware path:

- deployable firmware written in Rust
- targeting ESP32-S3 / Arduino Nano ESP32 class hardware
- no Arduino C++ deployable path as the primary implementation
- no Rust↔C++ bridge/FFI as the primary deployment strategy

Conceptually:

`regional_weather_field + current_position + current_time -> estimated_local_conditions`

## Primary Firmware Path

Primary path:

- [`firmware_esp32/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/firmware_esp32)

This path is intended to become the deployable product firmware and currently includes:

- packet assembler
- packet parser / strict validation
- ingress handling
- device state
- interpolation engine
- persistence model (two-slot last-good style)
- display formatter
- display output boundary
- BLE-facing runtime boundary
- firmware runtime/boot loop scaffold

## Hardware and Runtime Baseline

Block 1 architecture constraints preserved:

- ESP32-S3 / Arduino Nano ESP32 class board
- SparkFun 16x2 SerLCD RGB Qwiic display
- BLE communication with phone
- 3x3 weather field, 240 miles across
- forecast slots at 0 / 60 / 120 minutes
- confidence computed on-device only

Runtime flow:

BLE fragments  
-> adapter  
-> assembler  
-> parser  
-> ingress  
-> device state  
-> interpolation  
-> display formatter  
-> display output

Persistence flow:

accepted packets  
-> persistence write

Boot flow:

restore persisted weather + position  
-> rebuild state  
-> recompute estimate  
-> refresh display

## Protocol

Protocol remains unchanged:

- binary, little-endian
- common header with magic `0x5743`, version `1`, CRC-32
- packet types:
  - `RegionalSnapshotV1`
  - `PositionUpdateV1`
  - `AckV1`
- strict validation
- confidence is not transmitted on wire

Python remains protocol truth source:

- [`weather_protocol/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/weather_protocol)

## Repository Layout

- [`firmware_esp32/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/firmware_esp32): primary embedded Rust firmware path
- [`weather_protocol/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/weather_protocol): Python protocol truth source and fixtures
- [`fixtures/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/fixtures): deterministic protocol binaries
- [`weather_protocol_rust/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/weather_protocol_rust): legacy transition crate from pre-pivot phase (no longer primary deployment path)
- [`docs/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/docs): architecture, policy, and integration notes

## Running Tests

Python protocol tests:

```bash
python3 -m pytest
```

Primary firmware crate tests:

```bash
cd firmware_esp32
cargo test
```

## Current Status

- Python protocol reference: complete
- `firmware_esp32` primary path: established and populated with Block 1 runtime modules
- next step: complete first true target-toolchain build + first hardware deployment attempt on ESP32-S3

## License

All Rights Reserved.

Copyright (C) C.T. Smith.

This repository and its contents are not licensed for reuse, redistribution, or modification without explicit permission from the author.
