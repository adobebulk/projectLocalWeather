# Weather Computer — Block 1 Hardware Integration Plan

This document captures the remaining Block 1 hardware integration work now that the core software layers are implemented.

It is intended as an implementation guide for firmware engineers integrating the existing software stack onto target hardware.

## 1. Block 1 System Overview

Block 1 runtime data path (software pipeline):

BLE fragments  
→ `BleAdapter`  
→ `FirmwareCore`  
→ `PacketAssembler`  
→ `PacketIngress`  
→ Parser  
→ `DeviceState`  
→ Interpolation  
→ Display Formatter  
→ `TextDisplay`

Persistence path:

accepted packets  
→ persistence write

boot  
→ persistence restore  
→ recompute estimate  
→ display refresh

## 2. Completed Software Layers

The following software layers are already implemented and tested:

- Parser: validates header/payload structure, packet type, length, version, magic, and CRC; decodes `RegionalSnapshotV1`, `PositionUpdateV1`, and `AckV1`.
- Packet Assembler: accepts transport fragments, finds packet start, uses header length, and emits complete packet buffers.
- Packet Ingress: routes complete packets through parser and state updates, and produces accepted/rejected ACK responses.
- Device State: stores active weather snapshot and latest position update, tracks update timestamps, and recomputes current estimate.
- Interpolation Engine: performs spatial/temporal interpolation and local confidence calculation from weather field + position + current time.
- Persistence Abstraction: stores/restores weather and position using validity metadata and CRC with fallback to last known good record.
- Display Formatter: deterministically converts estimated conditions into Block 1 16x2 display lines.
- Display Driver Interface: `TextDisplay` boundary for writing already formatted lines to a display implementation.
- BLE Adapter Boundary: `ble_adapter` receives board BLE fragments, forwards into `FirmwareCore`, and exposes pending ACK bytes.
- Firmware Core: central runtime integration layer coordinating assembler, ingress, state updates, interpolation, persistence writes, and display refresh.

## 3. Remaining Hardware Integration Work

### BLE integration

Implement real Nano ESP32 BLE receive callbacks that pass incoming data to:

`BleAdapter::on_rx_fragment(...)`

### Flash persistence backend

Implement a board-specific non-volatile storage backend for the existing persistence abstraction.

The backend should replace the in-memory test backend while preserving existing validity, CRC, and fallback behavior.

### SerLCD driver

Implement a hardware `TextDisplay` implementation for:

SparkFun 16x2 SerLCD RGB Qwiic

This driver should only render lines supplied by the display formatter path.

### Board runtime loop

Create a thin firmware loop that coordinates:

boot  
→ `restore_on_boot()`

BLE fragment arrives  
→ `BleAdapter::on_rx_fragment(...)`

if adapter has pending ACK  
→ send ACK over BLE

periodically  
→ write current display lines to LCD

### iPhone sender (future work)

Outside this firmware repository, the iPhone companion will:

- fetch NOAA weather data
- build protocol packets
- transmit packets via BLE

## 4. Integration Order

Recommended order for remaining Block 1 hardware integration:

1. serial console bring-up
2. minimal firmware loop
3. BLE receive path
4. persistence backend
5. LCD driver
6. end-to-end device test

## 5. Firmware Runtime Example

```rust
loop {
    if ble_fragment_received {
        adapter.on_rx_fragment(bytes, now);
    }

    if let Some(ack) = adapter.take_pending_ack() {
        send_ble_ack(ack);
    }

    if let Some(lines) = adapter.current_display_lines() {
        display.write_lines(lines);
    }
}
```

## 6. Design Philosophy

Block 1 integration follows these architecture principles:

- protocol logic is transport-agnostic
- firmware core is platform-independent
- BLE adapter is a thin boundary layer
- display formatting is deterministic
- persistence guarantees power-loss resilience
