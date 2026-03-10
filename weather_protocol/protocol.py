from dataclasses import dataclass
import struct
import zlib
from typing import Dict, Iterable, List, Sequence, Tuple, Union


MAGIC = 0x5743
VERSION = 1

PACKET_TYPE_REGIONAL_SNAPSHOT_V1 = 1
PACKET_TYPE_POSITION_UPDATE_V1 = 2
PACKET_TYPE_ACK_V1 = 3

STATUS_ACCEPTED = 0
STATUS_BAD_MAGIC = 1
STATUS_UNSUPPORTED_VERSION = 2
STATUS_WRONG_LENGTH = 3
STATUS_BAD_CHECKSUM = 4
STATUS_UNSUPPORTED_PACKET_TYPE = 5
STATUS_SEMANTIC_VALIDATION_FAILED = 6
STATUS_STALE_OR_REPLAYED_SEQUENCE = 7
STATUS_STORAGE_FAILURE = 8
STATUS_INTERNAL_BUSY = 9

PRECIP_KIND_NONE = 0
PRECIP_KIND_RAIN = 1
PRECIP_KIND_SNOW = 2
PRECIP_KIND_SLEET = 3
PRECIP_KIND_FREEZING_RAIN = 4
PRECIP_KIND_HAIL = 5
PRECIP_KIND_MIXED = 6
PRECIP_KIND_UNKNOWN = 255

PRECIP_INTENSITY_NONE = 0
PRECIP_INTENSITY_LIGHT = 1
PRECIP_INTENSITY_MODERATE = 2
PRECIP_INTENSITY_HEAVY = 3
PRECIP_INTENSITY_SEVERE = 4
PRECIP_INTENSITY_UNKNOWN = 255

FIELD_WIDTH_MI = 240
FIELD_HEIGHT_MI = 240
GRID_ROWS = 3
GRID_COLS = 3
SLOT_COUNT = 3
FORECAST_HORIZON_MIN = 120

HEADER_FORMAT = "<HBBHIII"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)

POSITION_PAYLOAD_FORMAT = "<iiHI"
POSITION_PAYLOAD_SIZE = struct.calcsize(POSITION_PAYLOAD_FORMAT)
POSITION_PACKET_SIZE = HEADER_SIZE + POSITION_PAYLOAD_SIZE

ACK_PAYLOAD_FORMAT = "<IBIIB"
ACK_PAYLOAD_SIZE = struct.calcsize(ACK_PAYLOAD_FORMAT)
ACK_PACKET_SIZE = HEADER_SIZE + ACK_PAYLOAD_SIZE

REGIONAL_METADATA_FORMAT = "<iiHHBBBBHH"
REGIONAL_METADATA_SIZE = struct.calcsize(REGIONAL_METADATA_FORMAT)
WEATHER_SLOT_FORMAT = "<HhHHBBBBHH"
WEATHER_SLOT_SIZE = struct.calcsize(WEATHER_SLOT_FORMAT)
ANCHOR_COUNT = 9
REGIONAL_PACKET_SIZE = 470

CHECKSUM_OFFSET = HEADER_SIZE - 4

EXPECTED_SLOT_OFFSETS = (0, 60, 120)
ANCHOR_NAMES = (
    "northwest",
    "north",
    "northeast",
    "west",
    "center",
    "east",
    "southwest",
    "south",
    "southeast",
)

PRECIP_KIND_NAMES = {
    PRECIP_KIND_NONE: "none",
    PRECIP_KIND_RAIN: "rain",
    PRECIP_KIND_SNOW: "snow",
    PRECIP_KIND_SLEET: "sleet",
    PRECIP_KIND_FREEZING_RAIN: "freezing_rain",
    PRECIP_KIND_HAIL: "hail",
    PRECIP_KIND_MIXED: "mixed",
    PRECIP_KIND_UNKNOWN: "unknown",
}

PRECIP_INTENSITY_NAMES = {
    PRECIP_INTENSITY_NONE: "none",
    PRECIP_INTENSITY_LIGHT: "light",
    PRECIP_INTENSITY_MODERATE: "moderate",
    PRECIP_INTENSITY_HEAVY: "heavy",
    PRECIP_INTENSITY_SEVERE: "severe",
    PRECIP_INTENSITY_UNKNOWN: "unknown",
}

STATUS_NAMES = {
    STATUS_ACCEPTED: "accepted",
    STATUS_BAD_MAGIC: "bad_magic",
    STATUS_UNSUPPORTED_VERSION: "unsupported_version",
    STATUS_WRONG_LENGTH: "wrong_length",
    STATUS_BAD_CHECKSUM: "bad_checksum",
    STATUS_UNSUPPORTED_PACKET_TYPE: "unsupported_packet_type",
    STATUS_SEMANTIC_VALIDATION_FAILED: "semantic_validation_failed",
    STATUS_STALE_OR_REPLAYED_SEQUENCE: "stale_or_replayed_sequence",
    STATUS_STORAGE_FAILURE: "storage_failure",
    STATUS_INTERNAL_BUSY: "internal_busy",
}

HAZARD_FLAG_NAMES = (
    "thunder_risk",
    "severe_thunderstorm_risk",
    "hail_risk",
    "strong_wind",
    "poor_visibility",
    "freezing_surface_risk",
    "heavy_precipitation",
    "tornado_watch_present",
    "stale_weather_field",
    "stale_position",
    "outside_field_degraded_confidence",
)


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class PacketHeader:
    magic: int
    version: int
    packet_type: int
    total_length: int
    sequence: int
    timestamp_unix: int
    checksum_crc32: int


@dataclass(frozen=True)
class PositionUpdateV1:
    header: PacketHeader
    lat_e5: int
    lon_e5: int
    accuracy_m: int
    fix_timestamp_unix: int


@dataclass(frozen=True)
class AckV1:
    header: PacketHeader
    echoed_sequence: int
    status_code: int
    active_weather_timestamp_unix: int
    active_position_timestamp_unix: int
    reserved: int = 0


@dataclass(frozen=True)
class RegionalSnapshotMetadataV1:
    field_center_lat_e5: int
    field_center_lon_e5: int
    field_width_mi: int
    field_height_mi: int
    grid_rows: int
    grid_cols: int
    slot_count: int
    reserved0: int
    forecast_horizon_min: int
    source_age_min: int


@dataclass(frozen=True)
class WeatherSlot:
    slot_offset_min: int
    air_temp_c_tenths: int
    wind_speed_mps_tenths: int
    wind_gust_mps_tenths: int
    precip_prob_pct: int
    precip_kind: int
    precip_intensity: int
    reserved0: int
    visibility_m: int
    hazard_flags: int


@dataclass(frozen=True)
class RegionalSnapshotV1:
    header: PacketHeader
    metadata: RegionalSnapshotMetadataV1
    anchor_slots: Tuple[Tuple[WeatherSlot, ...], ...]


DecodedPacket = Union[PositionUpdateV1, AckV1, RegionalSnapshotV1]


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def crc32_with_zeroed_checksum(packet: bytes) -> int:
    mutable_packet = bytearray(packet)
    zero_checksum_field(mutable_packet)
    return crc32(bytes(mutable_packet))


def zero_checksum_field(packet: bytearray) -> None:
    struct.pack_into("<I", packet, CHECKSUM_OFFSET, 0)


def decode_header(packet: bytes) -> PacketHeader:
    if len(packet) < HEADER_SIZE:
        raise ProtocolError(
            "packet too short for header: expected at least %d bytes, got %d"
            % (HEADER_SIZE, len(packet))
        )

    return PacketHeader(*struct.unpack_from(HEADER_FORMAT, packet, 0))


def validate_header_fields(header: PacketHeader) -> None:
    if header.magic != MAGIC:
        raise ProtocolError(
            "bad magic: expected 0x%04X, got 0x%04X" % (MAGIC, header.magic)
        )
    if header.version != VERSION:
        raise ProtocolError(
            "bad version: expected %d, got %d" % (VERSION, header.version)
        )
    if header.packet_type not in (
        PACKET_TYPE_REGIONAL_SNAPSHOT_V1,
        PACKET_TYPE_POSITION_UPDATE_V1,
        PACKET_TYPE_ACK_V1,
    ):
        raise ProtocolError("unsupported packet type: %d" % header.packet_type)


def validate_total_length(packet: bytes, header: PacketHeader, expected_length: int) -> None:
    if header.total_length != expected_length:
        raise ProtocolError(
            "wrong packet length in header: expected %d, got %d"
            % (expected_length, header.total_length)
        )
    if len(packet) != expected_length:
        raise ProtocolError(
            "wrong packet byte length: expected %d, got %d"
            % (expected_length, len(packet))
        )


def validate_checksum(packet: bytes, header: PacketHeader) -> None:
    expected_checksum = crc32_with_zeroed_checksum(packet)
    if header.checksum_crc32 != expected_checksum:
        raise ProtocolError(
            "bad checksum: expected 0x%08X, got 0x%08X"
            % (expected_checksum, header.checksum_crc32)
        )


def validate_latitude_e5(lat_e5: int) -> None:
    if not (-9000000 <= lat_e5 <= 9000000):
        raise ProtocolError("latitude out of range: %d" % lat_e5)


def validate_longitude_e5(lon_e5: int) -> None:
    if not (-18000000 <= lon_e5 <= 18000000):
        raise ProtocolError("longitude out of range: %d" % lon_e5)


def validate_position_fields(lat_e5: int, lon_e5: int, accuracy_m: int) -> None:
    validate_latitude_e5(lat_e5)
    validate_longitude_e5(lon_e5)
    if accuracy_m <= 0:
        raise ProtocolError("accuracy_m must be greater than zero")


def validate_status_code(status_code: int) -> None:
    if status_code not in STATUS_NAMES:
        raise ProtocolError("unsupported status code: %d" % status_code)


def validate_precip_probability(precip_prob_pct: int) -> None:
    if not (0 <= precip_prob_pct <= 100):
        raise ProtocolError("precip_prob_pct out of range: %d" % precip_prob_pct)


def validate_precip_kind(precip_kind: int) -> None:
    if precip_kind not in PRECIP_KIND_NAMES:
        raise ProtocolError("unsupported precip_kind: %d" % precip_kind)


def validate_precip_intensity(precip_intensity: int) -> None:
    if precip_intensity not in PRECIP_INTENSITY_NAMES:
        raise ProtocolError("unsupported precip_intensity: %d" % precip_intensity)


def validate_weather_slot(slot: WeatherSlot) -> None:
    validate_precip_probability(slot.precip_prob_pct)
    validate_precip_kind(slot.precip_kind)
    validate_precip_intensity(slot.precip_intensity)
    if slot.reserved0 != 0:
        raise ProtocolError("weather slot reserved0 must be zero")


def validate_regional_metadata(metadata: RegionalSnapshotMetadataV1) -> None:
    validate_latitude_e5(metadata.field_center_lat_e5)
    validate_longitude_e5(metadata.field_center_lon_e5)
    if metadata.field_width_mi != FIELD_WIDTH_MI:
        raise ProtocolError("field_width_mi must be %d" % FIELD_WIDTH_MI)
    if metadata.field_height_mi != FIELD_HEIGHT_MI:
        raise ProtocolError("field_height_mi must be %d" % FIELD_HEIGHT_MI)
    if metadata.grid_rows != GRID_ROWS:
        raise ProtocolError("grid_rows must be %d" % GRID_ROWS)
    if metadata.grid_cols != GRID_COLS:
        raise ProtocolError("grid_cols must be %d" % GRID_COLS)
    if metadata.slot_count != SLOT_COUNT:
        raise ProtocolError("slot_count must be %d" % SLOT_COUNT)
    if metadata.reserved0 != 0:
        raise ProtocolError("regional metadata reserved0 must be zero")
    if metadata.forecast_horizon_min != FORECAST_HORIZON_MIN:
        raise ProtocolError(
            "forecast_horizon_min must be %d" % FORECAST_HORIZON_MIN
        )


def validate_anchor_slots(anchor_slots: Sequence[Sequence[WeatherSlot]]) -> None:
    if len(anchor_slots) != ANCHOR_COUNT:
        raise ProtocolError("expected %d anchors, got %d" % (ANCHOR_COUNT, len(anchor_slots)))

    for anchor_index, slots in enumerate(anchor_slots):
        if len(slots) != SLOT_COUNT:
            raise ProtocolError(
                "anchor %d must contain %d slots" % (anchor_index, SLOT_COUNT)
            )
        actual_offsets = tuple(slot.slot_offset_min for slot in slots)
        if actual_offsets != EXPECTED_SLOT_OFFSETS:
            raise ProtocolError(
                "anchor %d slot offsets must be %s, got %s"
                % (anchor_index, EXPECTED_SLOT_OFFSETS, actual_offsets)
            )
        for slot in slots:
            validate_weather_slot(slot)


def build_header(packet_type: int, sequence: int, timestamp_unix: int, payload_length: int) -> bytearray:
    total_length = HEADER_SIZE + payload_length
    return bytearray(
        struct.pack(
            HEADER_FORMAT,
            MAGIC,
            VERSION,
            packet_type,
            total_length,
            sequence,
            timestamp_unix,
            0,
        )
    )


def finalize_packet(header: bytearray, payload: bytes) -> bytes:
    packet = bytearray(header)
    packet.extend(payload)
    checksum = crc32(bytes(packet))
    struct.pack_into("<I", packet, CHECKSUM_OFFSET, checksum)
    return bytes(packet)


def encode_position(
    sequence: int,
    timestamp: int,
    lat_e5: int,
    lon_e5: int,
    accuracy_m: int,
    fix_timestamp: int,
) -> bytes:
    validate_position_fields(lat_e5, lon_e5, accuracy_m)
    payload = struct.pack(
        POSITION_PAYLOAD_FORMAT,
        lat_e5,
        lon_e5,
        accuracy_m,
        fix_timestamp,
    )
    return finalize_packet(
        build_header(PACKET_TYPE_POSITION_UPDATE_V1, sequence, timestamp, len(payload)),
        payload,
    )


def encode_ack(
    sequence: int,
    timestamp: int,
    echoed_sequence: int,
    status_code: int,
    weather_ts: int,
    position_ts: int,
) -> bytes:
    validate_status_code(status_code)
    payload = struct.pack(
        ACK_PAYLOAD_FORMAT,
        echoed_sequence,
        status_code,
        weather_ts,
        position_ts,
        0,
    )
    return finalize_packet(
        build_header(PACKET_TYPE_ACK_V1, sequence, timestamp, len(payload)),
        payload,
    )


def encode_regional_snapshot(
    sequence: int,
    timestamp: int,
    metadata: RegionalSnapshotMetadataV1,
    anchor_slots: Sequence[Sequence[WeatherSlot]],
) -> bytes:
    validate_regional_metadata(metadata)
    validate_anchor_slots(anchor_slots)

    payload = bytearray(
        struct.pack(
            REGIONAL_METADATA_FORMAT,
            metadata.field_center_lat_e5,
            metadata.field_center_lon_e5,
            metadata.field_width_mi,
            metadata.field_height_mi,
            metadata.grid_rows,
            metadata.grid_cols,
            metadata.slot_count,
            metadata.reserved0,
            metadata.forecast_horizon_min,
            metadata.source_age_min,
        )
    )

    for slots in anchor_slots:
        for slot in slots:
            payload.extend(
                struct.pack(
                    WEATHER_SLOT_FORMAT,
                    slot.slot_offset_min,
                    slot.air_temp_c_tenths,
                    slot.wind_speed_mps_tenths,
                    slot.wind_gust_mps_tenths,
                    slot.precip_prob_pct,
                    slot.precip_kind,
                    slot.precip_intensity,
                    slot.reserved0,
                    slot.visibility_m,
                    slot.hazard_flags,
                )
            )

    if len(payload) != REGIONAL_PACKET_SIZE - HEADER_SIZE:
        raise ProtocolError(
            "regional snapshot payload length must be %d, got %d"
            % (REGIONAL_PACKET_SIZE - HEADER_SIZE, len(payload))
        )

    return finalize_packet(
        build_header(PACKET_TYPE_REGIONAL_SNAPSHOT_V1, sequence, timestamp, len(payload)),
        bytes(payload),
    )


def decode_position(packet: bytes) -> PositionUpdateV1:
    header = decode_header(packet)
    validate_header_fields(header)
    if header.packet_type != PACKET_TYPE_POSITION_UPDATE_V1:
        raise ProtocolError("packet is not PositionUpdateV1")
    validate_total_length(packet, header, POSITION_PACKET_SIZE)
    validate_checksum(packet, header)

    lat_e5, lon_e5, accuracy_m, fix_timestamp_unix = struct.unpack_from(
        POSITION_PAYLOAD_FORMAT, packet, HEADER_SIZE
    )
    validate_position_fields(lat_e5, lon_e5, accuracy_m)

    return PositionUpdateV1(
        header=header,
        lat_e5=lat_e5,
        lon_e5=lon_e5,
        accuracy_m=accuracy_m,
        fix_timestamp_unix=fix_timestamp_unix,
    )


def decode_ack(packet: bytes) -> AckV1:
    header = decode_header(packet)
    validate_header_fields(header)
    if header.packet_type != PACKET_TYPE_ACK_V1:
        raise ProtocolError("packet is not AckV1")
    validate_total_length(packet, header, ACK_PACKET_SIZE)
    validate_checksum(packet, header)

    (
        echoed_sequence,
        status_code,
        active_weather_timestamp_unix,
        active_position_timestamp_unix,
        reserved,
    ) = struct.unpack_from(ACK_PAYLOAD_FORMAT, packet, HEADER_SIZE)
    validate_status_code(status_code)
    if reserved != 0:
        raise ProtocolError("ack reserved byte must be zero")

    return AckV1(
        header=header,
        echoed_sequence=echoed_sequence,
        status_code=status_code,
        active_weather_timestamp_unix=active_weather_timestamp_unix,
        active_position_timestamp_unix=active_position_timestamp_unix,
        reserved=reserved,
    )


def decode_regional_snapshot(packet: bytes) -> RegionalSnapshotV1:
    header = decode_header(packet)
    validate_header_fields(header)
    if header.packet_type != PACKET_TYPE_REGIONAL_SNAPSHOT_V1:
        raise ProtocolError("packet is not RegionalSnapshotV1")
    validate_total_length(packet, header, REGIONAL_PACKET_SIZE)
    validate_checksum(packet, header)

    metadata_values = struct.unpack_from(REGIONAL_METADATA_FORMAT, packet, HEADER_SIZE)
    metadata = RegionalSnapshotMetadataV1(*metadata_values)
    validate_regional_metadata(metadata)

    anchor_slots: List[Tuple[WeatherSlot, ...]] = []
    slot_offset = HEADER_SIZE + REGIONAL_METADATA_SIZE
    for _anchor_index in range(ANCHOR_COUNT):
        slots: List[WeatherSlot] = []
        for _slot_index in range(SLOT_COUNT):
            slot_values = struct.unpack_from(WEATHER_SLOT_FORMAT, packet, slot_offset)
            slot = WeatherSlot(*slot_values)
            validate_weather_slot(slot)
            slots.append(slot)
            slot_offset += WEATHER_SLOT_SIZE
        anchor_slots.append(tuple(slots))

    validate_anchor_slots(anchor_slots)

    return RegionalSnapshotV1(
        header=header,
        metadata=metadata,
        anchor_slots=tuple(anchor_slots),
    )


def decode_packet(packet: bytes) -> DecodedPacket:
    header = decode_header(packet)
    if header.packet_type == PACKET_TYPE_POSITION_UPDATE_V1:
        return decode_position(packet)
    if header.packet_type == PACKET_TYPE_ACK_V1:
        return decode_ack(packet)
    if header.packet_type == PACKET_TYPE_REGIONAL_SNAPSHOT_V1:
        return decode_regional_snapshot(packet)

    validate_header_fields(header)
    raise ProtocolError("unsupported packet type: %d" % header.packet_type)


def make_regional_snapshot_metadata(
    field_center_lat_e5: int,
    field_center_lon_e5: int,
    source_age_min: int,
) -> RegionalSnapshotMetadataV1:
    return RegionalSnapshotMetadataV1(
        field_center_lat_e5=field_center_lat_e5,
        field_center_lon_e5=field_center_lon_e5,
        field_width_mi=FIELD_WIDTH_MI,
        field_height_mi=FIELD_HEIGHT_MI,
        grid_rows=GRID_ROWS,
        grid_cols=GRID_COLS,
        slot_count=SLOT_COUNT,
        reserved0=0,
        forecast_horizon_min=FORECAST_HORIZON_MIN,
        source_age_min=source_age_min,
    )


def iter_hazard_flag_names(hazard_flags: int) -> Iterable[str]:
    for bit_index, name in enumerate(HAZARD_FLAG_NAMES):
        if hazard_flags & (1 << bit_index):
            yield name


def header_to_dict(header: PacketHeader) -> Dict[str, int]:
    return {
        "magic": header.magic,
        "version": header.version,
        "packet_type": header.packet_type,
        "total_length": header.total_length,
        "sequence": header.sequence,
        "timestamp_unix": header.timestamp_unix,
        "checksum_crc32": header.checksum_crc32,
    }


def packet_to_dict(packet: DecodedPacket) -> Dict[str, object]:
    if isinstance(packet, PositionUpdateV1):
        return {
            "kind": "PositionUpdateV1",
            "header": header_to_dict(packet.header),
            "lat_e5": packet.lat_e5,
            "lon_e5": packet.lon_e5,
            "accuracy_m": packet.accuracy_m,
            "fix_timestamp_unix": packet.fix_timestamp_unix,
        }

    if isinstance(packet, AckV1):
        return {
            "kind": "AckV1",
            "header": header_to_dict(packet.header),
            "echoed_sequence": packet.echoed_sequence,
            "status_code": packet.status_code,
            "status_name": STATUS_NAMES[packet.status_code],
            "active_weather_timestamp_unix": packet.active_weather_timestamp_unix,
            "active_position_timestamp_unix": packet.active_position_timestamp_unix,
            "reserved": packet.reserved,
        }

    regional_packet = packet
    return {
        "kind": "RegionalSnapshotV1",
        "header": header_to_dict(regional_packet.header),
        "metadata": {
            "field_center_lat_e5": regional_packet.metadata.field_center_lat_e5,
            "field_center_lon_e5": regional_packet.metadata.field_center_lon_e5,
            "field_width_mi": regional_packet.metadata.field_width_mi,
            "field_height_mi": regional_packet.metadata.field_height_mi,
            "grid_rows": regional_packet.metadata.grid_rows,
            "grid_cols": regional_packet.metadata.grid_cols,
            "slot_count": regional_packet.metadata.slot_count,
            "reserved0": regional_packet.metadata.reserved0,
            "forecast_horizon_min": regional_packet.metadata.forecast_horizon_min,
            "source_age_min": regional_packet.metadata.source_age_min,
        },
        "anchors": [
            {
                "anchor_name": ANCHOR_NAMES[anchor_index],
                "slots": [
                    {
                        "slot_offset_min": slot.slot_offset_min,
                        "air_temp_c_tenths": slot.air_temp_c_tenths,
                        "wind_speed_mps_tenths": slot.wind_speed_mps_tenths,
                        "wind_gust_mps_tenths": slot.wind_gust_mps_tenths,
                        "precip_prob_pct": slot.precip_prob_pct,
                        "precip_kind": slot.precip_kind,
                        "precip_kind_name": PRECIP_KIND_NAMES[slot.precip_kind],
                        "precip_intensity": slot.precip_intensity,
                        "precip_intensity_name": PRECIP_INTENSITY_NAMES[
                            slot.precip_intensity
                        ],
                        "reserved0": slot.reserved0,
                        "visibility_m": slot.visibility_m,
                        "hazard_flags": slot.hazard_flags,
                        "hazard_flag_names": list(iter_hazard_flag_names(slot.hazard_flags)),
                    }
                    for slot in slots
                ],
            }
            for anchor_index, slots in enumerate(regional_packet.anchor_slots)
        ],
    }
