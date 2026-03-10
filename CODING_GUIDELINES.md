
# Weather Computer Project — Coding Guidelines

## Purpose

This document defines coding and architectural guidelines for the Weather Computer project.

These guidelines exist to ensure:
- clarity
- maintainability
- deterministic behavior
- compatibility with constrained embedded hardware

This project is actively evolving. The guidelines represent the current Block 1 philosophy and may change as the system evolves.

When updates occur, newer instructions override older assumptions.

---

# General Philosophy

The system prioritizes:
1. deterministic behavior
2. explicit data structures
3. strict validation
4. minimal dependencies
5. readable code

Avoid clever abstractions or unnecessary complexity.

Clarity is more valuable than flexibility.

---

# Language Roles

Current planned languages:

Component | Language
--------- | --------
iPhone application | Swift
reference protocol implementation | Python
firmware | Rust

Each language has a defined responsibility.

---

# Python Role

Python acts as the protocol reference implementation.

Responsibilities:
- encode packets
- decode packets
- generate test fixtures
- simulate the phone sender
- validate packet structures

Python code should prioritize clarity over performance.

---

# Rust Role

Rust will be used for firmware packet parsing and weather interpolation.

Rust code must emphasize:
- safety
- deterministic behavior
- strict validation
- low memory usage

Avoid unnecessary external dependencies unless they clearly improve safety or reliability.

---

# Swift Role

Swift powers the iPhone companion application.

Responsibilities:
- GPS acquisition
- NOAA weather retrieval
- generation of regional weather fields
- packet transmission via BLE

---

# Protocol Design Rules

The protocol must remain:

- binary
- little-endian
- deterministic
- compact

Avoid text-based formats such as JSON.

Binary packets reduce bandwidth and simplify firmware parsing.

---

# Packet Validation Philosophy

Firmware must apply strict validation.

Invalid packets must be rejected immediately.

Examples:
- incorrect magic value
- unsupported protocol version
- incorrect packet length
- checksum mismatch
- invalid enum values
- unexpected grid sizes

Do not attempt recovery from malformed packets.

Reject them.

---

# Error Handling

Errors must be explicit and deterministic.

Good:

    if crc_invalid:
        return Error::ChecksumFailure

Bad:

    try:
        parse_packet()
    except:
        pass

---

# Data Structures

Prefer explicit structures over dynamic containers.

Example (Rust):

    struct WeatherSlot {
        temperature_tenths_c: i16,
        wind_speed_tenths_ms: u16,
        wind_gust_tenths_ms: u16,
        precip_probability_pct: u8,
        precip_kind: u8,
        precip_intensity: u8,
        visibility_m: u16,
        hazard_flags: u16,
    }

Field sizes must match the protocol exactly.

Avoid runtime resizing where possible.

---

# Naming Conventions

Use clear descriptive names.

Good:

    weather_field_age_minutes
    position_accuracy_meters

Avoid overly short names.

Bad:

    wf_age
    pos_acc

---

# Units

Protocol uses NOAA-native units.

Examples:
- temperature: tenths °C
- wind speed: tenths m/s
- visibility: meters

Conversion to imperial units should occur only in the display layer.

---

# Packet Fixtures

Python should generate deterministic fixtures including:

- valid packets
- corrupted CRC packets
- truncated packets
- invalid enum packets
- stale timestamp packets

Firmware tests should validate behavior using these fixtures.

---

# Deterministic Testing

Packet generation should produce identical binary output across runs.

If randomness is required, seed it.

Example:

    random.seed(42)

---

# Debugging Tools

Include a packet dump utility that prints:

- header fields
- packet type
- decoded slot data
- hazard flags

This tool will assist during firmware bring-up.

---

# Logging

Firmware logging should remain minimal.

Recommended logs:
- packet accepted
- packet rejected
- validation errors
- stale data warnings

Avoid verbose logging on constrained hardware.

---

# Versioning

Protocol version must increase when binary format changes.

Example:

    version = 1

Future incompatible changes:

    version = 2

Devices must reject unsupported versions.

---

# Code Review

When reviewing code check:

- protocol compatibility
- deterministic behavior
- memory usage
- error handling
- unit correctness

---

# Documentation

Every packet structure should have a human-readable table describing offsets and sizes.

Example:

Offset | Field | Size
------ | ----- | ----
0 | magic | 2 bytes
2 | version | 1 byte

Documentation must remain synchronized with the implementation.

---

# Final Principle

Favor code that is:

- boring
- explicit
- testable

Over code that is clever.
