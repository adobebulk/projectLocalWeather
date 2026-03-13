#ifndef WEATHER_COMPUTER_PERSISTENCE_H
#define WEATHER_COMPUTER_PERSISTENCE_H

#include <Arduino.h>

#include "protocol_parser.h"

namespace persistence {

bool saveWeatherSnapshot(const protocol_parser::RegionalSnapshotV1& weather, Stream& serial);
bool savePositionUpdate(const protocol_parser::PositionUpdateV1& position, Stream& serial);
void restoreDeviceState(Stream& serial);

}  // namespace persistence

#endif  // WEATHER_COMPUTER_PERSISTENCE_H
