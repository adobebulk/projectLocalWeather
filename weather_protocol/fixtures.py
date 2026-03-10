from pathlib import Path
import struct

from .protocol import (
    CHECKSUM_OFFSET,
    GRID_COLS,
    GRID_ROWS,
    POSITION_PACKET_SIZE,
    PRECIP_INTENSITY_HEAVY,
    PRECIP_INTENSITY_LIGHT,
    PRECIP_INTENSITY_MODERATE,
    PRECIP_INTENSITY_NONE,
    PRECIP_KIND_NONE,
    PRECIP_KIND_RAIN,
    PRECIP_KIND_SNOW,
    REGIONAL_PACKET_SIZE,
    WeatherSlot,
    crc32,
    encode_ack,
    encode_position,
    encode_regional_snapshot,
    make_regional_snapshot_metadata,
)


FIXTURE_DIR = Path(__file__).resolve().parent.parent / "fixtures"


def make_sample_weather_slots():
    anchor_slots = []
    for anchor_index in range(GRID_ROWS * GRID_COLS):
        slots = []
        for slot_index, slot_offset in enumerate((0, 60, 120)):
            precip_kind = (PRECIP_KIND_NONE, PRECIP_KIND_RAIN, PRECIP_KIND_SNOW)[slot_index]
            precip_intensity = (
                PRECIP_INTENSITY_NONE,
                PRECIP_INTENSITY_LIGHT,
                PRECIP_INTENSITY_MODERATE,
            )[slot_index]
            if anchor_index == 4 and slot_index == 2:
                precip_intensity = PRECIP_INTENSITY_HEAVY

            slots.append(
                WeatherSlot(
                    slot_offset_min=slot_offset,
                    air_temp_c_tenths=185 - (anchor_index * 3) - (slot_index * 7),
                    wind_speed_mps_tenths=45 + (anchor_index * 2) + slot_index,
                    wind_gust_mps_tenths=70 + (anchor_index * 2) + (slot_index * 2),
                    precip_prob_pct=10 + (anchor_index * 3) + (slot_index * 20),
                    precip_kind=precip_kind,
                    precip_intensity=precip_intensity,
                    reserved0=0,
                    visibility_m=12000 - (anchor_index * 150) - (slot_index * 300),
                    hazard_flags=((1 << anchor_index) if slot_index == 1 and anchor_index < 11 else 0),
                )
            )
        anchor_slots.append(tuple(slots))
    return tuple(anchor_slots)


def fixture_packets():
    metadata = make_regional_snapshot_metadata(
        field_center_lat_e5=3405223,
        field_center_lon_e5=-11824368,
        source_age_min=17,
    )
    weather_slots = make_sample_weather_slots()

    valid_position = encode_position(
        sequence=1,
        timestamp=1700000000,
        lat_e5=3405223,
        lon_e5=-11824368,
        accuracy_m=8,
        fix_timestamp=1700000005,
    )
    valid_ack = encode_ack(
        sequence=2,
        timestamp=1700000010,
        echoed_sequence=1,
        status_code=0,
        weather_ts=1700000000,
        position_ts=1700000005,
    )
    valid_weather = encode_regional_snapshot(
        sequence=3,
        timestamp=1700000020,
        metadata=metadata,
        anchor_slots=weather_slots,
    )

    bad_checksum_weather = bytearray(valid_weather)
    struct.pack_into("<I", bad_checksum_weather, CHECKSUM_OFFSET, 0x12345678)

    bad_length_position = bytearray(valid_position)
    struct.pack_into("<H", bad_length_position, 4, POSITION_PACKET_SIZE - 1)
    struct.pack_into("<I", bad_length_position, CHECKSUM_OFFSET, 0)
    struct.pack_into(
        "<I",
        bad_length_position,
        CHECKSUM_OFFSET,
        crc32(bytes(bad_length_position)),
    )

    invalid_precip_weather = bytearray(valid_weather)
    precip_probability_offset = 18 + 20 + 8
    invalid_precip_weather[precip_probability_offset] = 101
    struct.pack_into("<I", invalid_precip_weather, CHECKSUM_OFFSET, 0)
    struct.pack_into(
        "<I",
        invalid_precip_weather,
        CHECKSUM_OFFSET,
        crc32(bytes(invalid_precip_weather)),
    )

    return {
        "valid_position.bin": valid_position,
        "valid_ack.bin": valid_ack,
        "valid_weather.bin": valid_weather,
        "bad_checksum_weather.bin": bytes(bad_checksum_weather),
        "bad_length_position.bin": bytes(bad_length_position),
        "invalid_precip_weather.bin": bytes(invalid_precip_weather),
    }


def write_fixtures(output_dir: Path = FIXTURE_DIR):
    output_dir.mkdir(parents=True, exist_ok=True)
    written_paths = []
    for name, payload in fixture_packets().items():
        path = output_dir / name
        path.write_bytes(payload)
        written_paths.append(path)
    return written_paths


def main():
    for path in write_fixtures():
        print(path)


if __name__ == "__main__":
    main()
