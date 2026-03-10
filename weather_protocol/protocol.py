
import struct
import zlib

MAGIC = 0x5743
VERSION = 1

PACKET_WEATHER = 1
PACKET_POSITION = 2
PACKET_ACK = 3

HEADER_SIZE = 18

def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xffffffff

def build_header(packet_type, sequence, timestamp, payload_len):
    total_len = HEADER_SIZE + payload_len
    header = struct.pack(
        "<HBBHII I",
        MAGIC,
        VERSION,
        packet_type,
        total_len,
        sequence,
        timestamp,
        0
    )
    return bytearray(header)

def encode_position(sequence, timestamp, lat_e5, lon_e5, accuracy_m, fix_timestamp):
    payload = struct.pack(
        "<iiHI",
        lat_e5,
        lon_e5,
        accuracy_m,
        fix_timestamp
    )

    header = build_header(
        PACKET_POSITION,
        sequence,
        timestamp,
        len(payload)
    )

    packet = header + payload

    checksum = crc32(packet)
    struct.pack_into("<I", packet, 14, checksum)

    return bytes(packet)

def encode_ack(sequence, timestamp, echoed_sequence, status_code, weather_ts, position_ts):
    payload = struct.pack(
        "<IBIIB",
        echoed_sequence,
        status_code,
        weather_ts,
        position_ts,
        0
    )

    header = build_header(
        PACKET_ACK,
        sequence,
        timestamp,
        len(payload)
    )

    packet = header + payload

    checksum = crc32(packet)
    struct.pack_into("<I", packet, 14, checksum)

    return bytes(packet)
