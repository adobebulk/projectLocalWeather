pub mod device_state;
pub mod assembler;
pub mod ingress;
pub mod interpolation;

pub const MAGIC: u16 = 0x5743;
pub const VERSION: u8 = 1;

pub const PACKET_TYPE_REGIONAL_SNAPSHOT_V1: u8 = 1;
pub const PACKET_TYPE_POSITION_UPDATE_V1: u8 = 2;
pub const PACKET_TYPE_ACK_V1: u8 = 3;

pub const STATUS_ACCEPTED: u8 = 0;
pub const STATUS_BAD_MAGIC: u8 = 1;
pub const STATUS_UNSUPPORTED_VERSION: u8 = 2;
pub const STATUS_WRONG_LENGTH: u8 = 3;
pub const STATUS_BAD_CHECKSUM: u8 = 4;
pub const STATUS_UNSUPPORTED_PACKET_TYPE: u8 = 5;
pub const STATUS_SEMANTIC_VALIDATION_FAILED: u8 = 6;
pub const STATUS_STALE_OR_REPLAYED_SEQUENCE: u8 = 7;
pub const STATUS_STORAGE_FAILURE: u8 = 8;
pub const STATUS_INTERNAL_BUSY: u8 = 9;

pub const FIELD_WIDTH_MI: u16 = 240;
pub const FIELD_HEIGHT_MI: u16 = 240;
pub const GRID_ROWS: u8 = 3;
pub const GRID_COLS: u8 = 3;
pub const SLOT_COUNT: u8 = 3;
pub const FORECAST_HORIZON_MIN: u16 = 120;

pub const HEADER_SIZE: usize = 18;
pub const POSITION_PACKET_SIZE: usize = 32;
pub const ACK_PACKET_SIZE: usize = 32;
pub const REGIONAL_PACKET_SIZE: usize = 470;
pub const REGIONAL_METADATA_SIZE: usize = 20;
pub const WEATHER_SLOT_SIZE: usize = 16;
pub const ANCHOR_COUNT: usize = 9;
pub const CHECKSUM_OFFSET: usize = HEADER_SIZE - 4;

pub const EXPECTED_SLOT_OFFSETS: [u16; 3] = [0, 60, 120];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketHeader {
    pub magic: u16,
    pub version: u8,
    pub packet_type: u8,
    pub total_length: u16,
    pub sequence: u32,
    pub timestamp_unix: u32,
    pub checksum_crc32: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PositionUpdateV1 {
    pub header: PacketHeader,
    pub lat_e5: i32,
    pub lon_e5: i32,
    pub accuracy_m: u16,
    pub fix_timestamp_unix: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AckV1 {
    pub header: PacketHeader,
    pub echoed_sequence: u32,
    pub status_code: u8,
    pub active_weather_timestamp_unix: u32,
    pub active_position_timestamp_unix: u32,
    pub reserved: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegionalSnapshotMetadataV1 {
    pub field_center_lat_e5: i32,
    pub field_center_lon_e5: i32,
    pub field_width_mi: u16,
    pub field_height_mi: u16,
    pub grid_rows: u8,
    pub grid_cols: u8,
    pub slot_count: u8,
    pub reserved0: u8,
    pub forecast_horizon_min: u16,
    pub source_age_min: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WeatherSlot {
    pub slot_offset_min: u16,
    pub air_temp_c_tenths: i16,
    pub wind_speed_mps_tenths: u16,
    pub wind_gust_mps_tenths: u16,
    pub precip_prob_pct: u8,
    pub precip_kind: u8,
    pub precip_intensity: u8,
    pub reserved0: u8,
    pub visibility_m: u16,
    pub hazard_flags: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegionalSnapshotV1 {
    pub header: PacketHeader,
    pub metadata: RegionalSnapshotMetadataV1,
    pub anchor_slots: [[WeatherSlot; SLOT_COUNT as usize]; ANCHOR_COUNT],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Packet {
    RegionalSnapshotV1(RegionalSnapshotV1),
    PositionUpdateV1(PositionUpdateV1),
    AckV1(AckV1),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    PacketTooShort { expected_at_least: usize, actual: usize },
    BadMagic { expected: u16, actual: u16 },
    UnsupportedVersion { expected: u8, actual: u8 },
    UnsupportedPacketType(u8),
    WrongPacketLengthInHeader { expected: usize, actual: usize },
    WrongPacketByteLength { expected: usize, actual: usize },
    BadChecksum { expected: u32, actual: u32 },
    PacketTypeMismatch { expected: u8, actual: u8 },
    LatitudeOutOfRange(i32),
    LongitudeOutOfRange(i32),
    AccuracyMustBeGreaterThanZero,
    UnsupportedStatusCode(u8),
    ReservedNotZero { field_name: &'static str, value: u8 },
    FieldWidthMustBe240(u16),
    FieldHeightMustBe240(u16),
    GridRowsMustBe3(u8),
    GridColsMustBe3(u8),
    SlotCountMustBe3(u8),
    ForecastHorizonMustBe120(u16),
    InvalidPrecipProbability(u8),
    UnsupportedPrecipKind(u8),
    UnsupportedPrecipIntensity(u8),
    InvalidSlotOffsets {
        anchor_index: usize,
        expected: [u16; 3],
        actual: [u16; 3],
    },
}

pub fn parse_packet(packet: &[u8]) -> Result<Packet, ParseError> {
    let header = parse_header(packet)?;
    validate_header_fields(header)?;

    match header.packet_type {
        PACKET_TYPE_REGIONAL_SNAPSHOT_V1 => {
            Ok(Packet::RegionalSnapshotV1(parse_regional_snapshot_v1(packet)?))
        }
        PACKET_TYPE_POSITION_UPDATE_V1 => {
            Ok(Packet::PositionUpdateV1(parse_position_update_v1(packet)?))
        }
        PACKET_TYPE_ACK_V1 => Ok(Packet::AckV1(parse_ack_v1(packet)?)),
        other => Err(ParseError::UnsupportedPacketType(other)),
    }
}

pub fn parse_position_update_v1(packet: &[u8]) -> Result<PositionUpdateV1, ParseError> {
    let header = parse_header(packet)?;
    validate_header_fields(header)?;
    if header.packet_type != PACKET_TYPE_POSITION_UPDATE_V1 {
        return Err(ParseError::PacketTypeMismatch {
            expected: PACKET_TYPE_POSITION_UPDATE_V1,
            actual: header.packet_type,
        });
    }

    validate_packet_length(packet, header, POSITION_PACKET_SIZE)?;
    validate_checksum(packet, header)?;

    let lat_e5 = read_i32_le(packet, HEADER_SIZE)?;
    let lon_e5 = read_i32_le(packet, HEADER_SIZE + 4)?;
    let accuracy_m = read_u16_le(packet, HEADER_SIZE + 8)?;
    let fix_timestamp_unix = read_u32_le(packet, HEADER_SIZE + 10)?;

    validate_latitude_e5(lat_e5)?;
    validate_longitude_e5(lon_e5)?;
    if accuracy_m == 0 {
        return Err(ParseError::AccuracyMustBeGreaterThanZero);
    }

    Ok(PositionUpdateV1 {
        header,
        lat_e5,
        lon_e5,
        accuracy_m,
        fix_timestamp_unix,
    })
}

pub fn parse_ack_v1(packet: &[u8]) -> Result<AckV1, ParseError> {
    let header = parse_header(packet)?;
    validate_header_fields(header)?;
    if header.packet_type != PACKET_TYPE_ACK_V1 {
        return Err(ParseError::PacketTypeMismatch {
            expected: PACKET_TYPE_ACK_V1,
            actual: header.packet_type,
        });
    }

    validate_packet_length(packet, header, ACK_PACKET_SIZE)?;
    validate_checksum(packet, header)?;

    let echoed_sequence = read_u32_le(packet, HEADER_SIZE)?;
    let status_code = read_u8(packet, HEADER_SIZE + 4)?;
    validate_status_code(status_code)?;
    let active_weather_timestamp_unix = read_u32_le(packet, HEADER_SIZE + 5)?;
    let active_position_timestamp_unix = read_u32_le(packet, HEADER_SIZE + 9)?;
    let reserved = read_u8(packet, HEADER_SIZE + 13)?;
    if reserved != 0 {
        return Err(ParseError::ReservedNotZero {
            field_name: "ack.reserved",
            value: reserved,
        });
    }

    Ok(AckV1 {
        header,
        echoed_sequence,
        status_code,
        active_weather_timestamp_unix,
        active_position_timestamp_unix,
        reserved,
    })
}

pub fn parse_regional_snapshot_v1(packet: &[u8]) -> Result<RegionalSnapshotV1, ParseError> {
    let header = parse_header(packet)?;
    validate_header_fields(header)?;
    if header.packet_type != PACKET_TYPE_REGIONAL_SNAPSHOT_V1 {
        return Err(ParseError::PacketTypeMismatch {
            expected: PACKET_TYPE_REGIONAL_SNAPSHOT_V1,
            actual: header.packet_type,
        });
    }

    validate_packet_length(packet, header, REGIONAL_PACKET_SIZE)?;
    validate_checksum(packet, header)?;

    let metadata = RegionalSnapshotMetadataV1 {
        field_center_lat_e5: read_i32_le(packet, HEADER_SIZE)?,
        field_center_lon_e5: read_i32_le(packet, HEADER_SIZE + 4)?,
        field_width_mi: read_u16_le(packet, HEADER_SIZE + 8)?,
        field_height_mi: read_u16_le(packet, HEADER_SIZE + 10)?,
        grid_rows: read_u8(packet, HEADER_SIZE + 12)?,
        grid_cols: read_u8(packet, HEADER_SIZE + 13)?,
        slot_count: read_u8(packet, HEADER_SIZE + 14)?,
        reserved0: read_u8(packet, HEADER_SIZE + 15)?,
        forecast_horizon_min: read_u16_le(packet, HEADER_SIZE + 16)?,
        source_age_min: read_u16_le(packet, HEADER_SIZE + 18)?,
    };
    validate_regional_metadata(&metadata)?;

    let mut cursor = HEADER_SIZE + REGIONAL_METADATA_SIZE;
    let mut anchor_slots = [[WeatherSlot {
        slot_offset_min: 0,
        air_temp_c_tenths: 0,
        wind_speed_mps_tenths: 0,
        wind_gust_mps_tenths: 0,
        precip_prob_pct: 0,
        precip_kind: 0,
        precip_intensity: 0,
        reserved0: 0,
        visibility_m: 0,
        hazard_flags: 0,
    }; SLOT_COUNT as usize]; ANCHOR_COUNT];

    for anchor_index in 0..ANCHOR_COUNT {
        for slot_index in 0..SLOT_COUNT as usize {
            let slot = WeatherSlot {
                slot_offset_min: read_u16_le(packet, cursor)?,
                air_temp_c_tenths: read_i16_le(packet, cursor + 2)?,
                wind_speed_mps_tenths: read_u16_le(packet, cursor + 4)?,
                wind_gust_mps_tenths: read_u16_le(packet, cursor + 6)?,
                precip_prob_pct: read_u8(packet, cursor + 8)?,
                precip_kind: read_u8(packet, cursor + 9)?,
                precip_intensity: read_u8(packet, cursor + 10)?,
                reserved0: read_u8(packet, cursor + 11)?,
                visibility_m: read_u16_le(packet, cursor + 12)?,
                hazard_flags: read_u16_le(packet, cursor + 14)?,
            };
            validate_weather_slot(slot)?;
            anchor_slots[anchor_index][slot_index] = slot;
            cursor += WEATHER_SLOT_SIZE;
        }

        let actual_offsets = [
            anchor_slots[anchor_index][0].slot_offset_min,
            anchor_slots[anchor_index][1].slot_offset_min,
            anchor_slots[anchor_index][2].slot_offset_min,
        ];
        if actual_offsets != EXPECTED_SLOT_OFFSETS {
            return Err(ParseError::InvalidSlotOffsets {
                anchor_index,
                expected: EXPECTED_SLOT_OFFSETS,
                actual: actual_offsets,
            });
        }
    }

    Ok(RegionalSnapshotV1 {
        header,
        metadata,
        anchor_slots,
    })
}

pub fn parse_header(packet: &[u8]) -> Result<PacketHeader, ParseError> {
    if packet.len() < HEADER_SIZE {
        return Err(ParseError::PacketTooShort {
            expected_at_least: HEADER_SIZE,
            actual: packet.len(),
        });
    }

    Ok(PacketHeader {
        magic: read_u16_le(packet, 0)?,
        version: read_u8(packet, 2)?,
        packet_type: read_u8(packet, 3)?,
        total_length: read_u16_le(packet, 4)?,
        sequence: read_u32_le(packet, 6)?,
        timestamp_unix: read_u32_le(packet, 10)?,
        checksum_crc32: read_u32_le(packet, 14)?,
    })
}

pub fn crc32_with_zeroed_checksum(packet: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;

    for (index, byte) in packet.iter().enumerate() {
        let input = if (CHECKSUM_OFFSET..CHECKSUM_OFFSET + 4).contains(&index) {
            0u8
        } else {
            *byte
        };

        crc ^= u32::from(input);
        for _ in 0..8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }

    !crc
}

fn validate_header_fields(header: PacketHeader) -> Result<(), ParseError> {
    if header.magic != MAGIC {
        return Err(ParseError::BadMagic {
            expected: MAGIC,
            actual: header.magic,
        });
    }
    if header.version != VERSION {
        return Err(ParseError::UnsupportedVersion {
            expected: VERSION,
            actual: header.version,
        });
    }
    if !matches!(
        header.packet_type,
        PACKET_TYPE_REGIONAL_SNAPSHOT_V1
            | PACKET_TYPE_POSITION_UPDATE_V1
            | PACKET_TYPE_ACK_V1
    ) {
        return Err(ParseError::UnsupportedPacketType(header.packet_type));
    }

    Ok(())
}

fn validate_packet_length(
    packet: &[u8],
    header: PacketHeader,
    expected_length: usize,
) -> Result<(), ParseError> {
    if usize::from(header.total_length) != expected_length {
        return Err(ParseError::WrongPacketLengthInHeader {
            expected: expected_length,
            actual: usize::from(header.total_length),
        });
    }
    if packet.len() != expected_length {
        return Err(ParseError::WrongPacketByteLength {
            expected: expected_length,
            actual: packet.len(),
        });
    }
    Ok(())
}

fn validate_checksum(packet: &[u8], header: PacketHeader) -> Result<(), ParseError> {
    let expected = crc32_with_zeroed_checksum(packet);
    if header.checksum_crc32 != expected {
        return Err(ParseError::BadChecksum {
            expected,
            actual: header.checksum_crc32,
        });
    }
    Ok(())
}

fn validate_latitude_e5(value: i32) -> Result<(), ParseError> {
    if (-9_000_000..=9_000_000).contains(&value) {
        Ok(())
    } else {
        Err(ParseError::LatitudeOutOfRange(value))
    }
}

fn validate_longitude_e5(value: i32) -> Result<(), ParseError> {
    if (-18_000_000..=18_000_000).contains(&value) {
        Ok(())
    } else {
        Err(ParseError::LongitudeOutOfRange(value))
    }
}

fn validate_status_code(value: u8) -> Result<(), ParseError> {
    if matches!(value, 0..=9) {
        Ok(())
    } else {
        Err(ParseError::UnsupportedStatusCode(value))
    }
}

fn validate_precip_probability(value: u8) -> Result<(), ParseError> {
    if value <= 100 {
        Ok(())
    } else {
        Err(ParseError::InvalidPrecipProbability(value))
    }
}

fn validate_precip_kind(value: u8) -> Result<(), ParseError> {
    if matches!(value, 0..=6 | 255) {
        Ok(())
    } else {
        Err(ParseError::UnsupportedPrecipKind(value))
    }
}

fn validate_precip_intensity(value: u8) -> Result<(), ParseError> {
    if matches!(value, 0..=4 | 255) {
        Ok(())
    } else {
        Err(ParseError::UnsupportedPrecipIntensity(value))
    }
}

fn validate_weather_slot(slot: WeatherSlot) -> Result<(), ParseError> {
    validate_precip_probability(slot.precip_prob_pct)?;
    validate_precip_kind(slot.precip_kind)?;
    validate_precip_intensity(slot.precip_intensity)?;
    if slot.reserved0 != 0 {
        return Err(ParseError::ReservedNotZero {
            field_name: "weather_slot.reserved0",
            value: slot.reserved0,
        });
    }
    Ok(())
}

fn validate_regional_metadata(metadata: &RegionalSnapshotMetadataV1) -> Result<(), ParseError> {
    validate_latitude_e5(metadata.field_center_lat_e5)?;
    validate_longitude_e5(metadata.field_center_lon_e5)?;
    if metadata.field_width_mi != FIELD_WIDTH_MI {
        return Err(ParseError::FieldWidthMustBe240(metadata.field_width_mi));
    }
    if metadata.field_height_mi != FIELD_HEIGHT_MI {
        return Err(ParseError::FieldHeightMustBe240(metadata.field_height_mi));
    }
    if metadata.grid_rows != GRID_ROWS {
        return Err(ParseError::GridRowsMustBe3(metadata.grid_rows));
    }
    if metadata.grid_cols != GRID_COLS {
        return Err(ParseError::GridColsMustBe3(metadata.grid_cols));
    }
    if metadata.slot_count != SLOT_COUNT {
        return Err(ParseError::SlotCountMustBe3(metadata.slot_count));
    }
    if metadata.reserved0 != 0 {
        return Err(ParseError::ReservedNotZero {
            field_name: "regional_snapshot.metadata.reserved0",
            value: metadata.reserved0,
        });
    }
    if metadata.forecast_horizon_min != FORECAST_HORIZON_MIN {
        return Err(ParseError::ForecastHorizonMustBe120(
            metadata.forecast_horizon_min,
        ));
    }
    Ok(())
}

fn read_u8(packet: &[u8], offset: usize) -> Result<u8, ParseError> {
    packet.get(offset).copied().ok_or(ParseError::PacketTooShort {
        expected_at_least: offset + 1,
        actual: packet.len(),
    })
}

fn read_u16_le(packet: &[u8], offset: usize) -> Result<u16, ParseError> {
    let bytes = read_exact::<2>(packet, offset)?;
    Ok(u16::from_le_bytes(bytes))
}

fn read_u32_le(packet: &[u8], offset: usize) -> Result<u32, ParseError> {
    let bytes = read_exact::<4>(packet, offset)?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_i16_le(packet: &[u8], offset: usize) -> Result<i16, ParseError> {
    let bytes = read_exact::<2>(packet, offset)?;
    Ok(i16::from_le_bytes(bytes))
}

fn read_i32_le(packet: &[u8], offset: usize) -> Result<i32, ParseError> {
    let bytes = read_exact::<4>(packet, offset)?;
    Ok(i32::from_le_bytes(bytes))
}

fn read_exact<const N: usize>(packet: &[u8], offset: usize) -> Result<[u8; N], ParseError> {
    let end = offset + N;
    let slice = packet.get(offset..end).ok_or(ParseError::PacketTooShort {
        expected_at_least: end,
        actual: packet.len(),
    })?;
    let mut bytes = [0u8; N];
    bytes.copy_from_slice(slice);
    Ok(bytes)
}
