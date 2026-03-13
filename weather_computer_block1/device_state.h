#ifndef WEATHER_COMPUTER_DEVICE_STATE_H
#define WEATHER_COMPUTER_DEVICE_STATE_H

#include <Arduino.h>

#include "interpolation.h"
#include "protocol_parser.h"

namespace device_state {

struct DeviceState {
  bool has_position;
  bool has_weather;
  bool has_estimate;

  protocol_parser::PositionUpdateV1 position;
  protocol_parser::RegionalSnapshotV1 weather;
  interpolation::LocalEstimate estimate;

  uint32_t position_timestamp;
  uint32_t weather_timestamp;
  uint32_t estimate_timestamp;
};

void reset();
DeviceState* mutableState();
const DeviceState* state();

}  // namespace device_state

#endif  // WEATHER_COMPUTER_DEVICE_STATE_H
