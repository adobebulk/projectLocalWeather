#ifndef WEATHER_COMPUTER_DISPLAY_FORMATTER_H
#define WEATHER_COMPUTER_DISPLAY_FORMATTER_H

#include <Arduino.h>

#include "interpolation.h"

namespace display_formatter {

struct DisplayLines {
  char line1[17];
  char line2[17];
};

DisplayLines formatEstimate(const interpolation::LocalEstimate& estimate);

}  // namespace display_formatter

#endif  // WEATHER_COMPUTER_DISPLAY_FORMATTER_H
