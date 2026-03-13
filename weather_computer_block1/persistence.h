#ifndef WEATHER_COMPUTER_PERSISTENCE_H
#define WEATHER_COMPUTER_PERSISTENCE_H

#include <Arduino.h>

#include "protocol_parser.h"

namespace persistence {

bool saveWeatherSnapshot(const protocol_parser::RegionalSnapshotV1& weather, Stream& serial);
bool savePositionUpdate(const protocol_parser::PositionUpdateV1& position, Stream& serial);
void restoreDeviceState(Stream& serial);

// Validation-only helpers for persistence and reboot robustness testing.
void clearAllRecords(Stream& serial);
void clearWeatherRecords(Stream& serial);
void clearPositionRecords(Stream& serial);
bool corruptWeatherSlotForTest(uint8_t slot_index, Stream& serial);
bool corruptPositionSlotForTest(uint8_t slot_index, Stream& serial);

}  // namespace persistence

#endif  // WEATHER_COMPUTER_PERSISTENCE_H
