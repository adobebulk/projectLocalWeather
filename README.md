# Weather Computer

## 1. Project Overview

The Weather Computer project is a vehicle weather awareness device intended to remain useful when cellular coverage becomes unreliable or disappears.

The system is designed around a practical constraint: a moving vehicle cannot depend on continuous network access to keep weather information current. Instead of querying the network constantly, the system stores a regional weather field on the device and estimates local conditions from that field as the vehicle moves.

The goal is predictable, defensible behavior rather than perfect forecasting. Block 1 favors explicit validation, stable interpolation behavior, and bounded assumptions over more complex models.

Conceptually, the system operates as:

`regional_weather_field + current_position + current_time -> estimated_local_conditions`

```text
iPhone App
    |
    | BLE packets
    v
Arduino Device
|- PacketAssembler
|- BLE Adapter Boundary
|- PacketIngress
|- Protocol Parser
|- DeviceState
|- Interpolation Engine
|- Display Formatter
|- Display Driver Interface
'- Display Driver (future hardware transport)
```

## 2. System Architecture

The current Block 1 architecture has three major parts.

```text
 iPhone App
     │
     │ BLE packets
     ▼
 Arduino Device
 ┌───────────────────────┐
 │ Packet Parser (Rust)  │
 │ Interpolation Engine  │
 │ Device State          │
 │ Display Driver        │
 └───────────────────────┘
```

The iPhone companion application is responsible for:

- obtaining GPS position
- fetching NOAA / National Weather Service data
- generating a regional weather field
- transmitting compact binary packets over BLE

The device hardware is currently planned around:

- Arduino Nano ESP32
- SparkFun 16x2 SerLCD RGB Qwiic display

The device firmware is responsible for:

- BLE adapter boundary for board callback handoff into firmware core
- packet assembly from transport fragments
- packet parsing and validation
- packet ingress routing and ACK generation
- runtime device state handling and estimate recomputation
- interpolation of local conditions from the stored regional field
- persistence of active weather and latest position across reboot
- pure display line formatting
- display driver interface boundary (without hardware transport yet)

At the repository level, the Python implementation acts as the protocol reference, and the Rust implementation follows that reference for firmware-side parsing and interpolation behavior.

Adapter cleanup note:

- `serial_runtime` no longer exists
- `ble_adapter` is the current board-facing adapter boundary
- `LoggableDisplay` was removed to avoid harness-only concerns leaking into core/runtime interfaces

## 3. Offline Operation

The core design premise is that the device stores a regional weather grid covering about 240 miles. Once that grid is loaded, the firmware can continue estimating local weather conditions as the vehicle moves, even if the phone no longer has a live data connection.

Each weather snapshot contains a 3 x 3 grid of anchors and forecast slots at 0, 60, and 120 minutes. The firmware combines position, time, and the stored field to estimate current local conditions. This allows the system to remain useful for roughly two hours after losing service, assuming position updates are still available.

Example scenario:

A driver leaves an area with good reception after receiving a fresh weather snapshot. Over the next two hours, the route passes through regions with poor or no cellular service. The device continues estimating local conditions from the stored field and the latest vehicle position instead of depending on fresh network weather queries.

## 4. Protocol Design

The Block 1 packet protocol is intentionally compact and strict:

- binary packet format
- little-endian encoding
- CRC-32 protection
- strict validation of header and payload semantics

Current packet types are:

- `RegionalSnapshotV1`
- `PositionUpdateV1`
- `AckV1`

The complete packet specification is implemented in code, but the Python implementation is the reference protocol implementation for this repository. The Rust parser is expected to match the Python behavior exactly when given the same bytes.

## 5. Repository Structure

```text
projectLocalWeather/
├── ARCHITECTURE_BLOCK1.md
├── CODING_GUIDELINES.md
├── PROTOCOL_STATUS.md
├── fixtures/
├── tests/
├── weather_protocol/
└── weather_protocol_rust/
```

Major directories and files:

- [`weather_protocol/`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/weather_protocol)  
  Python reference protocol implementation. This contains packet encoding, decoding, validation, deterministic fixture generation, and a human-readable packet dump tool.

- [`weather_protocol_rust/`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/weather_protocol_rust)  
  Rust firmware-side crate. This currently contains the packet parser, assembler, ingress, device state, interpolation engine, persistence, display formatter, display driver interface, BLE adapter boundary, and Rust tests.

- [`fixtures/`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/fixtures)  
  Binary packet fixtures generated by the Python reference implementation. These are used by firmware-side Rust tests to verify parser behavior against the reference implementation.

- [`tests/`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/tests)  
  Python tests for the reference protocol implementation.

- [`ARCHITECTURE_BLOCK1.md`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/ARCHITECTURE_BLOCK1.md)  
  Frozen Block 1 architecture baseline.

- [`PROTOCOL_STATUS.md`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/PROTOCOL_STATUS.md)  
  Project status tracker for implemented and unimplemented protocol-related components.

- [`CODING_GUIDELINES.md`](/Users/smith/Documents/Personal/Projects/Project Local Weather/projectLocalWeather/CODING_GUIDELINES.md)  
  Project coding and validation rules.

Both Python and Rust exist in this repository for different reasons:

- Python defines and tests the protocol truth source
- Rust implements the firmware-side behavior that must match that reference

## 6. Development Workflow

The repository is intended to develop in layers:

1. The protocol is defined and validated in Python.
2. Python generates deterministic binary fixtures.
3. The Rust firmware parser is implemented and tested against those fixtures.
4. The Rust interpolation engine is built on top of decoded packet structs.
5. Firmware runtime boundaries are integrated through `FirmwareCore` and `ble_adapter`.
6. Future work will add hardware BLE callbacks and hardware LCD transport wiring.

This workflow keeps the packet format and validation behavior stable while allowing firmware work to progress incrementally.

Block 1 persistence note:

- the firmware stores the active `RegionalSnapshotV1` and latest `PositionUpdateV1`
- on boot, it restores the newest valid persisted records and recomputes the estimate
- if a newer stored record is corrupted, restore falls back to the last good valid record
- current persistence uses a board-agnostic abstraction with an in-memory test backend
- hardware-specific flash backend wiring is still future work

## 7. Running the Python Tests

Run the Python reference implementation tests from the repository root:

```bash
python3 -m pytest
```

Regenerate deterministic binary fixtures:

```bash
python3 -m weather_protocol.fixtures
```

Inspect a packet in a human-readable form:

```bash
python3 -m weather_protocol.dump fixtures/valid_weather.bin
```

## 8. Running the Rust Tests

Run the Rust parser and interpolation tests from the Rust crate directory:

```bash
cd weather_protocol_rust
cargo test
```

These tests cover:

- parser acceptance of valid Python-generated fixtures
- parser rejection of malformed fixtures and invalid packet mutations
- interpolation behavior at representative positions and times
- confidence degradation behavior

## 9. Project Status

Current repository status:

- Python protocol reference implementation complete
- Rust packet parser complete
- Rust interpolation engine implemented
- Rust device state layer implemented
- persistence layer implemented with board-agnostic abstraction and in-memory test backend
- BLE adapter boundary implemented (`ble_adapter`)
- hardware BLE transport callbacks not yet implemented
- display driver interface implemented (hardware LCD transport not yet implemented)
- iPhone application not yet implemented

The next likely engineering areas are hardware BLE integration, hardware flash backend integration, display logic, and the iPhone application.

## 10. Design Philosophy

This project consistently favors:

- deterministic behavior
- strict validation
- minimal complexity
- predictable operation under constrained conditions

The objective is useful situational awareness in a vehicle, not perfect forecasting. When the system must choose between a more complicated model and a simpler, more defensible one, Block 1 generally prefers the simpler approach.

## 11. License

All Rights Reserved.

Copyright (C) C.T. Smith.

This repository and its contents are not licensed for reuse, redistribution, or modification without explicit permission from the author.
