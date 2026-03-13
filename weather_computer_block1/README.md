# Local Weather Computer — Block 1 Firmware

This firmware runs on an Arduino Nano ESP32 and provides offline weather situational awareness while driving. The device stores a regional weather field transmitted from a phone over BLE and interpolates local conditions as the vehicle moves, allowing useful weather awareness even when cellular connectivity is lost.

# System Overview

The firmware maintains a local weather model on the device rather than storing a single forecast point. The phone periodically downloads weather data, constructs a regional field, and sends that field plus vehicle position updates to the device over BLE. The device keeps the latest field and position in memory, restores them after reboot when available, and recomputes a local estimate for display.

The regional weather field is a 3×3 anchor grid. Each anchor contains three forecast slots at 0, 60, and 120 minutes. The full grid covers roughly 240 miles across, or about a 120 mile radius around the field center. The phone periodically sends:

- regional weather snapshots
- vehicle GPS position updates

The device performs:

- spatial interpolation across the grid
- temporal interpolation across forecast slots
- hazard interpretation
- compact display rendering

The phone performs:

- internet access
- weather download
- grid construction

The operational goal is useful weather awareness for roughly two hours without network connectivity.

# Hardware Platform

## Microcontroller

Arduino Nano ESP32 (ESP32-S3)

Reasons:

- integrated BLE
- sufficient RAM for weather grid
- simple development environment

## Display

SparkFun 16x2 SerLCD RGB Qwiic character LCD.

Connected via I²C.

Typical wiring:

```text
Nano ESP32      SerLCD
SDA (Qwiic) --> SDA
SCL (Qwiic) --> SCL
3.3V        --> VCC
GND         --> GND
```

Default display I²C address:

`0x72`

# Firmware Architecture

Runtime pipeline:

```text
BLE Transport
      ↓
Packet Assembler
      ↓
Protocol Parser
      ↓
Ingress Router
      ↓
Device State
      ↓
Interpolation Engine
      ↓
Display Formatter
      ↓
LCD Driver
```

Module descriptions:

`BLE Transport`  
Handles BLE connection and characteristic reads/writes.

`Packet Assembler`  
Accumulates BLE fragments into complete protocol packets.

`Protocol Parser`  
Validates packet structure and CRC.

`Ingress Router`  
Updates device state from validated packets.

`Device State`  
Stores latest position, latest weather snapshot, and the computed estimate.

`Interpolation Engine`  
Computes local weather conditions from the regional grid.

`Display Formatter`  
Converts the estimate into the 16×2 LCD layout.

`Persistence`  
Stores weather and position in ESP32 NVS so the device can restore state after power loss.

# BLE Protocol

BLE service layout.

Service UUID  
`19B10010-E8F2-537E-4F6C-D104768A1214`

RX Characteristic (Write)  
`19B10011-E8F2-537E-4F6C-D104768A1214`

Used for incoming protocol packets.

TX Characteristic (Notify)  
`19B10012-E8F2-537E-4F6C-D104768A1214`

Used for acknowledgements.

# Packet Types

## PositionUpdateV1

Contains:

- latitude
- longitude
- position accuracy
- timestamp

Packet size:

`32 bytes`

## RegionalSnapshotV1

Contains:

- weather field metadata
- 3×3 anchor grid
- 3 forecast slots per anchor

Packet size:

`470 bytes`

## AckV1

Device acknowledgement packet.

Packet size:

`32 bytes`

# Display Format

## Line 1

Compact coded strip:

`visibility → phenomenon → wind`

Example:

`V10 TS W6G7`

Rules:

- only one phenomenon displayed
- deterministic truncation
- gust dropped first if space required

Visibility codes:

`V10 V5 V2 VL`

Phenomena priority:

`TS IC SN RA FG SM HZ MX`

## Line 2

Interpretation plus confidence.

Example:

`THUNDER C95%`

# Persistence

Weather and position are stored in ESP32 NVS.

Two-slot redundancy scheme:

`wx0 / wx1` → weather snapshots  
`ps0 / ps1` → position updates

Newest valid generation is selected during restore.

This allows the device to:

- reboot without losing weather awareness
- recompute the estimate immediately after boot

# Development Environment

Tools required:

- Arduino IDE
- ESP32 board package

Board selection:

`Arduino Nano ESP32`

Libraries used:

- SparkFun SerLCD
- ESP32 BLE library
- Wire
- Preferences

# Example Serial Output

Example boot log:

```text
BOOT: Weather Computer Block 1.0
I2C: init OK
LCD: init success
BLE: advertising as WeatherComputer
PERSIST: weather restore success
PERSIST: position restore success
ESTIMATE: recompute start
ESTIMATE: success
DISPLAY: runtime update success
BOOT: complete
```

# Repository Layout

```text
weather_computer_block1/

boot.cpp
ble_transport.cpp
packet_assembler.cpp
protocol_parser.cpp
ingress_router.cpp
interpolation.cpp
display_formatter.cpp
display_driver.cpp
persistence.cpp
device_state.cpp
```

# Future Work

Possible future improvements:

- phone app sender implementation
- expanded hazard interpretation
- improved display formatting
- additional validation and field testing

# License

Copyright (c) C.T. Smith  
All Rights Reserved.

This repository and its contents are proprietary. Redistribution, modification, or commercial use without explicit written permission from the author is prohibited.
