#ifndef WEATHER_COMPUTER_DEBUG_SEED_H
#define WEATHER_COMPUTER_DEBUG_SEED_H

#include <Arduino.h>

namespace debug_seed {

bool isEnabled();
void maybeInject(Stream& serial);

}  // namespace debug_seed

#endif  // WEATHER_COMPUTER_DEBUG_SEED_H
