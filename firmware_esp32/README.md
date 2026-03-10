# firmware_esp32 (Primary Block 1.0 Firmware Path)

This directory is the primary product firmware path for Block 1.0.

Target hardware class:

- ESP32-S3 / Arduino Nano ESP32

This firmware crate contains the runtime architecture used by the product path:

- packet assembler
- packet parser/validation
- ingress
- device state
- interpolation
- persistence model
- display formatter
- display output boundary
- BLE-facing runtime boundary
- boot/runtime loop scaffold

## Status

This path is intentionally based on the validated Block 1 logic and is now the deployment-oriented default.

The previous Rust↔Arduino bridge/ABI path is superseded for Block 1.0 and should be treated as legacy transition material.
