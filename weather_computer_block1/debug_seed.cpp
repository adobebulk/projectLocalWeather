#include "debug_seed.h"

#include "device_state.h"
#include "interpolation.h"
#include "protocol_parser.h"

namespace {

constexpr bool kEnableDebugSeed = false;

protocol_parser::WeatherSlot makeWeatherSlot(
    uint16_t slot_offset_min,
    int16_t air_temp_c_tenths,
    uint16_t wind_speed_mps_tenths,
    uint16_t wind_gust_mps_tenths,
    uint8_t precip_prob_pct,
    uint8_t precip_kind,
    uint8_t precip_intensity,
    uint16_t visibility_m,
    uint16_t hazard_flags) {
  protocol_parser::WeatherSlot slot = {};
  slot.slot_offset_min = slot_offset_min;
  slot.air_temp_c_tenths = air_temp_c_tenths;
  slot.wind_speed_mps_tenths = wind_speed_mps_tenths;
  slot.wind_gust_mps_tenths = wind_gust_mps_tenths;
  slot.precip_prob_pct = precip_prob_pct;
  slot.precip_kind = precip_kind;
  slot.precip_intensity = precip_intensity;
  slot.reserved0 = 0;
  slot.visibility_m = visibility_m;
  slot.hazard_flags = hazard_flags;
  return slot;
}

void fillSampleWeather(protocol_parser::RegionalSnapshotV1* weather) {
  *weather = {};
  weather->header.magic = protocol_parser::kMagic;
  weather->header.version = protocol_parser::kVersion;
  weather->header.packet_type = protocol_parser::kPacketTypeRegionalSnapshotV1;
  weather->header.total_length = protocol_parser::kRegionalSnapshotPacketSize;
  weather->header.sequence = 101;
  weather->header.timestamp_unix = 1700000000;
  weather->metadata.field_center_lat_e5 = 3405223;
  weather->metadata.field_center_lon_e5 = -11824368;
  weather->metadata.field_width_mi = interpolation::kFieldWidthMiles;
  weather->metadata.field_height_mi = interpolation::kFieldHeightMiles;
  weather->metadata.grid_rows = interpolation::kGridRows;
  weather->metadata.grid_cols = interpolation::kGridCols;
  weather->metadata.slot_count = interpolation::kSlotCount;
  weather->metadata.reserved0 = 0;
  weather->metadata.forecast_horizon_min = interpolation::kForecastHorizonMinutes;
  weather->metadata.source_age_min = 5;

  for (size_t anchor = 0; anchor < protocol_parser::kAnchorCount; ++anchor) {
    weather->anchor_slots[anchor][0] =
        makeWeatherSlot(0, 500 + (anchor * 10), 50 + anchor, 60 + anchor, 20, 1, 1, 10400, 1);
    weather->anchor_slots[anchor][1] =
        makeWeatherSlot(60, 550 + (anchor * 10), 60 + anchor, 70 + anchor, 30, 1, 2, 10000, 2);
    weather->anchor_slots[anchor][2] =
        makeWeatherSlot(120, 600 + (anchor * 10), 70 + anchor, 80 + anchor, 40, 2, 2, 9600, 4);
  }
}

void fillSamplePosition(protocol_parser::PositionUpdateV1* position) {
  *position = {};
  position->header.magic = protocol_parser::kMagic;
  position->header.version = protocol_parser::kVersion;
  position->header.packet_type = protocol_parser::kPacketTypePositionUpdateV1;
  position->header.total_length = protocol_parser::kPositionUpdatePacketSize;
  position->header.sequence = 202;
  position->header.timestamp_unix = 1700001800;
  position->lat_e5 = 3405223;
  position->lon_e5 = -11824368;
  position->accuracy_m = 8;
  position->fix_timestamp_unix = 1700001800;
}

}  // namespace

namespace debug_seed {

void maybeInject(Stream& serial) {
  if (!kEnableDebugSeed) {
    return;
  }

  device_state::DeviceState* state = device_state::mutableState();
  fillSampleWeather(&state->weather);
  fillSamplePosition(&state->position);
  state->has_weather = true;
  state->has_position = true;
  state->weather_timestamp = state->weather.header.timestamp_unix;
  state->position_timestamp = state->position.header.timestamp_unix;

  interpolation::LocalEstimate estimate = {};
  const uint32_t recompute_timestamp =
      state->weather_timestamp > state->position_timestamp ? state->weather_timestamp
                                                           : state->position_timestamp;
  if (interpolation::estimateLocalConditions(state->weather, state->position, recompute_timestamp,
                                             &estimate) == interpolation::kInterpolationOk) {
    state->estimate = estimate;
    state->has_estimate = true;
    state->estimate_timestamp = recompute_timestamp;
    serial.println("DEBUG: injected sample weather and position");
  }
}

}  // namespace debug_seed
