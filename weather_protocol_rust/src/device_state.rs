use crate::interpolation::{
    estimate_local_conditions, EstimatedLocalConditions, InterpolationError,
};
use crate::{PositionUpdateV1, RegionalSnapshotV1};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceStateError {
    Interpolation(InterpolationError),
}

impl From<InterpolationError> for DeviceStateError {
    fn from(value: InterpolationError) -> Self {
        Self::Interpolation(value)
    }
}

#[derive(Debug, Clone, Default)]
pub struct DeviceState {
    active_weather_snapshot: Option<RegionalSnapshotV1>,
    latest_position_update: Option<PositionUpdateV1>,
    current_estimate: Option<EstimatedLocalConditions>,
    last_weather_update_timestamp: Option<u32>,
    last_position_update_timestamp: Option<u32>,
    last_recompute_timestamp: Option<u32>,
}

impl DeviceState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn apply_weather_snapshot(
        &mut self,
        snapshot: RegionalSnapshotV1,
    ) -> Result<(), DeviceStateError> {
        self.last_weather_update_timestamp = Some(snapshot.header.timestamp_unix);
        self.active_weather_snapshot = Some(snapshot);
        self.recompute_from_latest_inputs()
    }

    pub fn apply_position_update(
        &mut self,
        position: PositionUpdateV1,
    ) -> Result<(), DeviceStateError> {
        self.last_position_update_timestamp = Some(position.header.timestamp_unix);
        self.latest_position_update = Some(position);
        self.recompute_from_latest_inputs()
    }

    pub fn current_estimate(&self) -> Option<&EstimatedLocalConditions> {
        self.current_estimate.as_ref()
    }

    pub fn recompute_estimate(
        &mut self,
        current_unix_timestamp: u32,
    ) -> Result<Option<&EstimatedLocalConditions>, DeviceStateError> {
        let Some(weather) = self.active_weather_snapshot.as_ref() else {
            self.current_estimate = None;
            self.last_recompute_timestamp = Some(current_unix_timestamp);
            return Ok(None);
        };
        let Some(position) = self.latest_position_update.as_ref() else {
            self.current_estimate = None;
            self.last_recompute_timestamp = Some(current_unix_timestamp);
            return Ok(None);
        };

        let estimate = estimate_local_conditions(weather, position, current_unix_timestamp)?;
        self.current_estimate = Some(estimate);
        self.last_recompute_timestamp = Some(current_unix_timestamp);
        Ok(self.current_estimate.as_ref())
    }

    pub fn active_weather_snapshot(&self) -> Option<&RegionalSnapshotV1> {
        self.active_weather_snapshot.as_ref()
    }

    pub fn latest_position_update(&self) -> Option<&PositionUpdateV1> {
        self.latest_position_update.as_ref()
    }

    pub fn last_weather_update_timestamp(&self) -> Option<u32> {
        self.last_weather_update_timestamp
    }

    pub fn last_position_update_timestamp(&self) -> Option<u32> {
        self.last_position_update_timestamp
    }

    pub fn last_recompute_timestamp(&self) -> Option<u32> {
        self.last_recompute_timestamp
    }

    fn recompute_from_latest_inputs(&mut self) -> Result<(), DeviceStateError> {
        let recompute_timestamp = match (
            self.last_weather_update_timestamp,
            self.last_position_update_timestamp,
        ) {
            (Some(weather_timestamp), Some(position_timestamp)) => {
                weather_timestamp.max(position_timestamp)
            }
            _ => return Ok(()),
        };

        let _ = self.recompute_estimate(recompute_timestamp)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::DeviceState;
    use crate::{
        PacketHeader, PositionUpdateV1, RegionalSnapshotMetadataV1, RegionalSnapshotV1, WeatherSlot,
        FIELD_HEIGHT_MI, FIELD_WIDTH_MI, FORECAST_HORIZON_MIN, GRID_COLS, GRID_ROWS, MAGIC,
        PACKET_TYPE_POSITION_UPDATE_V1, PACKET_TYPE_REGIONAL_SNAPSHOT_V1, SLOT_COUNT, VERSION,
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
                total_length: 470,
                sequence: 1,
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

    fn build_position(timestamp_unix: u32, lon_offset_e5: i32) -> PositionUpdateV1 {
        PositionUpdateV1 {
            header: PacketHeader {
                magic: MAGIC,
                version: VERSION,
                packet_type: PACKET_TYPE_POSITION_UPDATE_V1,
                total_length: 32,
                sequence: 2,
                timestamp_unix,
                checksum_crc32: 0,
            },
            lat_e5: 3_405_223,
            lon_e5: -11_824_368 + lon_offset_e5,
            accuracy_m: 8,
            fix_timestamp_unix: timestamp_unix,
        }
    }

    #[test]
    fn receiving_weather_snapshot_stores_state_without_estimate() {
        let mut state = DeviceState::new();

        state
            .apply_weather_snapshot(build_weather(1_700_000_000))
            .expect("weather snapshot should apply");

        assert!(state.active_weather_snapshot().is_some());
        assert_eq!(state.last_weather_update_timestamp(), Some(1_700_000_000));
        assert!(state.current_estimate().is_none());
        assert_eq!(state.last_recompute_timestamp(), None);
    }

    #[test]
    fn receiving_position_update_after_weather_creates_estimate() {
        let mut state = DeviceState::new();
        state
            .apply_weather_snapshot(build_weather(1_700_000_000))
            .expect("weather snapshot should apply");

        state
            .apply_position_update(build_position(1_700_000_000, 0))
            .expect("position update should apply");

        let estimate = state.current_estimate().expect("estimate should exist");
        assert_eq!(estimate.air_temp_c_tenths, 500);
        assert_eq!(estimate.confidence_score, 100);
        assert_eq!(state.last_position_update_timestamp(), Some(1_700_000_000));
        assert_eq!(state.last_recompute_timestamp(), Some(1_700_000_000));
    }

    #[test]
    fn updating_position_multiple_times_refreshes_estimate() {
        let mut state = DeviceState::new();
        state
            .apply_weather_snapshot(build_weather(1_700_000_000))
            .expect("weather snapshot should apply");
        state
            .apply_position_update(build_position(1_700_000_000, 0))
            .expect("first position should apply");

        let first_temp = state
            .current_estimate()
            .expect("first estimate should exist")
            .air_temp_c_tenths;

        state
            .apply_position_update(build_position(1_700_000_600, 20_000))
            .expect("second position should apply");

        let second_estimate = state.current_estimate().expect("second estimate should exist");
        assert_ne!(second_estimate.air_temp_c_tenths, first_temp);
        assert_eq!(state.last_position_update_timestamp(), Some(1_700_000_600));
        assert_eq!(state.last_recompute_timestamp(), Some(1_700_000_600));
    }

    #[test]
    fn stale_weather_field_reduces_confidence_after_recompute() {
        let mut state = DeviceState::new();
        state
            .apply_weather_snapshot(build_weather(1_700_000_000))
            .expect("weather snapshot should apply");
        state
            .apply_position_update(build_position(1_700_000_000, 0))
            .expect("position should apply");

        let fresh_confidence = state
            .current_estimate()
            .expect("fresh estimate should exist")
            .confidence_score;

        let stale_estimate = state
            .recompute_estimate(1_700_009_000)
            .expect("stale recompute should succeed")
            .expect("stale estimate should exist");

        assert!(stale_estimate.confidence_score < fresh_confidence);
        assert_eq!(state.last_recompute_timestamp(), Some(1_700_009_000));
    }

    #[test]
    fn stale_position_update_reduces_confidence_after_recompute() {
        let mut state = DeviceState::new();
        state
            .apply_weather_snapshot(build_weather(1_700_000_000))
            .expect("weather snapshot should apply");
        state
            .apply_position_update(build_position(1_700_000_000, 0))
            .expect("position should apply");

        let fresh_confidence = state
            .current_estimate()
            .expect("fresh estimate should exist")
            .confidence_score;

        let stale_estimate = state
            .recompute_estimate(1_700_001_800)
            .expect("stale recompute should succeed")
            .expect("stale estimate should exist");

        assert!(stale_estimate.confidence_score < fresh_confidence);
        assert_eq!(state.last_recompute_timestamp(), Some(1_700_001_800));
    }
}
