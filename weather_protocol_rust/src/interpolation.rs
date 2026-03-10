use crate::{
    PositionUpdateV1, RegionalSnapshotMetadataV1, RegionalSnapshotV1, WeatherSlot,
    ANCHOR_COUNT, FIELD_HEIGHT_MI, FIELD_WIDTH_MI, FORECAST_HORIZON_MIN, GRID_COLS, GRID_ROWS,
    SLOT_COUNT,
};

const METERS_PER_DEGREE_LATITUDE: f64 = 111_320.0;
const METERS_PER_MILE: f64 = 1_609.344;

/// Estimated local conditions in protocol-native units.
///
/// The confidence score is computed locally on the device. It is a tunable
/// Block 1 heuristic, not a physical truth model and not part of the wire
/// format.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstimatedLocalConditions {
    pub air_temp_c_tenths: i16,
    pub wind_speed_mps_tenths: u16,
    pub wind_gust_mps_tenths: u16,
    pub precip_prob_pct: u8,
    pub precip_kind: u8,
    pub precip_intensity: u8,
    pub visibility_m: u16,
    pub hazard_flags: u16,
    pub confidence_score: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InterpolationError {
    InvalidWeatherField(&'static str),
    InvalidPosition(&'static str),
}

#[derive(Debug, Clone, Copy)]
struct SpatialContext {
    clamped_x: f64,
    clamped_y: f64,
    outside_field_bounds: bool,
    distance_from_center_m: f64,
}

#[derive(Debug, Clone, Copy)]
struct TemporalContext {
    lower_slot_index: usize,
    upper_slot_index: usize,
    fraction: f64,
    weather_age_minutes: i64,
    minutes_beyond_horizon: i64,
}

#[derive(Debug, Clone, Copy)]
struct SpatialBlend {
    anchor_index: usize,
    weight: f64,
}

#[derive(Debug, Clone, Copy)]
struct NumericSample {
    air_temp_c_tenths: f64,
    wind_speed_mps_tenths: f64,
    wind_gust_mps_tenths: f64,
    precip_prob_pct: f64,
    visibility_m: f64,
}

/// Block 1 interpolation over a decoded weather field and position.
///
/// This module intentionally uses a crude planar approximation for the
/// 240-mile field. The goal for Block 1 is clear, stable, and testable
/// behavior rather than sophisticated geodesic math.
///
/// Spatial and temporal queries are clamped outside the field and forecast
/// bounds. Returned weather values come from the nearest valid edge of the
/// stored field, while the confidence score carries the degradation.
///
/// Hazard flags are combined conservatively. If any contributing anchor or
/// time slot with non-zero interpolation weight sets a hazard bit, the result
/// keeps that bit set.
pub fn estimate_local_conditions(
    weather: &RegionalSnapshotV1,
    position: &PositionUpdateV1,
    current_unix_timestamp: u32,
) -> Result<EstimatedLocalConditions, InterpolationError> {
    validate_weather_field(weather)?;
    validate_position(position)?;

    let spatial = build_spatial_context(&weather.metadata, position);
    let temporal = build_temporal_context(weather.header.timestamp_unix, current_unix_timestamp);
    let spatial_blends = build_spatial_blends(spatial.clamped_x, spatial.clamped_y);

    let mut air_temp = 0.0;
    let mut wind_speed = 0.0;
    let mut wind_gust = 0.0;
    let mut precip_probability = 0.0;
    let mut visibility = 0.0;
    let mut hazard_flags = 0u16;
    let mut best_precip_score = -1.0;
    let mut best_precip_probability = 0u8;
    let mut best_precip_intensity = 0u8;
    let mut best_precip_kind = 0u8;

    for blend in spatial_blends {
        let anchor_slots = &weather.anchor_slots[blend.anchor_index];
        let lower_slot = anchor_slots[temporal.lower_slot_index];
        let upper_slot = anchor_slots[temporal.upper_slot_index];
        let interpolated = interpolate_slot_numeric(lower_slot, upper_slot, temporal.fraction);

        air_temp += interpolated.air_temp_c_tenths * blend.weight;
        wind_speed += interpolated.wind_speed_mps_tenths * blend.weight;
        wind_gust += interpolated.wind_gust_mps_tenths * blend.weight;
        precip_probability += interpolated.precip_prob_pct * blend.weight;
        visibility += interpolated.visibility_m * blend.weight;

        if blend.weight > 0.0 {
            hazard_flags |= lower_slot.hazard_flags;
            hazard_flags |= upper_slot.hazard_flags;
        }

        update_precip_choice(
            &mut best_precip_score,
            &mut best_precip_probability,
            &mut best_precip_intensity,
            &mut best_precip_kind,
            lower_slot,
            blend.weight * (1.0 - temporal.fraction),
        );
        update_precip_choice(
            &mut best_precip_score,
            &mut best_precip_probability,
            &mut best_precip_intensity,
            &mut best_precip_kind,
            upper_slot,
            blend.weight * temporal.fraction,
        );
    }

    let rounded_precip_probability = clamp_u8(precip_probability.round(), 0, 100);
    let (precip_kind, precip_intensity) = if rounded_precip_probability == 0 {
        (0, 0)
    } else {
        (best_precip_kind, best_precip_intensity)
    };

    Ok(EstimatedLocalConditions {
        air_temp_c_tenths: clamp_i16(air_temp.round()),
        wind_speed_mps_tenths: clamp_u16(wind_speed.round()),
        wind_gust_mps_tenths: clamp_u16(wind_gust.round()),
        precip_prob_pct: rounded_precip_probability,
        precip_kind,
        precip_intensity,
        visibility_m: clamp_u16(visibility.round()),
        hazard_flags,
        confidence_score: calculate_confidence(
            &spatial,
            &temporal,
            weather.metadata.field_width_mi,
            weather.metadata.field_height_mi,
            weather.metadata.source_age_min,
            position.header.timestamp_unix,
            current_unix_timestamp,
            position.accuracy_m,
        ),
    })
}

/// Returns only the local confidence score for a weather field and position.
///
/// This 0-100 score is intentionally simple and tunable. It is for local
/// device behavior in Block 1 and should not be treated as a physical truth
/// model.
pub fn calculate_confidence_score(
    weather: &RegionalSnapshotV1,
    position: &PositionUpdateV1,
    current_unix_timestamp: u32,
) -> Result<u8, InterpolationError> {
    validate_weather_field(weather)?;
    validate_position(position)?;

    let spatial = build_spatial_context(&weather.metadata, position);
    let temporal = build_temporal_context(weather.header.timestamp_unix, current_unix_timestamp);

    Ok(calculate_confidence(
        &spatial,
        &temporal,
        weather.metadata.field_width_mi,
        weather.metadata.field_height_mi,
        weather.metadata.source_age_min,
        position.header.timestamp_unix,
        current_unix_timestamp,
        position.accuracy_m,
    ))
}

fn calculate_confidence(
    spatial: &SpatialContext,
    temporal: &TemporalContext,
    field_width_miles: u16,
    field_height_miles: u16,
    source_age_minutes: u16,
    position_timestamp_unix: u32,
    current_unix_timestamp: u32,
    position_accuracy_m: u16,
) -> u8 {
    let mut score = 100i64;

    let effective_weather_age_minutes = temporal.weather_age_minutes.max(i64::from(source_age_minutes));
    score -= effective_weather_age_minutes.min(120) / 6;
    score -= temporal.minutes_beyond_horizon.min(120) / 3;

    let half_width_meters = (f64::from(field_width_miles) * METERS_PER_MILE) / 2.0;
    let half_height_meters = (f64::from(field_height_miles) * METERS_PER_MILE) / 2.0;
    let half_diagonal_meters = (half_width_meters.powi(2) + half_height_meters.powi(2)).sqrt();
    let distance_ratio = spatial.distance_from_center_m / half_diagonal_meters;
    score -= (distance_ratio.min(1.0) * 20.0).round() as i64;
    if spatial.outside_field_bounds {
        score -= 20;
    }

    let position_age_minutes = (i64::from(current_unix_timestamp) - i64::from(position_timestamp_unix))
        .max(0)
        / 60;
    score -= position_age_minutes.min(30);
    score -= i64::from((position_accuracy_m / 100).min(20));

    score.clamp(0, 100) as u8
}

fn validate_weather_field(weather: &RegionalSnapshotV1) -> Result<(), InterpolationError> {
    let metadata = &weather.metadata;
    if metadata.field_width_mi != FIELD_WIDTH_MI {
        return Err(InterpolationError::InvalidWeatherField(
            "field_width_mi must be 240",
        ));
    }
    if metadata.field_height_mi != FIELD_HEIGHT_MI {
        return Err(InterpolationError::InvalidWeatherField(
            "field_height_mi must be 240",
        ));
    }
    if metadata.grid_rows != GRID_ROWS || metadata.grid_cols != GRID_COLS {
        return Err(InterpolationError::InvalidWeatherField(
            "grid shape must be 3 by 3",
        ));
    }
    if metadata.slot_count != SLOT_COUNT {
        return Err(InterpolationError::InvalidWeatherField(
            "slot_count must be 3",
        ));
    }
    if metadata.forecast_horizon_min != FORECAST_HORIZON_MIN {
        return Err(InterpolationError::InvalidWeatherField(
            "forecast horizon must be 120 minutes",
        ));
    }
    if weather.anchor_slots.len() != ANCHOR_COUNT {
        return Err(InterpolationError::InvalidWeatherField(
            "anchor count must be 9",
        ));
    }

    for anchor_slots in &weather.anchor_slots {
        if anchor_slots.len() != SLOT_COUNT as usize {
            return Err(InterpolationError::InvalidWeatherField(
                "each anchor must contain 3 slots",
            ));
        }
        if anchor_slots[0].slot_offset_min != 0
            || anchor_slots[1].slot_offset_min != 60
            || anchor_slots[2].slot_offset_min != 120
        {
            return Err(InterpolationError::InvalidWeatherField(
                "slot offsets must be 0, 60, 120",
            ));
        }
    }

    Ok(())
}

fn validate_position(position: &PositionUpdateV1) -> Result<(), InterpolationError> {
    if !(-9_000_000..=9_000_000).contains(&position.lat_e5) {
        return Err(InterpolationError::InvalidPosition(
            "latitude must be in [-90, 90] degrees",
        ));
    }
    if !(-18_000_000..=18_000_000).contains(&position.lon_e5) {
        return Err(InterpolationError::InvalidPosition(
            "longitude must be in [-180, 180] degrees",
        ));
    }
    if position.accuracy_m == 0 {
        return Err(InterpolationError::InvalidPosition(
            "accuracy_m must be greater than zero",
        ));
    }
    Ok(())
}

fn build_spatial_context(
    metadata: &RegionalSnapshotMetadataV1,
    position: &PositionUpdateV1,
) -> SpatialContext {
    // Block 1 intentionally uses a simple planar approximation. The field is
    // small enough that stable, explicit behavior matters more than geodesic
    // precision here.
    let center_latitude_degrees = f64::from(metadata.field_center_lat_e5) / 100_000.0;
    let latitude_delta_degrees =
        (f64::from(position.lat_e5) - f64::from(metadata.field_center_lat_e5)) / 100_000.0;
    let longitude_delta_degrees =
        (f64::from(position.lon_e5) - f64::from(metadata.field_center_lon_e5)) / 100_000.0;

    let latitude_meters = latitude_delta_degrees * METERS_PER_DEGREE_LATITUDE;
    let longitude_meters = longitude_delta_degrees
        * METERS_PER_DEGREE_LATITUDE
        * center_latitude_degrees.to_radians().cos();

    let half_width_meters = (f64::from(metadata.field_width_mi) * METERS_PER_MILE) / 2.0;
    let half_height_meters = (f64::from(metadata.field_height_mi) * METERS_PER_MILE) / 2.0;

    let normalized_x = longitude_meters / half_width_meters;
    let normalized_y = latitude_meters / half_height_meters;

    SpatialContext {
        clamped_x: normalized_x.clamp(-1.0, 1.0),
        clamped_y: normalized_y.clamp(-1.0, 1.0),
        outside_field_bounds: normalized_x.abs() > 1.0 || normalized_y.abs() > 1.0,
        distance_from_center_m: (longitude_meters.powi(2) + latitude_meters.powi(2)).sqrt(),
    }
}

fn build_temporal_context(field_timestamp_unix: u32, current_unix_timestamp: u32) -> TemporalContext {
    let weather_age_seconds = i64::from(current_unix_timestamp) - i64::from(field_timestamp_unix);
    let clamped_age_seconds = weather_age_seconds.max(0);
    let weather_age_minutes = clamped_age_seconds / 60;

    if clamped_age_seconds <= 0 {
        // Before slot 0, clamp to the first forecast slot.
        return TemporalContext {
            lower_slot_index: 0,
            upper_slot_index: 0,
            fraction: 0.0,
            weather_age_minutes,
            minutes_beyond_horizon: 0,
        };
    }

    if clamped_age_seconds >= 7_200 {
        // Beyond the 120-minute horizon, clamp values to the last slot and let
        // the local confidence score carry the degradation.
        return TemporalContext {
            lower_slot_index: 2,
            upper_slot_index: 2,
            fraction: 0.0,
            weather_age_minutes,
            minutes_beyond_horizon: (clamped_age_seconds - 7_200) / 60,
        };
    }

    if clamped_age_seconds < 3_600 {
        return TemporalContext {
            lower_slot_index: 0,
            upper_slot_index: 1,
            fraction: clamped_age_seconds as f64 / 3_600.0,
            weather_age_minutes,
            minutes_beyond_horizon: 0,
        };
    }

    TemporalContext {
        lower_slot_index: 1,
        upper_slot_index: 2,
        fraction: (clamped_age_seconds - 3_600) as f64 / 3_600.0,
        weather_age_minutes,
        minutes_beyond_horizon: 0,
    }
}

fn build_spatial_blends(clamped_x: f64, clamped_y: f64) -> [SpatialBlend; 4] {
    let (left_column, right_column, column_fraction) = if clamped_x <= 0.0 {
        (0usize, 1usize, clamped_x + 1.0)
    } else {
        (1usize, 2usize, clamped_x)
    };

    let (top_row, bottom_row, row_fraction) = if clamped_y >= 0.0 {
        (0usize, 1usize, 1.0 - clamped_y)
    } else {
        (1usize, 2usize, -clamped_y)
    };

    let top_weight = 1.0 - row_fraction;
    let bottom_weight = row_fraction;
    let left_weight = 1.0 - column_fraction;
    let right_weight = column_fraction;

    [
        SpatialBlend {
            anchor_index: anchor_index(top_row, left_column),
            weight: top_weight * left_weight,
        },
        SpatialBlend {
            anchor_index: anchor_index(top_row, right_column),
            weight: top_weight * right_weight,
        },
        SpatialBlend {
            anchor_index: anchor_index(bottom_row, left_column),
            weight: bottom_weight * left_weight,
        },
        SpatialBlend {
            anchor_index: anchor_index(bottom_row, right_column),
            weight: bottom_weight * right_weight,
        },
    ]
}

fn interpolate_slot_numeric(
    lower_slot: WeatherSlot,
    upper_slot: WeatherSlot,
    fraction: f64,
) -> NumericSample {
    NumericSample {
        air_temp_c_tenths: lerp(
            f64::from(lower_slot.air_temp_c_tenths),
            f64::from(upper_slot.air_temp_c_tenths),
            fraction,
        ),
        wind_speed_mps_tenths: lerp(
            f64::from(lower_slot.wind_speed_mps_tenths),
            f64::from(upper_slot.wind_speed_mps_tenths),
            fraction,
        ),
        wind_gust_mps_tenths: lerp(
            f64::from(lower_slot.wind_gust_mps_tenths),
            f64::from(upper_slot.wind_gust_mps_tenths),
            fraction,
        ),
        precip_prob_pct: lerp(
            f64::from(lower_slot.precip_prob_pct),
            f64::from(upper_slot.precip_prob_pct),
            fraction,
        ),
        visibility_m: lerp(
            f64::from(lower_slot.visibility_m),
            f64::from(upper_slot.visibility_m),
            fraction,
        ),
    }
}

fn update_precip_choice(
    best_score: &mut f64,
    best_probability: &mut u8,
    best_intensity: &mut u8,
    best_kind: &mut u8,
    slot: WeatherSlot,
    source_weight: f64,
) {
    let score = source_weight * f64::from(slot.precip_prob_pct);
    if score > *best_score
        || (score == *best_score && slot.precip_intensity > *best_intensity)
        || (score == *best_score
            && slot.precip_intensity == *best_intensity
            && slot.precip_prob_pct > *best_probability)
    {
        *best_score = score;
        *best_probability = slot.precip_prob_pct;
        *best_intensity = slot.precip_intensity;
        *best_kind = slot.precip_kind;
    }
}

fn anchor_index(row: usize, column: usize) -> usize {
    row * GRID_COLS as usize + column
}

fn lerp(start: f64, end: f64, fraction: f64) -> f64 {
    start + ((end - start) * fraction)
}

fn clamp_u8(value: f64, min: u8, max: u8) -> u8 {
    value.clamp(f64::from(min), f64::from(max)) as u8
}

fn clamp_u16(value: f64) -> u16 {
    value.clamp(0.0, f64::from(u16::MAX)) as u16
}

fn clamp_i16(value: f64) -> i16 {
    value.clamp(f64::from(i16::MIN), f64::from(i16::MAX)) as i16
}

#[cfg(test)]
mod tests {
    use super::{estimate_local_conditions, InterpolationError};
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

    fn build_weather() -> RegionalSnapshotV1 {
        let metadata = RegionalSnapshotMetadataV1 {
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
        };

        let header = PacketHeader {
            magic: MAGIC,
            version: VERSION,
            packet_type: PACKET_TYPE_REGIONAL_SNAPSHOT_V1,
            total_length: 470,
            sequence: 11,
            timestamp_unix: 1_700_000_000,
            checksum_crc32: 0,
        };

        let anchor_slots = [
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
        ];

        RegionalSnapshotV1 {
            header,
            metadata,
            anchor_slots,
        }
    }

    fn build_position(lat_e5: i32, lon_e5: i32, timestamp_unix: u32, accuracy_m: u16) -> PositionUpdateV1 {
        PositionUpdateV1 {
            header: PacketHeader {
                magic: MAGIC,
                version: VERSION,
                packet_type: PACKET_TYPE_POSITION_UPDATE_V1,
                total_length: 32,
                sequence: 21,
                timestamp_unix,
                checksum_crc32: 0,
            },
            lat_e5,
            lon_e5,
            accuracy_m,
            fix_timestamp_unix: timestamp_unix,
        }
    }

    fn miles_to_lat_e5(miles: f64) -> i32 {
        let degrees = (miles * 1_609.344) / 111_320.0;
        (degrees * 100_000.0).round() as i32
    }

    fn miles_to_lon_e5(miles: f64, center_lat_e5: i32) -> i32 {
        let center_latitude_degrees = f64::from(center_lat_e5) / 100_000.0;
        let degrees =
            (miles * 1_609.344) / (111_320.0 * center_latitude_degrees.to_radians().cos());
        (degrees * 100_000.0).round() as i32
    }

    #[test]
    fn center_position_exact_slot_zero() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_000_000, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_000_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 500);
        assert_eq!(result.wind_speed_mps_tenths, 50);
        assert_eq!(result.wind_gust_mps_tenths, 60);
        assert_eq!(result.precip_prob_pct, 18);
        assert_eq!(result.precip_kind, 1);
        assert_eq!(result.precip_intensity, 1);
        assert_eq!(result.visibility_m, 10_400);
        assert_eq!(result.hazard_flags, 256);
        assert_eq!(result.confidence_score, 100);
    }

    #[test]
    fn center_position_halfway_between_slot_zero_and_slot_sixty() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_001_800, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_001_800).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 550);
        assert_eq!(result.wind_speed_mps_tenths, 60);
        assert_eq!(result.wind_gust_mps_tenths, 70);
        assert_eq!(result.precip_prob_pct, 28);
        assert_eq!(result.precip_kind, 1);
        assert_eq!(result.precip_intensity, 2);
        assert_eq!(result.visibility_m, 10_150);
        assert_eq!(result.hazard_flags, 768);
        assert_eq!(result.confidence_score, 95);
    }

    #[test]
    fn center_position_exact_slot_sixty() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_003_600, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_003_600).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 600);
        assert_eq!(result.wind_speed_mps_tenths, 70);
        assert_eq!(result.wind_gust_mps_tenths, 80);
        assert_eq!(result.precip_prob_pct, 38);
        assert_eq!(result.precip_kind, 1);
        assert_eq!(result.precip_intensity, 2);
        assert_eq!(result.visibility_m, 9_900);
        assert_eq!(result.hazard_flags, 1_536);
        assert_eq!(result.confidence_score, 90);
    }

    #[test]
    fn position_near_edge_of_field_uses_spatial_blend() {
        let weather = build_weather();
        let lon_offset = miles_to_lon_e5(110.0, weather.metadata.field_center_lat_e5);
        let lat_offset = miles_to_lat_e5(110.0);
        let position = build_position(
            weather.metadata.field_center_lat_e5 + lat_offset,
            weather.metadata.field_center_lon_e5 + lon_offset,
            1_700_000_000,
            8,
        );

        let result =
            estimate_local_conditions(&weather, &position, 1_700_000_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 317);
        assert_eq!(result.wind_speed_mps_tenths, 32);
        assert_eq!(result.precip_prob_pct, 20);
        assert_eq!(result.precip_kind, 2);
        assert_eq!(result.visibility_m, 10_217);
        assert_eq!(result.confidence_score, 82);
    }

    #[test]
    fn outside_field_degrades_confidence_and_clamps_values() {
        let weather = build_weather();
        let lon_offset = miles_to_lon_e5(150.0, weather.metadata.field_center_lat_e5);
        let position = build_position(
            weather.metadata.field_center_lat_e5,
            weather.metadata.field_center_lon_e5 + lon_offset,
            1_700_000_000,
            8,
        );

        let result =
            estimate_local_conditions(&weather, &position, 1_700_000_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 600);
        assert_eq!(result.wind_speed_mps_tenths, 60);
        assert_eq!(result.precip_prob_pct, 24);
        assert_eq!(result.confidence_score, 62);
    }

    #[test]
    fn far_outside_field_bounds_drives_confidence_very_low() {
        let weather = build_weather();
        let lon_offset = miles_to_lon_e5(400.0, weather.metadata.field_center_lat_e5);
        let lat_offset = miles_to_lat_e5(400.0);
        let position = build_position(
            weather.metadata.field_center_lat_e5 + lat_offset,
            weather.metadata.field_center_lon_e5 + lon_offset,
            1_700_000_000,
            2_500,
        );

        let result =
            estimate_local_conditions(&weather, &position, 1_700_009_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 320);
        assert_eq!(result.wind_speed_mps_tenths, 50);
        assert_eq!(result.precip_prob_pct, 40);
        assert_eq!(result.precip_kind, 2);
        assert!(result.confidence_score <= 20);
    }

    #[test]
    fn beyond_horizon_clamps_weather_and_degrades_confidence() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_009_000, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_009_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 700);
        assert_eq!(result.wind_speed_mps_tenths, 90);
        assert_eq!(result.wind_gust_mps_tenths, 100);
        assert_eq!(result.precip_prob_pct, 58);
        assert_eq!(result.precip_kind, 2);
        assert_eq!(result.precip_intensity, 3);
        assert_eq!(result.hazard_flags, 1_024);
        assert_eq!(result.confidence_score, 70);
    }

    #[test]
    fn stale_position_degrades_confidence() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_699_998_200, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_000_000).expect("interpolation should succeed");

        assert_eq!(result.air_temp_c_tenths, 500);
        assert_eq!(result.confidence_score, 70);
    }

    #[test]
    fn hazard_flags_propagate_conservatively() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_000_000, 8);

        let result =
            estimate_local_conditions(&weather, &position, 1_700_001_800).expect("interpolation should succeed");

        assert_eq!(result.hazard_flags & 256, 256);
        assert_eq!(result.hazard_flags & 512, 512);
    }

    #[test]
    fn strongest_weighted_precip_source_wins_kind_selection() {
        let mut weather = build_weather();
        weather.anchor_slots[4][0].precip_prob_pct = 40;
        weather.anchor_slots[4][0].precip_kind = 1;
        weather.anchor_slots[4][0].precip_intensity = 1;
        weather.anchor_slots[5][0].precip_prob_pct = 80;
        weather.anchor_slots[5][0].precip_kind = 2;
        weather.anchor_slots[5][0].precip_intensity = 3;

        let lon_offset = miles_to_lon_e5(90.0, weather.metadata.field_center_lat_e5);
        let position = build_position(
            weather.metadata.field_center_lat_e5,
            weather.metadata.field_center_lon_e5 + lon_offset,
            1_700_000_000,
            8,
        );

        let result =
            estimate_local_conditions(&weather, &position, 1_700_000_000).expect("interpolation should succeed");

        assert_eq!(result.precip_kind, 2);
        assert_eq!(result.precip_intensity, 3);
        assert!(result.precip_prob_pct > 40);
    }

    #[test]
    fn invalid_position_is_rejected() {
        let weather = build_weather();
        let position = build_position(3_405_223, -11_824_368, 1_700_000_000, 0);

        let error = estimate_local_conditions(&weather, &position, 1_700_000_000)
            .expect_err("invalid position should fail");

        assert_eq!(
            error,
            InterpolationError::InvalidPosition("accuracy_m must be greater than zero")
        );
    }
}
