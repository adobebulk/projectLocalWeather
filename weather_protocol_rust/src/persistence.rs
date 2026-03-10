use crate::device_state::{DeviceState, DeviceStateError};
use crate::{
    parse_packet, parse_position_update_v1, parse_regional_snapshot_v1, Packet, ParseError,
    PositionUpdateV1, RegionalSnapshotV1, CHECKSUM_OFFSET, POSITION_PACKET_SIZE,
    REGIONAL_PACKET_SIZE,
};

const PERSISTENCE_MAGIC: u32 = 0x5350_4357;
const PERSISTENCE_VERSION: u8 = 1;
const RECORD_HEADER_SIZE: usize = 18;
const SLOT_COUNT: usize = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersistedRecordKind {
    WeatherSnapshot = 1,
    PositionUpdate = 2,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersistenceError {
    Backend(&'static str),
    Parse(ParseError),
    DeviceState(DeviceStateError),
}

impl From<ParseError> for PersistenceError {
    fn from(value: ParseError) -> Self {
        Self::Parse(value)
    }
}

impl From<DeviceStateError> for PersistenceError {
    fn from(value: DeviceStateError) -> Self {
        Self::DeviceState(value)
    }
}

pub trait PersistenceBackend {
    fn read_slot(&self, kind: PersistedRecordKind, slot_index: usize) -> Vec<u8>;
    fn write_slot(
        &mut self,
        kind: PersistedRecordKind,
        slot_index: usize,
        data: &[u8],
    ) -> Result<(), PersistenceError>;
}

#[derive(Debug, Clone)]
pub struct StatePersistence<B: PersistenceBackend> {
    backend: B,
}

impl<B: PersistenceBackend> StatePersistence<B> {
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    pub fn backend(&self) -> &B {
        &self.backend
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }

    pub fn save_weather_snapshot(
        &mut self,
        snapshot: &RegionalSnapshotV1,
    ) -> Result<(), PersistenceError> {
        let packet_bytes = encode_regional_snapshot_packet(snapshot);
        self.save_record(PersistedRecordKind::WeatherSnapshot, &packet_bytes)
    }

    pub fn save_position_update(
        &mut self,
        position: &PositionUpdateV1,
    ) -> Result<(), PersistenceError> {
        let packet_bytes = encode_position_packet(position);
        self.save_record(PersistedRecordKind::PositionUpdate, &packet_bytes)
    }

    pub fn restore_weather_snapshot(
        &self,
    ) -> Result<Option<RegionalSnapshotV1>, PersistenceError> {
        let Some(record) = self.restore_record(PersistedRecordKind::WeatherSnapshot)? else {
            return Ok(None);
        };
        Ok(Some(parse_regional_snapshot_v1(&record.payload_bytes)?))
    }

    pub fn restore_position_update(
        &self,
    ) -> Result<Option<PositionUpdateV1>, PersistenceError> {
        let Some(record) = self.restore_record(PersistedRecordKind::PositionUpdate)? else {
            return Ok(None);
        };
        Ok(Some(parse_position_update_v1(&record.payload_bytes)?))
    }

    pub fn restore_device_state(
        &self,
        current_unix_timestamp: u32,
    ) -> Result<DeviceState, PersistenceError> {
        let mut state = DeviceState::new();

        if let Some(snapshot) = self.restore_weather_snapshot()? {
            state.apply_weather_snapshot(snapshot)?;
        }
        if let Some(position) = self.restore_position_update()? {
            state.apply_position_update(position)?;
        }

        let _ = state.recompute_estimate(current_unix_timestamp)?;
        Ok(state)
    }

    fn save_record(
        &mut self,
        kind: PersistedRecordKind,
        payload_bytes: &[u8],
    ) -> Result<(), PersistenceError> {
        let latest_slot = self.find_latest_valid_slot(kind)?;
        let next_generation = latest_slot
            .as_ref()
            .map(|slot| slot.record.generation.wrapping_add(1))
            .unwrap_or(1);
        let target_slot = latest_slot
            .map(|slot| (slot.slot_index + 1) % SLOT_COUNT)
            .unwrap_or(0);
        let record_bytes = build_record_bytes(kind, next_generation, payload_bytes);

        self.backend.write_slot(kind, target_slot, &record_bytes)
    }

    fn restore_record(
        &self,
        kind: PersistedRecordKind,
    ) -> Result<Option<StoredRecord>, PersistenceError> {
        Ok(self.find_latest_valid_slot(kind)?.map(|slot| slot.record))
    }

    fn find_latest_valid_slot(
        &self,
        kind: PersistedRecordKind,
    ) -> Result<Option<SlotRecord>, PersistenceError> {
        let mut best: Option<SlotRecord> = None;

        for slot_index in 0..SLOT_COUNT {
            let raw = self.backend.read_slot(kind, slot_index);
            let Some(record) = parse_record_bytes(kind, &raw) else {
                continue;
            };

            let replace = best
                .as_ref()
                .map(|current| record.generation > current.record.generation)
                .unwrap_or(true);
            if replace {
                best = Some(SlotRecord { slot_index, record });
            }
        }

        Ok(best)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredRecord {
    generation: u32,
    payload_bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SlotRecord {
    slot_index: usize,
    record: StoredRecord,
}

fn build_record_bytes(kind: PersistedRecordKind, generation: u32, payload_bytes: &[u8]) -> Vec<u8> {
    let payload_crc = raw_crc32(payload_bytes);
    let mut bytes = Vec::with_capacity(RECORD_HEADER_SIZE + payload_bytes.len());
    bytes.extend_from_slice(&PERSISTENCE_MAGIC.to_le_bytes());
    bytes.push(PERSISTENCE_VERSION);
    bytes.push(kind as u8);
    bytes.extend_from_slice(&0u16.to_le_bytes());
    bytes.extend_from_slice(&generation.to_le_bytes());
    bytes.extend_from_slice(&(payload_bytes.len() as u16).to_le_bytes());
    bytes.extend_from_slice(&payload_crc.to_le_bytes());
    bytes.extend_from_slice(payload_bytes);
    bytes
}

fn parse_record_bytes(kind: PersistedRecordKind, bytes: &[u8]) -> Option<StoredRecord> {
    if bytes.len() < RECORD_HEADER_SIZE {
        return None;
    }

    let magic = u32::from_le_bytes(bytes[0..4].try_into().ok()?);
    if magic != PERSISTENCE_MAGIC || bytes[4] != PERSISTENCE_VERSION || bytes[5] != kind as u8 {
        return None;
    }

    let generation = u32::from_le_bytes(bytes[8..12].try_into().ok()?);
    let payload_length = u16::from_le_bytes(bytes[12..14].try_into().ok()?);
    let payload_crc = u32::from_le_bytes(bytes[14..18].try_into().ok()?);
    if bytes.len() != RECORD_HEADER_SIZE + usize::from(payload_length) {
        return None;
    }

    let payload_bytes = bytes[RECORD_HEADER_SIZE..].to_vec();
    if raw_crc32(&payload_bytes) != payload_crc {
        return None;
    }

    match parse_packet(&payload_bytes).ok()? {
        Packet::RegionalSnapshotV1(_) if kind == PersistedRecordKind::WeatherSnapshot => {}
        Packet::PositionUpdateV1(_) if kind == PersistedRecordKind::PositionUpdate => {}
        _ => return None,
    }

    Some(StoredRecord {
        generation,
        payload_bytes,
    })
}

fn encode_position_packet(position: &PositionUpdateV1) -> Vec<u8> {
    let mut packet = Vec::with_capacity(POSITION_PACKET_SIZE);
    packet.extend_from_slice(&position.header.magic.to_le_bytes());
    packet.push(position.header.version);
    packet.push(position.header.packet_type);
    packet.extend_from_slice(&position.header.total_length.to_le_bytes());
    packet.extend_from_slice(&position.header.sequence.to_le_bytes());
    packet.extend_from_slice(&position.header.timestamp_unix.to_le_bytes());
    packet.extend_from_slice(&0u32.to_le_bytes());
    packet.extend_from_slice(&position.lat_e5.to_le_bytes());
    packet.extend_from_slice(&position.lon_e5.to_le_bytes());
    packet.extend_from_slice(&position.accuracy_m.to_le_bytes());
    packet.extend_from_slice(&position.fix_timestamp_unix.to_le_bytes());
    let checksum = packet_crc32(&packet);
    packet[CHECKSUM_OFFSET..CHECKSUM_OFFSET + 4].copy_from_slice(&checksum.to_le_bytes());
    packet
}

fn encode_regional_snapshot_packet(snapshot: &RegionalSnapshotV1) -> Vec<u8> {
    let mut packet = Vec::with_capacity(REGIONAL_PACKET_SIZE);
    packet.extend_from_slice(&snapshot.header.magic.to_le_bytes());
    packet.push(snapshot.header.version);
    packet.push(snapshot.header.packet_type);
    packet.extend_from_slice(&snapshot.header.total_length.to_le_bytes());
    packet.extend_from_slice(&snapshot.header.sequence.to_le_bytes());
    packet.extend_from_slice(&snapshot.header.timestamp_unix.to_le_bytes());
    packet.extend_from_slice(&0u32.to_le_bytes());
    packet.extend_from_slice(&snapshot.metadata.field_center_lat_e5.to_le_bytes());
    packet.extend_from_slice(&snapshot.metadata.field_center_lon_e5.to_le_bytes());
    packet.extend_from_slice(&snapshot.metadata.field_width_mi.to_le_bytes());
    packet.extend_from_slice(&snapshot.metadata.field_height_mi.to_le_bytes());
    packet.push(snapshot.metadata.grid_rows);
    packet.push(snapshot.metadata.grid_cols);
    packet.push(snapshot.metadata.slot_count);
    packet.push(snapshot.metadata.reserved0);
    packet.extend_from_slice(&snapshot.metadata.forecast_horizon_min.to_le_bytes());
    packet.extend_from_slice(&snapshot.metadata.source_age_min.to_le_bytes());

    for anchor_slots in snapshot.anchor_slots {
        for slot in anchor_slots {
            packet.extend_from_slice(&slot.slot_offset_min.to_le_bytes());
            packet.extend_from_slice(&slot.air_temp_c_tenths.to_le_bytes());
            packet.extend_from_slice(&slot.wind_speed_mps_tenths.to_le_bytes());
            packet.extend_from_slice(&slot.wind_gust_mps_tenths.to_le_bytes());
            packet.push(slot.precip_prob_pct);
            packet.push(slot.precip_kind);
            packet.push(slot.precip_intensity);
            packet.push(slot.reserved0);
            packet.extend_from_slice(&slot.visibility_m.to_le_bytes());
            packet.extend_from_slice(&slot.hazard_flags.to_le_bytes());
        }
    }

    let checksum = packet_crc32(&packet);
    packet[CHECKSUM_OFFSET..CHECKSUM_OFFSET + 4].copy_from_slice(&checksum.to_le_bytes());
    packet
}

fn packet_crc32(packet: &[u8]) -> u32 {
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

fn raw_crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;

    for byte in bytes {
        crc ^= u32::from(*byte);
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

#[derive(Debug, Clone, Default)]
pub struct InMemoryPersistenceBackend {
    weather_slots: [Vec<u8>; SLOT_COUNT],
    position_slots: [Vec<u8>; SLOT_COUNT],
}

impl InMemoryPersistenceBackend {
    pub fn corrupt_slot(
        &mut self,
        kind: PersistedRecordKind,
        slot_index: usize,
        raw_bytes: Vec<u8>,
    ) {
        match kind {
            PersistedRecordKind::WeatherSnapshot => self.weather_slots[slot_index] = raw_bytes,
            PersistedRecordKind::PositionUpdate => self.position_slots[slot_index] = raw_bytes,
        }
    }
}

impl PersistenceBackend for InMemoryPersistenceBackend {
    fn read_slot(&self, kind: PersistedRecordKind, slot_index: usize) -> Vec<u8> {
        match kind {
            PersistedRecordKind::WeatherSnapshot => self.weather_slots[slot_index].clone(),
            PersistedRecordKind::PositionUpdate => self.position_slots[slot_index].clone(),
        }
    }

    fn write_slot(
        &mut self,
        kind: PersistedRecordKind,
        slot_index: usize,
        data: &[u8],
    ) -> Result<(), PersistenceError> {
        match kind {
            PersistedRecordKind::WeatherSnapshot => self.weather_slots[slot_index] = data.to_vec(),
            PersistedRecordKind::PositionUpdate => {
                self.position_slots[slot_index] = data.to_vec()
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        InMemoryPersistenceBackend, PersistedRecordKind, PersistenceBackend, StatePersistence,
    };
    use crate::{
        PacketHeader, PositionUpdateV1, RegionalSnapshotMetadataV1, RegionalSnapshotV1, WeatherSlot,
        FIELD_HEIGHT_MI, FIELD_WIDTH_MI, FORECAST_HORIZON_MIN, GRID_COLS, GRID_ROWS, MAGIC,
        PACKET_TYPE_POSITION_UPDATE_V1, PACKET_TYPE_REGIONAL_SNAPSHOT_V1, POSITION_PACKET_SIZE,
        REGIONAL_PACKET_SIZE, SLOT_COUNT, VERSION,
    };

    fn sample_weather_slot(
        slot_offset_min: u16,
        air_temp_c_tenths: i16,
        wind_speed_mps_tenths: u16,
        wind_gust_mps_tenths: u16,
        precip_prob_pct: u8,
        precip_kind: u8,
        precip_intensity: u8,
        visibility_m: u16,
        hazard_flags: u16,
    ) -> WeatherSlot {
        WeatherSlot {
            slot_offset_min,
            air_temp_c_tenths,
            wind_speed_mps_tenths,
            wind_gust_mps_tenths,
            precip_prob_pct,
            precip_kind,
            precip_intensity,
            reserved0: 0,
            visibility_m,
            hazard_flags,
        }
    }

    fn build_weather(timestamp_unix: u32) -> RegionalSnapshotV1 {
        RegionalSnapshotV1 {
            header: PacketHeader {
                magic: MAGIC,
                version: VERSION,
                packet_type: PACKET_TYPE_REGIONAL_SNAPSHOT_V1,
                total_length: REGIONAL_PACKET_SIZE as u16,
                sequence: 9,
                timestamp_unix,
                checksum_crc32: 0,
            },
            metadata: RegionalSnapshotMetadataV1 {
                field_center_lat_e5: 3_405_223,
                field_center_lon_e5: -11_824_368,
                field_width_mi: FIELD_WIDTH_MI,
                field_height_mi: FIELD_HEIGHT_MI,
                grid_rows: GRID_ROWS,
                grid_cols: GRID_COLS,
                slot_count: SLOT_COUNT,
                reserved0: 0,
                forecast_horizon_min: FORECAST_HORIZON_MIN,
                source_age_min: 5,
            },
            anchor_slots: [
                [
                    sample_weather_slot(0, 100, 10, 20, 10, 1, 1, 10_000, 1),
                    sample_weather_slot(60, 110, 20, 30, 20, 1, 1, 9_500, 2),
                    sample_weather_slot(120, 120, 30, 40, 30, 1, 2, 9_000, 4),
                ],
                [
                    sample_weather_slot(0, 200, 20, 30, 15, 1, 1, 10_100, 0),
                    sample_weather_slot(60, 210, 30, 40, 25, 1, 2, 9_600, 0),
                    sample_weather_slot(120, 220, 40, 50, 35, 2, 2, 9_100, 8),
                ],
                [
                    sample_weather_slot(0, 300, 30, 40, 20, 2, 1, 10_200, 0),
                    sample_weather_slot(60, 310, 40, 50, 30, 2, 2, 9_700, 0),
                    sample_weather_slot(120, 320, 50, 60, 40, 2, 3, 9_200, 16),
                ],
                [
                    sample_weather_slot(0, 400, 40, 50, 12, 1, 1, 10_300, 32),
                    sample_weather_slot(60, 410, 50, 60, 22, 1, 2, 9_800, 64),
                    sample_weather_slot(120, 420, 60, 70, 32, 1, 3, 9_300, 128),
                ],
                [
                    sample_weather_slot(0, 500, 50, 60, 18, 1, 1, 10_400, 256),
                    sample_weather_slot(60, 600, 70, 80, 38, 1, 2, 9_900, 512),
                    sample_weather_slot(120, 700, 90, 100, 58, 2, 3, 9_400, 1_024),
                ],
                [
                    sample_weather_slot(0, 600, 60, 70, 24, 2, 1, 10_500, 0),
                    sample_weather_slot(60, 610, 70, 80, 34, 2, 2, 10_000, 0),
                    sample_weather_slot(120, 620, 80, 90, 44, 2, 3, 9_500, 2_048),
                ],
                [
                    sample_weather_slot(0, 700, 70, 80, 14, 1, 1, 10_600, 0),
                    sample_weather_slot(60, 710, 80, 90, 24, 1, 1, 10_100, 0),
                    sample_weather_slot(120, 720, 90, 100, 34, 1, 2, 9_600, 4_096),
                ],
                [
                    sample_weather_slot(0, 800, 80, 90, 16, 1, 1, 10_700, 0),
                    sample_weather_slot(60, 810, 90, 100, 26, 1, 2, 10_200, 0),
                    sample_weather_slot(120, 820, 100, 110, 36, 2, 2, 9_700, 8_192),
                ],
                [
                    sample_weather_slot(0, 900, 90, 100, 28, 2, 1, 10_800, 0),
                    sample_weather_slot(60, 910, 100, 110, 38, 2, 2, 10_300, 0),
                    sample_weather_slot(120, 920, 110, 120, 48, 2, 3, 9_800, 16_384),
                ],
            ],
        }
    }

    fn build_position(timestamp_unix: u32) -> PositionUpdateV1 {
        PositionUpdateV1 {
            header: PacketHeader {
                magic: MAGIC,
                version: VERSION,
                packet_type: PACKET_TYPE_POSITION_UPDATE_V1,
                total_length: POSITION_PACKET_SIZE as u16,
                sequence: 10,
                timestamp_unix,
                checksum_crc32: 0,
            },
            lat_e5: 3_405_223,
            lon_e5: -11_824_368,
            accuracy_m: 8,
            fix_timestamp_unix: timestamp_unix,
        }
    }

    #[test]
    fn save_and_restore_weather_snapshot() {
        let weather = build_weather(1_700_000_000);
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());

        persistence.save_weather_snapshot(&weather).unwrap();
        let restored = persistence.restore_weather_snapshot().unwrap().unwrap();

        assert_eq!(restored.header.timestamp_unix, weather.header.timestamp_unix);
        assert_eq!(restored.metadata.field_center_lat_e5, weather.metadata.field_center_lat_e5);
    }

    #[test]
    fn save_and_restore_position_update() {
        let position = build_position(1_700_000_600);
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());

        persistence.save_position_update(&position).unwrap();
        let restored = persistence.restore_position_update().unwrap().unwrap();

        assert_eq!(restored.header.timestamp_unix, position.header.timestamp_unix);
        assert_eq!(restored.lon_e5, position.lon_e5);
    }

    #[test]
    fn boot_restore_path() {
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        persistence.save_weather_snapshot(&build_weather(1_700_000_000)).unwrap();
        persistence.save_position_update(&build_position(1_700_000_000)).unwrap();

        let state = persistence.restore_device_state(1_700_000_000).unwrap();

        assert!(state.active_weather_snapshot().is_some());
        assert!(state.latest_position_update().is_some());
        assert!(state.current_estimate().is_some());
    }

    #[test]
    fn corrupted_stored_record_rejection() {
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        persistence.save_weather_snapshot(&build_weather(1_700_000_000)).unwrap();

        let mut corrupt = persistence
            .backend()
            .read_slot(PersistedRecordKind::WeatherSnapshot, 0);
        corrupt[0] ^= 0xFF;
        persistence
            .backend_mut()
            .corrupt_slot(PersistedRecordKind::WeatherSnapshot, 0, corrupt);

        let restored = persistence.restore_weather_snapshot().unwrap();
        assert!(restored.is_none());
    }

    #[test]
    fn interrupted_invalid_record_fallback_behavior() {
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        persistence.save_position_update(&build_position(1_700_000_000)).unwrap();
        persistence.save_position_update(&build_position(1_700_000_600)).unwrap();

        let mut bad_slot = persistence
            .backend()
            .read_slot(PersistedRecordKind::PositionUpdate, 0);
        bad_slot.truncate(12);
        persistence
            .backend_mut()
            .corrupt_slot(PersistedRecordKind::PositionUpdate, 0, bad_slot);

        let restored = persistence.restore_position_update().unwrap().unwrap();
        assert_eq!(restored.header.timestamp_unix, 1_700_000_600);
    }
}
