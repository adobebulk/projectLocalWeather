#include "interpolation.h"

#include <Arduino.h>
#include <math.h>

namespace {

constexpr double kMetersPerDegreeLatitude = 111320.0;
constexpr double kMetersPerMile = 1609.344;
constexpr double kDegreesToRadians = 0.017453292519943295;

struct SpatialContext {
  double clamped_x;
  double clamped_y;
  bool outside_field_bounds;
  double distance_from_center_m;
};

struct TemporalContext {
  size_t lower_slot_index;
  size_t upper_slot_index;
  double fraction;
  int32_t weather_age_minutes;
  int32_t minutes_beyond_horizon;
};

struct SpatialBlend {
  size_t anchor_index;
  double weight;
};

struct NumericSample {
  double air_temp_c_tenths;
  double wind_speed_mps_tenths;
  double wind_gust_mps_tenths;
  double precip_prob_pct;
  double visibility_m;
};

double lerp(double start, double end, double fraction) {
  return start + ((end - start) * fraction);
}

uint8_t clampU8(double value, uint8_t min_value, uint8_t max_value) {
  if (value < static_cast<double>(min_value)) {
    return min_value;
  }
  if (value > static_cast<double>(max_value)) {
    return max_value;
  }
  return static_cast<uint8_t>(value);
}

uint16_t clampU16(double value) {
  if (value < 0.0) {
    return 0;
  }
  if (value > static_cast<double>(UINT16_MAX)) {
    return UINT16_MAX;
  }
  return static_cast<uint16_t>(value);
}

int16_t clampI16(double value) {
  if (value < static_cast<double>(INT16_MIN)) {
    return INT16_MIN;
  }
  if (value > static_cast<double>(INT16_MAX)) {
    return INT16_MAX;
  }
  return static_cast<int16_t>(value);
}

size_t anchorIndex(size_t row, size_t column) {
  return (row * interpolation::kGridCols) + column;
}

bool validateWeatherField(const protocol_parser::RegionalSnapshotV1& weather) {
  const protocol_parser::RegionalSnapshotMetadataV1& metadata = weather.metadata;
  if (metadata.field_width_mi != interpolation::kFieldWidthMiles) {
    return false;
  }
  if (metadata.field_height_mi != interpolation::kFieldHeightMiles) {
    return false;
  }
  if (metadata.grid_rows != interpolation::kGridRows ||
      metadata.grid_cols != interpolation::kGridCols) {
    return false;
  }
  if (metadata.slot_count != interpolation::kSlotCount) {
    return false;
  }
  if (metadata.forecast_horizon_min != interpolation::kForecastHorizonMinutes) {
    return false;
  }

  for (size_t anchor_index = 0; anchor_index < protocol_parser::kAnchorCount; ++anchor_index) {
    if (weather.anchor_slots[anchor_index][0].slot_offset_min != 0 ||
        weather.anchor_slots[anchor_index][1].slot_offset_min != 60 ||
        weather.anchor_slots[anchor_index][2].slot_offset_min != 120) {
      return false;
    }
  }

  return true;
}

bool validatePosition(const protocol_parser::PositionUpdateV1& position) {
  if (position.lat_e5 < -9000000 || position.lat_e5 > 9000000) {
    return false;
  }
  if (position.lon_e5 < -18000000 || position.lon_e5 > 18000000) {
    return false;
  }
  if (position.accuracy_m == 0) {
    return false;
  }
  return true;
}

SpatialContext buildSpatialContext(
    const protocol_parser::RegionalSnapshotMetadataV1& metadata,
    const protocol_parser::PositionUpdateV1& position) {
  const double center_latitude_degrees =
      static_cast<double>(metadata.field_center_lat_e5) / 100000.0;
  const double latitude_delta_degrees =
      (static_cast<double>(position.lat_e5) -
       static_cast<double>(metadata.field_center_lat_e5)) /
      100000.0;
  const double longitude_delta_degrees =
      (static_cast<double>(position.lon_e5) -
       static_cast<double>(metadata.field_center_lon_e5)) /
      100000.0;

  const double latitude_meters = latitude_delta_degrees * kMetersPerDegreeLatitude;
  const double longitude_meters =
      longitude_delta_degrees * kMetersPerDegreeLatitude *
      cos(center_latitude_degrees * kDegreesToRadians);

  const double half_width_meters =
      (static_cast<double>(metadata.field_width_mi) * kMetersPerMile) / 2.0;
  const double half_height_meters =
      (static_cast<double>(metadata.field_height_mi) * kMetersPerMile) / 2.0;

  const double normalized_x = longitude_meters / half_width_meters;
  const double normalized_y = latitude_meters / half_height_meters;

  SpatialContext context = {};
  context.clamped_x = normalized_x;
  if (context.clamped_x < -1.0) {
    context.clamped_x = -1.0;
  } else if (context.clamped_x > 1.0) {
    context.clamped_x = 1.0;
  }

  context.clamped_y = normalized_y;
  if (context.clamped_y < -1.0) {
    context.clamped_y = -1.0;
  } else if (context.clamped_y > 1.0) {
    context.clamped_y = 1.0;
  }

  context.outside_field_bounds = (fabs(normalized_x) > 1.0) || (fabs(normalized_y) > 1.0);
  context.distance_from_center_m =
      sqrt((longitude_meters * longitude_meters) + (latitude_meters * latitude_meters));
  return context;
}

TemporalContext buildTemporalContext(uint32_t field_timestamp_unix, uint32_t current_unix_timestamp) {
  const int32_t weather_age_seconds =
      static_cast<int32_t>(current_unix_timestamp) - static_cast<int32_t>(field_timestamp_unix);
  const int32_t clamped_age_seconds = weather_age_seconds > 0 ? weather_age_seconds : 0;

  TemporalContext context = {};
  context.weather_age_minutes = clamped_age_seconds / 60;

  if (clamped_age_seconds <= 0) {
    context.lower_slot_index = 0;
    context.upper_slot_index = 0;
    context.fraction = 0.0;
    context.minutes_beyond_horizon = 0;
    return context;
  }

  if (clamped_age_seconds >= 7200) {
    context.lower_slot_index = 2;
    context.upper_slot_index = 2;
    context.fraction = 0.0;
    context.minutes_beyond_horizon = (clamped_age_seconds - 7200) / 60;
    return context;
  }

  if (clamped_age_seconds < 3600) {
    context.lower_slot_index = 0;
    context.upper_slot_index = 1;
    context.fraction = static_cast<double>(clamped_age_seconds) / 3600.0;
    context.minutes_beyond_horizon = 0;
    return context;
  }

  context.lower_slot_index = 1;
  context.upper_slot_index = 2;
  context.fraction = static_cast<double>(clamped_age_seconds - 3600) / 3600.0;
  context.minutes_beyond_horizon = 0;
  return context;
}

void buildSpatialBlends(double clamped_x, double clamped_y, SpatialBlend* blends) {
  size_t left_column = 0;
  size_t right_column = 1;
  double column_fraction = 0.0;
  if (clamped_x <= 0.0) {
    left_column = 0;
    right_column = 1;
    column_fraction = clamped_x + 1.0;
  } else {
    left_column = 1;
    right_column = 2;
    column_fraction = clamped_x;
  }

  size_t top_row = 0;
  size_t bottom_row = 1;
  double row_fraction = 0.0;
  if (clamped_y >= 0.0) {
    top_row = 0;
    bottom_row = 1;
    row_fraction = 1.0 - clamped_y;
  } else {
    top_row = 1;
    bottom_row = 2;
    row_fraction = -clamped_y;
  }

  const double top_weight = 1.0 - row_fraction;
  const double bottom_weight = row_fraction;
  const double left_weight = 1.0 - column_fraction;
  const double right_weight = column_fraction;

  blends[0].anchor_index = anchorIndex(top_row, left_column);
  blends[0].weight = top_weight * left_weight;
  blends[1].anchor_index = anchorIndex(top_row, right_column);
  blends[1].weight = top_weight * right_weight;
  blends[2].anchor_index = anchorIndex(bottom_row, left_column);
  blends[2].weight = bottom_weight * left_weight;
  blends[3].anchor_index = anchorIndex(bottom_row, right_column);
  blends[3].weight = bottom_weight * right_weight;
}

NumericSample interpolateSlotNumeric(
    const protocol_parser::WeatherSlot& lower_slot,
    const protocol_parser::WeatherSlot& upper_slot,
    double fraction) {
  NumericSample sample = {};
  sample.air_temp_c_tenths =
      lerp(lower_slot.air_temp_c_tenths, upper_slot.air_temp_c_tenths, fraction);
  sample.wind_speed_mps_tenths =
      lerp(lower_slot.wind_speed_mps_tenths, upper_slot.wind_speed_mps_tenths, fraction);
  sample.wind_gust_mps_tenths =
      lerp(lower_slot.wind_gust_mps_tenths, upper_slot.wind_gust_mps_tenths, fraction);
  sample.precip_prob_pct =
      lerp(lower_slot.precip_prob_pct, upper_slot.precip_prob_pct, fraction);
  sample.visibility_m = lerp(lower_slot.visibility_m, upper_slot.visibility_m, fraction);
  return sample;
}

void updatePrecipChoice(
    double* best_score,
    uint8_t* best_probability,
    uint8_t* best_intensity,
    uint8_t* best_kind,
    const protocol_parser::WeatherSlot& slot,
    double source_weight) {
  const double score = source_weight * static_cast<double>(slot.precip_prob_pct);
  if (score > *best_score ||
      (score == *best_score && slot.precip_intensity > *best_intensity) ||
      (score == *best_score && slot.precip_intensity == *best_intensity &&
       slot.precip_prob_pct > *best_probability)) {
    *best_score = score;
    *best_probability = slot.precip_prob_pct;
    *best_intensity = slot.precip_intensity;
    *best_kind = slot.precip_kind;
  }
}

uint8_t calculateConfidence(
    const SpatialContext& spatial,
    const TemporalContext& temporal,
    uint16_t field_width_miles,
    uint16_t field_height_miles,
    uint16_t source_age_minutes,
    uint32_t position_timestamp_unix,
    uint32_t current_unix_timestamp,
    uint16_t position_accuracy_m) {
  int32_t score = 100;

  int32_t effective_weather_age_minutes = temporal.weather_age_minutes;
  if (effective_weather_age_minutes < source_age_minutes) {
    effective_weather_age_minutes = source_age_minutes;
  }
  score -= (effective_weather_age_minutes > 120 ? 120 : effective_weather_age_minutes) / 6;
  score -= (temporal.minutes_beyond_horizon > 120 ? 120 : temporal.minutes_beyond_horizon) / 3;

  const double half_width_meters = (static_cast<double>(field_width_miles) * kMetersPerMile) / 2.0;
  const double half_height_meters =
      (static_cast<double>(field_height_miles) * kMetersPerMile) / 2.0;
  const double half_diagonal_meters =
      sqrt((half_width_meters * half_width_meters) + (half_height_meters * half_height_meters));
  double distance_ratio = spatial.distance_from_center_m / half_diagonal_meters;
  if (distance_ratio > 1.0) {
    distance_ratio = 1.0;
  }
  score -= static_cast<int32_t>(round(distance_ratio * 20.0));

  if (spatial.outside_field_bounds) {
    score -= 20;
  }

  int32_t position_age_minutes = 0;
  if (current_unix_timestamp > position_timestamp_unix) {
    position_age_minutes =
        static_cast<int32_t>((current_unix_timestamp - position_timestamp_unix) / 60);
  }
  score -= position_age_minutes > 30 ? 30 : position_age_minutes;
  score -= (position_accuracy_m / 100) > 20 ? 20 : (position_accuracy_m / 100);

  if (score < 0) {
    return 0;
  }
  if (score > 100) {
    return 100;
  }
  return static_cast<uint8_t>(score);
}

}  // namespace

namespace interpolation {

InterpolationStatus estimateLocalConditions(
    const protocol_parser::RegionalSnapshotV1& weather,
    const protocol_parser::PositionUpdateV1& position,
    uint32_t current_unix_timestamp,
    LocalEstimate* out_estimate) {
  if (out_estimate == nullptr) {
    return kInterpolationInvalidWeatherField;
  }

  *out_estimate = {};

  if (!validateWeatherField(weather)) {
    return kInterpolationInvalidWeatherField;
  }
  if (!validatePosition(position)) {
    return kInterpolationInvalidPosition;
  }

  const SpatialContext spatial = buildSpatialContext(weather.metadata, position);
  const TemporalContext temporal =
      buildTemporalContext(weather.header.timestamp_unix, current_unix_timestamp);
  SpatialBlend blends[4] = {};
  buildSpatialBlends(spatial.clamped_x, spatial.clamped_y, blends);

  double air_temp = 0.0;
  double wind_speed = 0.0;
  double wind_gust = 0.0;
  double precip_probability = 0.0;
  double visibility = 0.0;
  uint16_t hazard_flags = 0;
  double best_precip_score = -1.0;
  uint8_t best_precip_probability = 0;
  uint8_t best_precip_intensity = 0;
  uint8_t best_precip_kind = 0;

  for (size_t blend_index = 0; blend_index < 4; ++blend_index) {
    const SpatialBlend& blend = blends[blend_index];
    const protocol_parser::WeatherSlot& lower_slot =
        weather.anchor_slots[blend.anchor_index][temporal.lower_slot_index];
    const protocol_parser::WeatherSlot& upper_slot =
        weather.anchor_slots[blend.anchor_index][temporal.upper_slot_index];
    const NumericSample interpolated =
        interpolateSlotNumeric(lower_slot, upper_slot, temporal.fraction);

    air_temp += interpolated.air_temp_c_tenths * blend.weight;
    wind_speed += interpolated.wind_speed_mps_tenths * blend.weight;
    wind_gust += interpolated.wind_gust_mps_tenths * blend.weight;
    precip_probability += interpolated.precip_prob_pct * blend.weight;
    visibility += interpolated.visibility_m * blend.weight;

    if (blend.weight > 0.0) {
      hazard_flags |= lower_slot.hazard_flags;
      hazard_flags |= upper_slot.hazard_flags;
    }

    updatePrecipChoice(&best_precip_score, &best_precip_probability, &best_precip_intensity,
                       &best_precip_kind, lower_slot,
                       blend.weight * (1.0 - temporal.fraction));
    updatePrecipChoice(&best_precip_score, &best_precip_probability, &best_precip_intensity,
                       &best_precip_kind, upper_slot, blend.weight * temporal.fraction);
  }

  const uint8_t rounded_precip_probability =
      clampU8(round(precip_probability), 0, 100);
  uint8_t precip_kind = 0;
  uint8_t precip_intensity = 0;
  if (rounded_precip_probability > 0) {
    precip_kind = best_precip_kind;
    precip_intensity = best_precip_intensity;
  }

  out_estimate->has_estimate = true;
  out_estimate->air_temp_c_tenths = clampI16(round(air_temp));
  out_estimate->wind_speed_mps_tenths = clampU16(round(wind_speed));
  out_estimate->wind_gust_mps_tenths = clampU16(round(wind_gust));
  out_estimate->precip_prob_pct = rounded_precip_probability;
  out_estimate->precip_kind = precip_kind;
  out_estimate->precip_intensity = precip_intensity;
  out_estimate->visibility_m = clampU16(round(visibility));
  out_estimate->hazard_flags = hazard_flags;
  out_estimate->confidence_score = calculateConfidence(
      spatial, temporal, weather.metadata.field_width_mi, weather.metadata.field_height_mi,
      weather.metadata.source_age_min, position.header.timestamp_unix, current_unix_timestamp,
      position.accuracy_m);

  return kInterpolationOk;
}

const char* statusToString(InterpolationStatus status) {
  if (status == kInterpolationOk) {
    return "ok";
  }
  if (status == kInterpolationInvalidWeatherField) {
    return "invalid weather field";
  }
  return "invalid position";
}

}  // namespace interpolation
