# Weather Computer — Protocol and Firmware Status

This document tracks Block 1 protocol and firmware implementation status after the embedded Rust pivot.

## Block 1 Direction

Current Block 1.0 deployment direction:

- single product firmware path in embedded Rust
- target hardware class: ESP32-S3 / Arduino Nano ESP32
- no Arduino C++ firmware as primary deployment path
- no Rust↔C++ bridge/ABI as primary deployment path

## Protocol Truth Source (Python)

Status: COMPLETE

Location:

- [`weather_protocol/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/weather_protocol)

Capabilities:

- packet encode/decode
- strict validation
- CRC validation
- fixture generation
- packet dump tool

Packet types:

- `RegionalSnapshotV1`
- `PositionUpdateV1`
- `AckV1`

Python remains the protocol truth source.

## Primary Embedded Firmware (`firmware_esp32`)

Status: ESTABLISHED (ACTIVE PRIMARY PATH)

Location:

- [`firmware_esp32/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/firmware_esp32)

Implemented module set:

- assembler
- parser/validation
- ingress
- device state
- interpolation
- persistence abstraction/model
- display formatter
- display output boundary
- BLE-facing runtime boundary
- runtime/boot scaffold

Behavioral baseline preserved:

- 3x3 field, 240 miles
- slot offsets 0/60/120
- strict packet validation
- confidence computed on-device
- persistence of weather + position across reboot

## Legacy Transition Path

`weather_protocol_rust/` is now a legacy transition artifact from the prior deployment approach.

Status: DE-EMPHASIZED

Notes:

- useful as historical reference while pivoting
- not the primary deployment path for Block 1.0

## Not Yet Implemented (Product Hardware Level)

- target toolchain-complete embedded build output for board deployment
- board BLE callback wiring to runtime boundary on device
- board flash backend for persistence
- hardware SerLCD transport implementation
- iPhone companion app integration with live board

## Current Focus

1. make `firmware_esp32/` the end-to-end build/deploy path for ESP32-S3 target toolchain
2. execute first true board deployment attempt from that path
3. wire BLE RX/TX and persistence/display hardware boundaries on target
