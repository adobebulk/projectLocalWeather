#ifndef WEATHER_COMPUTER_DISPLAY_FORMATTER_H
#define WEATHER_COMPUTER_DISPLAY_FORMATTER_H

#include <Arduino.h>

#include "interpolation.h"

namespace display_formatter {

// Block 1 runtime display formatter.
// Line 1 follows the frozen visibility -> phenomenon -> wind policy with
// deterministic truncation inside 16 columns.
// Line 2 shows a short interpretation plus rounded confidence as CXX%.
//
// Hazard-bit assumptions used here are based on the frozen protocol names:
// bit 0 = thunder risk, bit 1 = severe thunderstorm risk,
// bit 3 = strong wind, bit 5 = freezing surface risk.

struct DisplayLines {
  char line1[17];
  char line2[17];
};

DisplayLines formatEstimate(const interpolation::LocalEstimate& estimate);
void logDecision(const interpolation::LocalEstimate& estimate, Stream& serial);

}  // namespace display_formatter

#endif  // WEATHER_COMPUTER_DISPLAY_FORMATTER_H
