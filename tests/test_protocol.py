from pathlib import Path
import struct

import pytest

from weather_protocol.dump import dump_packet
from weather_protocol.fixtures import fixture_packets, write_fixtures
from weather_protocol.protocol import (
    CHECKSUM_OFFSET,
    MAGIC,
    POSITION_PACKET_SIZE,
    PRECIP_KIND_UNKNOWN,
    ProtocolError,
    WeatherSlot,
    crc32,
    decode_ack,
    decode_packet,
    decode_position,
    decode_regional_snapshot,
    encode_ack,
    encode_position,
    encode_regional_snapshot,
    make_regional_snapshot_metadata,
)


def make_weather_slots():
    anchor_slots = []
    for anchor_index in range(9):
        slots = []
        for slot_index, slot_offset in enumerate((0, 60, 120)):
            slots.append(
                WeatherSlot(
                    slot_offset_min=slot_offset,
                    air_temp_c_tenths=220 - (anchor_index * 5) - (slot_index * 4),
                    wind_speed_mps_tenths=50 + anchor_index + slot_index,
                    wind_gust_mps_tenths=75 + anchor_index + (slot_index * 2),
                    precip_prob_pct=15 + (slot_index * 15),
                    precip_kind=(0, 1, PRECIP_KIND_UNKNOWN)[slot_index],
                    precip_intensity=(0, 1, 255)[slot_index],
                    reserved0=0,
                    visibility_m=14000 - (anchor_index * 100) - (slot_index * 250),
                    hazard_flags=(1 << anchor_index) if anchor_index < 11 and slot_index == 0 else 0,
                )
            )
        anchor_slots.append(tuple(slots))
    return tuple(anchor_slots)


def make_weather_packet():
    metadata = make_regional_snapshot_metadata(
        field_center_lat_e5=3405223,
        field_center_lon_e5=-11824368,
        source_age_min=11,
    )
    return encode_regional_snapshot(
        sequence=33,
        timestamp=1700000020,
        metadata=metadata,
        anchor_slots=make_weather_slots(),
    )


def recalc_checksum(packet_bytes):
    packet = bytearray(packet_bytes)
    struct.pack_into("<I", packet, CHECKSUM_OFFSET, 0)
    struct.pack_into("<I", packet, CHECKSUM_OFFSET, crc32(bytes(packet)))
    return bytes(packet)


def test_position_packet_size():
    pkt = encode_position(
        sequence=1,
        timestamp=1700000000,
        lat_e5=3405223,
        lon_e5=-11824368,
        accuracy_m=8,
        fix_timestamp=1700000000,
    )
    assert len(pkt) == POSITION_PACKET_SIZE


def test_position_round_trip_decode():
    packet = encode_position(
        sequence=7,
        timestamp=1700000000,
        lat_e5=3405223,
        lon_e5=-11824368,
        accuracy_m=8,
        fix_timestamp=1700000015,
    )

    decoded = decode_position(packet)

    assert decoded.header.magic == MAGIC
    assert decoded.header.sequence == 7
    assert decoded.lat_e5 == 3405223
    assert decoded.lon_e5 == -11824368
    assert decoded.accuracy_m == 8
    assert decoded.fix_timestamp_unix == 1700000015


def test_ack_round_trip_decode():
    packet = encode_ack(
        sequence=10,
        timestamp=1700000100,
        echoed_sequence=7,
        status_code=0,
        weather_ts=1700000000,
        position_ts=1700000015,
    )

    decoded = decode_ack(packet)

    assert decoded.header.sequence == 10
    assert decoded.echoed_sequence == 7
    assert decoded.status_code == 0
    assert decoded.active_weather_timestamp_unix == 1700000000
    assert decoded.active_position_timestamp_unix == 1700000015


def test_weather_round_trip_decode():
    packet = make_weather_packet()

    decoded = decode_regional_snapshot(packet)

    assert decoded.header.total_length == 470
    assert decoded.metadata.grid_rows == 3
    assert decoded.metadata.grid_cols == 3
    assert decoded.metadata.slot_count == 3
    assert len(decoded.anchor_slots) == 9
    assert [slot.slot_offset_min for slot in decoded.anchor_slots[4]] == [0, 60, 120]


def test_decode_packet_dispatches():
    position_packet = encode_position(
        sequence=11,
        timestamp=1700000000,
        lat_e5=3405223,
        lon_e5=-11824368,
        accuracy_m=6,
        fix_timestamp=1700000007,
    )
    weather_packet = make_weather_packet()

    assert decode_packet(position_packet).header.packet_type == 2
    assert decode_packet(weather_packet).header.packet_type == 1


def test_crc_rejection():
    packet = bytearray(make_weather_packet())
    packet[-1] ^= 0xFF

    with pytest.raises(ProtocolError, match="bad checksum"):
        decode_regional_snapshot(bytes(packet))


def test_wrong_length_rejection():
    packet = bytearray(
        encode_position(
            sequence=1,
            timestamp=1700000000,
            lat_e5=3405223,
            lon_e5=-11824368,
            accuracy_m=8,
            fix_timestamp=1700000015,
        )
    )
    struct.pack_into("<H", packet, 4, POSITION_PACKET_SIZE - 1)
    packet = bytearray(recalc_checksum(packet))

    with pytest.raises(ProtocolError, match="wrong packet length"):
        decode_position(bytes(packet))


def test_bad_magic_rejection():
    packet = bytearray(make_weather_packet())
    struct.pack_into("<H", packet, 0, 0x0000)
    packet = bytearray(recalc_checksum(packet))

    with pytest.raises(ProtocolError, match="bad magic"):
        decode_regional_snapshot(bytes(packet))


def test_bad_version_rejection():
    packet = bytearray(make_weather_packet())
    packet[2] = 9
    packet = bytearray(recalc_checksum(packet))

    with pytest.raises(ProtocolError, match="bad version"):
        decode_regional_snapshot(bytes(packet))


def test_invalid_slot_offsets_rejection():
    slots = [list(anchor) for anchor in make_weather_slots()]
    first_slot = slots[0][0]
    slots[0][0] = WeatherSlot(
        slot_offset_min=30,
        air_temp_c_tenths=first_slot.air_temp_c_tenths,
        wind_speed_mps_tenths=first_slot.wind_speed_mps_tenths,
        wind_gust_mps_tenths=first_slot.wind_gust_mps_tenths,
        precip_prob_pct=first_slot.precip_prob_pct,
        precip_kind=first_slot.precip_kind,
        precip_intensity=first_slot.precip_intensity,
        reserved0=first_slot.reserved0,
        visibility_m=first_slot.visibility_m,
        hazard_flags=first_slot.hazard_flags,
    )

    with pytest.raises(ProtocolError, match="slot offsets"):
        encode_regional_snapshot(
            sequence=33,
            timestamp=1700000020,
            metadata=make_regional_snapshot_metadata(3405223, -11824368, 11),
            anchor_slots=tuple(tuple(anchor) for anchor in slots),
        )


def test_invalid_precip_probability_rejection():
    slots = [list(anchor) for anchor in make_weather_slots()]
    first_slot = slots[0][0]
    slots[0][0] = WeatherSlot(
        slot_offset_min=first_slot.slot_offset_min,
        air_temp_c_tenths=first_slot.air_temp_c_tenths,
        wind_speed_mps_tenths=first_slot.wind_speed_mps_tenths,
        wind_gust_mps_tenths=first_slot.wind_gust_mps_tenths,
        precip_prob_pct=101,
        precip_kind=first_slot.precip_kind,
        precip_intensity=first_slot.precip_intensity,
        reserved0=first_slot.reserved0,
        visibility_m=first_slot.visibility_m,
        hazard_flags=first_slot.hazard_flags,
    )

    with pytest.raises(ProtocolError, match="precip_prob_pct"):
        encode_regional_snapshot(
            sequence=33,
            timestamp=1700000020,
            metadata=make_regional_snapshot_metadata(3405223, -11824368, 11),
            anchor_slots=tuple(tuple(anchor) for anchor in slots),
        )


def test_invalid_grid_shape_rejection():
    bad_metadata = make_regional_snapshot_metadata(
        field_center_lat_e5=3405223,
        field_center_lon_e5=-11824368,
        source_age_min=11,
    )
    bad_metadata = bad_metadata.__class__(
        field_center_lat_e5=bad_metadata.field_center_lat_e5,
        field_center_lon_e5=bad_metadata.field_center_lon_e5,
        field_width_mi=bad_metadata.field_width_mi,
        field_height_mi=bad_metadata.field_height_mi,
        grid_rows=4,
        grid_cols=bad_metadata.grid_cols,
        slot_count=bad_metadata.slot_count,
        reserved0=bad_metadata.reserved0,
        forecast_horizon_min=bad_metadata.forecast_horizon_min,
        source_age_min=bad_metadata.source_age_min,
    )

    with pytest.raises(ProtocolError, match="grid_rows"):
        encode_regional_snapshot(
            sequence=33,
            timestamp=1700000020,
            metadata=bad_metadata,
            anchor_slots=make_weather_slots(),
        )


def test_fixture_generation_and_dump(tmp_path: Path):
    written_paths = write_fixtures(tmp_path)
    names = sorted(path.name for path in written_paths)

    assert names == [
        "bad_checksum_weather.bin",
        "bad_length_position.bin",
        "invalid_precip_weather.bin",
        "valid_ack.bin",
        "valid_position.bin",
        "valid_weather.bin",
    ]

    packet_dump = dump_packet(tmp_path / "valid_weather.bin")
    assert "RegionalSnapshotV1" in packet_dump
    assert "northwest" in packet_dump


def test_fixture_packets_invalid_cases_fail_decode():
    packets = fixture_packets()

    with pytest.raises(ProtocolError, match="bad checksum"):
        decode_regional_snapshot(packets["bad_checksum_weather.bin"])

    with pytest.raises(ProtocolError, match="wrong packet length"):
        decode_position(packets["bad_length_position.bin"])

    with pytest.raises(ProtocolError, match="precip_prob_pct"):
        decode_regional_snapshot(packets["invalid_precip_weather.bin"])
