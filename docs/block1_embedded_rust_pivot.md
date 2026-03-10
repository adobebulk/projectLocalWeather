# Block 1.0 Embedded Rust Pivot

This document records the Block 1.0 deployment pivot:

- primary deployment path is now embedded Rust firmware
- location: `firmware_esp32/`
- target hardware class: ESP32-S3 / Arduino Nano ESP32

Superseded as primary path:

- Arduino C++ deployable shell strategy
- Rust↔C++ bridge / FFI / ABI-first deployment approach

The protocol, weather model, display policy, and runtime behavior are unchanged by this pivot.
