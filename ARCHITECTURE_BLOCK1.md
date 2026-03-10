# Weather Computer — Block 1 Architecture

## Purpose

Block 1 defines the first working architecture for the Weather Computer system.

The goal is to provide **situational awareness of current weather and near-term hazards while driving**, including during periods without cellular coverage.

The system prioritizes useful approximations rather than perfect forecasting.

The device should continue producing reasonable estimates of local conditions for **up to approximately two hours after losing connectivity**.

---

# System Concept

The system operates by storing a **regional weather field** and sampling that field as the vehicle moves.

Conceptually:

regional_weather_field + current_vehicle_position → estimated_local_conditions

The weather field is periodically refreshed by the iPhone when network connectivity is available.

When connectivity is lost, the device continues estimating conditions locally.

---

# Hardware Platform

Microcontroller:

Arduino Nano ESP32

Reasons:

- compact
- simple
- integrated Bluetooth capability
- sufficient processing capability for interpolation and display

Display:

SparkFun 16x2 SerLCD RGB Qwiic character LCD

Reasons:

- simple character display
- low power
- readable in vehicle environments
- visually similar to traditional vehicle information displays

The device will be housed in a custom enclosure designed for vehicle use.

---

# Phone Companion Application

The iPhone application performs the following responsibilities:

- acquire GPS position
- retrieve weather data from NOAA / National Weather Service
- construct a regional weather field
- transmit compact binary packets to the device via BLE

The microcontroller does **not** retrieve internet weather data directly.

---

# Regional Weather Field Model

The weather field transmitted to the device is structured as a **3 × 3 grid of anchor points**.

Coverage:

240 miles across

Anchor layout:

NW   N   NE  
W    C   E  
SW   S   SE  

The grid is centered on the vehicle when the snapshot is generated.

Each anchor point contains three forecast slots:

0 minutes  
60 minutes  
120 minutes  

Total forecast horizon:

2 hours

---

# Offline Operation Model

Position updates continue even when the phone has no cellular connectivity.

Expected behavior:

- phone sends weather field snapshot
- phone periodically sends position updates (~10 minutes)
- device recomputes estimated local conditions as the vehicle moves

This allows the device to maintain weather awareness while driving through areas without coverage.

Example scenario:

Driver leaves a gas station with fresh weather data.  
Cell service is lost for two hours while driving ~120 miles.  
The device continues estimating local conditions using the stored regional field and updated GPS positions.

---

# Packet Communication Protocol

The iPhone sends **binary packets** to the device.

Protocol characteristics:

- binary format
- little-endian encoding
- CRC-32 integrity checking
- strict validation

Packet types:

RegionalSnapshotV1  
PositionUpdateV1  
AckV1  

Confidence values are **not transmitted in packets**.

Confidence is computed locally on the device.

---

# Device Responsibilities

The device must:

- receive and validate packets
- store the active weather field
- store the most recent vehicle position
- recompute estimated local weather conditions
- update the display with relevant information

---

# iPhone Responsibilities

The phone must:

- fetch NOAA weather data
- reduce the data to the regional grid model
- transmit compact packets to the device
- send periodic position updates

---

# Development Strategy

Block 1 development proceeds in the following order:

1. Python protocol reference implementation  
2. Rust firmware packet parser  
3. Weather interpolation engine  
4. Bluetooth communication layer  
5. Device state machine  
6. Display rendering  
7. iPhone application

Each stage should be validated before moving to the next.

---

# Design Philosophy

The system prioritizes:

- deterministic behavior
- strict validation
- minimal complexity
- predictable operation under constrained conditions

When in doubt, prefer simple and explicit implementations.

---
