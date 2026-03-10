use crate::device_state::{DeviceState, DeviceStateError};
use crate::{
    crc32_with_zeroed_checksum, parse_header, parse_packet, AckV1, Packet, PacketHeader, ParseError,
    ACK_PACKET_SIZE, CHECKSUM_OFFSET, HEADER_SIZE, MAGIC, PACKET_TYPE_ACK_V1,
    PACKET_TYPE_POSITION_UPDATE_V1, PACKET_TYPE_REGIONAL_SNAPSHOT_V1, STATUS_ACCEPTED,
    STATUS_BAD_CHECKSUM, STATUS_BAD_MAGIC, STATUS_INTERNAL_BUSY, STATUS_SEMANTIC_VALIDATION_FAILED,
    STATUS_UNSUPPORTED_PACKET_TYPE, STATUS_UNSUPPORTED_VERSION, STATUS_WRONG_LENGTH, VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngressError {
    Parse(ParseError),
    DeviceState(DeviceStateError),
    UnsupportedIncomingAck,
}

impl From<ParseError> for IngressError {
    fn from(value: ParseError) -> Self {
        Self::Parse(value)
    }
}

impl From<DeviceStateError> for IngressError {
    fn from(value: DeviceStateError) -> Self {
        Self::DeviceState(value)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngressSuccess {
    pub ack: AckV1,
    pub ack_bytes: Vec<u8>,
    pub accepted_packet_type: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngressRejection {
    pub ack: AckV1,
    pub ack_bytes: Vec<u8>,
    pub error: IngressError,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngressResult {
    Accepted(IngressSuccess),
    Rejected(IngressRejection),
}

#[derive(Debug, Clone, Default)]
pub struct PacketIngress {
    device_state: DeviceState,
    next_ack_sequence: u32,
}

impl PacketIngress {
    pub fn new() -> Self {
        Self {
            device_state: DeviceState::new(),
            next_ack_sequence: 1,
        }
    }

    pub fn device_state(&self) -> &DeviceState {
        &self.device_state
    }

    pub fn ingest_packet(&mut self, packet_bytes: &[u8], ack_timestamp_unix: u32) -> IngressResult {
        let echoed_sequence = parse_header(packet_bytes)
            .map(|header| header.sequence)
            .unwrap_or(0);

        match parse_packet(packet_bytes) {
            Ok(Packet::RegionalSnapshotV1(snapshot)) => {
                match self.device_state.apply_weather_snapshot(snapshot) {
                    Ok(()) => self.accept_result(
                        echoed_sequence,
                        ack_timestamp_unix,
                        PACKET_TYPE_REGIONAL_SNAPSHOT_V1,
                    ),
                    Err(error) => self.reject_result(
                        echoed_sequence,
                        ack_timestamp_unix,
                        STATUS_SEMANTIC_VALIDATION_FAILED,
                        IngressError::DeviceState(error),
                    ),
                }
            }
            Ok(Packet::PositionUpdateV1(position)) => {
                match self.device_state.apply_position_update(position) {
                    Ok(()) => self.accept_result(
                        echoed_sequence,
                        ack_timestamp_unix,
                        PACKET_TYPE_POSITION_UPDATE_V1,
                    ),
                    Err(error) => self.reject_result(
                        echoed_sequence,
                        ack_timestamp_unix,
                        STATUS_SEMANTIC_VALIDATION_FAILED,
                        IngressError::DeviceState(error),
                    ),
                }
            }
            Ok(Packet::AckV1(_)) => self.reject_result(
                echoed_sequence,
                ack_timestamp_unix,
                STATUS_UNSUPPORTED_PACKET_TYPE,
                IngressError::UnsupportedIncomingAck,
            ),
            Err(error) => {
                let status_code = map_parse_error_to_status_code(&error);
                self.reject_result(
                    echoed_sequence,
                    ack_timestamp_unix,
                    status_code,
                    IngressError::Parse(error),
                )
            }
        }
    }

    fn accept_result(
        &mut self,
        echoed_sequence: u32,
        ack_timestamp_unix: u32,
        accepted_packet_type: u8,
    ) -> IngressResult {
        let ack = self.build_ack(
            echoed_sequence,
            STATUS_ACCEPTED,
            ack_timestamp_unix,
        );
        let ack_bytes = encode_ack_packet(&ack);

        IngressResult::Accepted(IngressSuccess {
            ack,
            ack_bytes,
            accepted_packet_type,
        })
    }

    fn reject_result(
        &mut self,
        echoed_sequence: u32,
        ack_timestamp_unix: u32,
        status_code: u8,
        error: IngressError,
    ) -> IngressResult {
        let ack = self.build_ack(echoed_sequence, status_code, ack_timestamp_unix);
        let ack_bytes = encode_ack_packet(&ack);

        IngressResult::Rejected(IngressRejection {
            ack,
            ack_bytes,
            error,
        })
    }

    fn build_ack(
        &mut self,
        echoed_sequence: u32,
        status_code: u8,
        ack_timestamp_unix: u32,
    ) -> AckV1 {
        let ack = AckV1 {
            header: PacketHeader {
                magic: MAGIC,
                version: VERSION,
                packet_type: PACKET_TYPE_ACK_V1,
                total_length: ACK_PACKET_SIZE as u16,
                sequence: self.next_ack_sequence,
                timestamp_unix: ack_timestamp_unix,
                checksum_crc32: 0,
            },
            echoed_sequence,
            status_code,
            active_weather_timestamp_unix: self
                .device_state
                .last_weather_update_timestamp()
                .unwrap_or(0),
            active_position_timestamp_unix: self
                .device_state
                .last_position_update_timestamp()
                .unwrap_or(0),
            reserved: 0,
        };
        self.next_ack_sequence = self.next_ack_sequence.wrapping_add(1);
        ack
    }
}

fn map_parse_error_to_status_code(error: &ParseError) -> u8 {
    match error {
        ParseError::BadMagic { .. } => STATUS_BAD_MAGIC,
        ParseError::UnsupportedVersion { .. } => STATUS_UNSUPPORTED_VERSION,
        ParseError::PacketTooShort { .. }
        | ParseError::WrongPacketLengthInHeader { .. }
        | ParseError::WrongPacketByteLength { .. } => STATUS_WRONG_LENGTH,
        ParseError::BadChecksum { .. } => STATUS_BAD_CHECKSUM,
        ParseError::UnsupportedPacketType(_) | ParseError::PacketTypeMismatch { .. } => {
            STATUS_UNSUPPORTED_PACKET_TYPE
        }
        ParseError::LatitudeOutOfRange(_)
        | ParseError::LongitudeOutOfRange(_)
        | ParseError::AccuracyMustBeGreaterThanZero
        | ParseError::UnsupportedStatusCode(_)
        | ParseError::ReservedNotZero { .. }
        | ParseError::FieldWidthMustBe240(_)
        | ParseError::FieldHeightMustBe240(_)
        | ParseError::GridRowsMustBe3(_)
        | ParseError::GridColsMustBe3(_)
        | ParseError::SlotCountMustBe3(_)
        | ParseError::ForecastHorizonMustBe120(_)
        | ParseError::InvalidPrecipProbability(_)
        | ParseError::UnsupportedPrecipKind(_)
        | ParseError::UnsupportedPrecipIntensity(_)
        | ParseError::InvalidSlotOffsets { .. } => STATUS_SEMANTIC_VALIDATION_FAILED,
    }
}

fn encode_ack_packet(ack: &AckV1) -> Vec<u8> {
    let mut packet = Vec::with_capacity(ACK_PACKET_SIZE);
    packet.extend_from_slice(&ack.header.magic.to_le_bytes());
    packet.push(ack.header.version);
    packet.push(ack.header.packet_type);
    packet.extend_from_slice(&ack.header.total_length.to_le_bytes());
    packet.extend_from_slice(&ack.header.sequence.to_le_bytes());
    packet.extend_from_slice(&ack.header.timestamp_unix.to_le_bytes());
    packet.extend_from_slice(&0u32.to_le_bytes());
    packet.extend_from_slice(&ack.echoed_sequence.to_le_bytes());
    packet.push(ack.status_code);
    packet.extend_from_slice(&ack.active_weather_timestamp_unix.to_le_bytes());
    packet.extend_from_slice(&ack.active_position_timestamp_unix.to_le_bytes());
    packet.push(ack.reserved);

    let checksum = crc32_with_zeroed_checksum(&packet);
    packet[CHECKSUM_OFFSET..CHECKSUM_OFFSET + 4].copy_from_slice(&checksum.to_le_bytes());
    packet
}

#[allow(dead_code)]
fn _assert_ack_layout() {
    let _ = HEADER_SIZE;
    let _ = STATUS_INTERNAL_BUSY;
}
