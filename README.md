
Weather Protocol Reference Implementation (Block 1)

This repository contains a Python reference implementation for the
Weather Computer Block 1 packet protocol.

Packet Types
------------
RegionalSnapshotV1 (future expansion)
PositionUpdateV1
AckV1

Key Rules
---------
Binary protocol
Little-endian encoding
CRC32 checksum
Magic value: 0x5743

Usage
-----
Run tests:

    pip install pytest
    pytest
