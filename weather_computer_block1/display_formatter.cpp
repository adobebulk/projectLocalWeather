#include "display_formatter.h"

#include <Arduino.h>
#include <stdio.h>

namespace {

int roundedTenthsToWhole(int16_t value_tenths) {
  if (value_tenths >= 0) {
    return (value_tenths + 5) / 10;
  }
  return (value_tenths - 5) / 10;
}

void fitToDisplay(const char* source, char* destination) {
  size_t index = 0;
  while (source[index] != '\0' && index < 16) {
    destination[index] = source[index];
    ++index;
  }

  while (index < 16) {
    destination[index] = ' ';
    ++index;
  }

  destination[16] = '\0';
}

}  // namespace

namespace display_formatter {

DisplayLines formatEstimate(const interpolation::LocalEstimate& estimate) {
  DisplayLines lines = {};

  char raw_line1[32];
  char raw_line2[32];

  snprintf(raw_line1, sizeof(raw_line1), "T%d W%u G%u P%u",
           roundedTenthsToWhole(estimate.air_temp_c_tenths),
           static_cast<unsigned>(roundedTenthsToWhole(estimate.wind_speed_mps_tenths)),
           static_cast<unsigned>(roundedTenthsToWhole(estimate.wind_gust_mps_tenths)),
           static_cast<unsigned>(estimate.precip_prob_pct));
  snprintf(raw_line2, sizeof(raw_line2), "C%u H%04X V%u",
           static_cast<unsigned>(estimate.confidence_score),
           static_cast<unsigned>(estimate.hazard_flags),
           static_cast<unsigned>(estimate.visibility_m));

  fitToDisplay(raw_line1, lines.line1);
  fitToDisplay(raw_line2, lines.line2);
  return lines;
}

}  // namespace display_formatter
