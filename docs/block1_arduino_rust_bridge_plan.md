# Block 1.0 Arduino-to-Rust Bridge Plan

## 1. Purpose

Block 1.0 uses a thin Arduino/Nano shell with the existing Rust core so platform wiring stays simple while protocol/runtime logic remains centralized, testable, and deterministic.

This avoids two high-risk paths:

- full Rust-on-ESP migration in Block 1.0
- rewriting validated Rust core logic in Arduino C++

## 2. Responsibilities Split

Arduino/Nano shell owns:

- serial initialization and logging
- BLE stack setup and callback registration
- unix timestamp source
- flash backend hookup (when ready)
- LCD transport hookup (later)
- calling bridge boundary functions

Rust core owns:

- packet assembly
- parser and validation
- packet ingress routing
- device state
- interpolation
- persistence logic and record validation rules
- display formatting
- ACK payload generation semantics

## 3. Boundary API Shape

The Arduino shell should use a minimal boundary equivalent to the existing `BleAdapter` surface:

- `new(backend)`  
  Construct runtime boundary with persistence backend.
- `restore_on_boot(now_unix)`  
  Restore persisted weather/position and recompute estimate.
- `on_rx_fragment(fragment_bytes, now_unix)`  
  Push BLE fragment bytes into core pipeline.
- `take_pending_ack() -> Option<Vec<u8>>`  
  Fetch next ACK bytes for BLE TX (if any).
- `current_display_lines() -> Option<DisplayLines>`  
  Fetch latest formatted 16x2 lines.

No protocol decisions should be reimplemented in the shell.

## 4. Data Flow

Ingress flow:

BLE RX callback  
-> read received bytes  
-> call `on_rx_fragment(...)`  
-> core assembles/parses/routes/updates state

ACK flow:

after fragment processing  
-> call `take_pending_ack()`  
-> if present, shell transmits bytes on BLE TX/notify characteristic

Display flow:

after fragment processing (or periodic loop tick)  
-> call `current_display_lines()`  
-> if present, shell prints to serial now, then later forwards to LCD transport

## 5. Persistence Integration

Block 1.0 keeps persistence logic in Rust and only swaps backend wiring in shell integration:

- current bring-up backend: in-memory backend
- future board backend: flash-backed read/write hooks

Shell-side flash backend requirements:

- implement slot read/write hooks expected by Rust persistence abstraction
- preserve write/commit ordering so interrupted writes do not replace last good record
- keep record validation, CRC checks, and fallback-to-last-good decisions inside Rust logic

## 6. LCD Integration

Block 1.0 LCD integration stays transport-only on Arduino side:

- shell obtains `DisplayLines` from Rust boundary
- shell sends line1/line2 to SparkFun 16x2 SerLCD transport
- shell does not truncate, reword, or reinterpret lines

During BLE bring-up, serial prints are the temporary sink for these lines.

## 7. Integration Order

1. serial boot shell
2. BLE RX callback path to Rust boundary
3. serial-visible display output and ACK logging
4. flash backend hookup
5. LCD hookup

## 8. Risks / Constraints

- FFI/bridge complexity: keep boundary narrow and byte-oriented.
- Thin-shell discipline: avoid business logic in Arduino layer.
- Logic duplication risk: do not replicate parse/validation/display rules outside Rust.
- Protocol ownership: keep protocol and semantic validation behavior in Rust (aligned with Python truth source).

