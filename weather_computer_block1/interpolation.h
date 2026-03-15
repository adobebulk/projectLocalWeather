#ifndef WEATHER_COMPUTER_INTERPOLATION_H
#define WEATHER_COMPUTER_INTERPOLATION_H

#include <Arduino.h>

#include "protocol_parser.h"

namespace interpolation {

constexpr uint16_t kFieldWidthMiles = 240;
constexpr uint16_t kFieldHeightMiles = 240;
constexpr uint16_t kMinFieldDimensionMiles = 1;
constexpr uint16_t kMaxFieldDimensionMiles = 1000;
constexpr uint8_t kGridRows = 3;
constexpr uint8_t kGridCols = 3;
constexpr uint8_t kSlotCount = 3;
constexpr uint16_t kForecastHorizonMinutes = 120;

enum InterpolationStatus {
  kInterpolationOk = 0,
  kInterpolationInvalidWeatherField,
  kInterpolationInvalidPosition,
};

struct LocalEstimate {
  bool has_estimate;
  int16_t air_temp_c_tenths;
  uint16_t wind_speed_mps_tenths;
  uint16_t wind_gust_mps_tenths;
  uint8_t precip_prob_pct;
  uint8_t precip_kind;
  uint8_t precip_intensity;
  uint16_t visibility_m;
  uint16_t hazard_flags;
  uint8_t confidence_score;
};

InterpolationStatus estimateLocalConditions(
    const protocol_parser::RegionalSnapshotV1& weather,
    const protocol_parser::PositionUpdateV1& position,
    uint32_t current_unix_timestamp,
    LocalEstimate* out_estimate);

const char* statusToString(InterpolationStatus status);
void logWeatherFieldValidationFailure(const protocol_parser::RegionalSnapshotV1& weather,
                                      Stream& serial);

}  // namespace interpolation

#endif  // WEATHER_COMPUTER_INTERPOLATION_H
