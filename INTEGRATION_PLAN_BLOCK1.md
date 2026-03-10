# Weather Computer — Block 1 Integration Plan (Embedded Rust Primary)

This plan defines the remaining work from the current state to first real hardware deployment using the embedded Rust firmware path.

## 1. Primary Runtime Pipeline

Block 1 runtime pipeline (product path):

BLE fragments  
-> runtime boundary  
-> packet assembler  
-> parser / validation  
-> ingress  
-> device state  
-> interpolation  
-> display formatter  
-> display output boundary

Persistence path:

accepted packets  
-> persistence write

Boot path:

restore weather + position  
-> recompute estimate  
-> refresh display

## 2. Primary Firmware Location

Primary deployable path:

- [`firmware_esp32/`](/Users/smith/.codex/worktrees/395b/projectLocalWeather/firmware_esp32)

This supersedes the previous bridge/Arduino-shell deployment concept.

## 3. Completed in Primary Path

- core packet/data modules recreated in `firmware_esp32`
- runtime boundary scaffold in Rust (`runtime` + `main`)
- persistence model present
- display policy implementation present
- BLE-facing API boundary shape present

## 4. Remaining Hardware Integration Work

### A. Target Toolchain Build

Produce target-compatible firmware artifacts for ESP32-S3 from `firmware_esp32`.

### B. BLE Wiring

Connect board BLE RX/TX callbacks directly to `firmware_esp32` runtime boundary.

### C. Persistence Backend Wiring

Replace in-memory persistence backend with board flash-backed implementation.

### D. Display Transport Wiring

Implement SerLCD transport using already-formatted lines from runtime.

### E. First End-to-End Device Test

Validate weather snapshot + position ingest, ACK behavior, and display output on hardware.

## 5. Practical Integration Order

1. target-toolchain compile of `firmware_esp32`
2. boot + serial logs on board
3. BLE fragment ingress on board
4. ACK transmit path on board
5. flash-backed persistence wiring
6. SerLCD output transport wiring
7. end-to-end field test with phone sender

## 6. Guardrails

- do not redesign protocol
- do not redesign weather model
- keep confidence off-wire
- keep code explicit and testable
- avoid parallel duplicate firmware paths
