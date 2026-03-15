#include "display_formatter.h"

#include <Arduino.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

namespace {

constexpr uint32_t kStaleThresholdMinutes = 300;
constexpr double kMetersPerStatuteMile = 1609.344;
constexpr double kMetersPerSecondToMph = 2.2369362920544;

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

int roundedMpsTenthsToMph(uint16_t value_tenths) {
  const double mps = static_cast<double>(value_tenths) / 10.0;
  return static_cast<int>(round(mps * kMetersPerSecondToMph));
}

bool hasHazard(uint16_t hazard_flags, uint8_t bit_index) {
  return (hazard_flags & (1U << bit_index)) != 0U;
}

bool visibilityMissing(uint16_t visibility_m) {
  return visibility_m == 0;
}

void visibilityCode(uint16_t visibility_m, char* out_code) {
  if (visibilityMissing(visibility_m)) {
    out_code[0] = '\0';
    return;
  }

  const double visibility_miles = static_cast<double>(visibility_m) / kMetersPerStatuteMile;
  if (visibility_miles < 0.5) {
    snprintf(out_code, 4, "VL");
    return;
  }

  if (visibility_miles > 10.0) {
    snprintf(out_code, 4, "V+");
    return;
  }

  int rounded_miles = static_cast<int>(round(visibility_miles));
  if (rounded_miles < 1) {
    rounded_miles = 1;
  } else if (rounded_miles > 10) {
    rounded_miles = 10;
  }
  snprintf(out_code, 4, "V%d", rounded_miles);
}

bool phenomenonCode(const interpolation::LocalEstimate& estimate, char* out_code) {
  // Block 1.1 hazard display policy: only show hazard codes that are explicitly
  // present in forecast-office hazard flags; no derived hazards.
  if (estimate.hazard_flags == 0) {
    out_code[0] = '\0';
    return false;
  }

  if (hasHazard(estimate.hazard_flags, 1)) {
    snprintf(out_code, 4, "SV");
  } else if (hasHazard(estimate.hazard_flags, 0)) {
    snprintf(out_code, 4, "TS");
  } else if (hasHazard(estimate.hazard_flags, 5)) {
    snprintf(out_code, 4, "IC");
  } else if (hasHazard(estimate.hazard_flags, 3)) {
    snprintf(out_code, 4, "WI");
  } else {
    snprintf(out_code, 4, "HZ");
  }
  return true;
}

bool shouldDropVisibilityForPhenomenon(const char* phenomenon) {
  return strcmp(phenomenon, "FG") == 0 || strcmp(phenomenon, "SM") == 0 ||
         strcmp(phenomenon, "HZ") == 0;
}

void buildWindBlock(const interpolation::LocalEstimate& estimate, bool include_gust, char* out_block) {
  const int wind = roundedMpsTenthsToMph(estimate.wind_speed_mps_tenths);
  const int gust = roundedMpsTenthsToMph(estimate.wind_gust_mps_tenths);

  if (include_gust && gust > wind) {
    snprintf(out_block, 16, "W%dG%d", wind, gust);
    return;
  }

  snprintf(out_block, 16, "W%d", wind);
}

void buildLine1(const interpolation::LocalEstimate& estimate, char* out_line) {
  char visibility[4];
  char phenomenon[4];
  char wind[16];
  bool include_visibility = !visibilityMissing(estimate.visibility_m);
  bool include_phenomenon = phenomenonCode(estimate, phenomenon);
  bool include_gust = true;

  visibilityCode(estimate.visibility_m, visibility);
  buildWindBlock(estimate, include_gust, wind);

  char candidate[24];
  while (true) {
    candidate[0] = '\0';

    if (include_visibility) {
      snprintf(candidate + strlen(candidate), sizeof(candidate) - strlen(candidate), "%s",
               visibility);
    }
    if (include_phenomenon) {
      snprintf(candidate + strlen(candidate), sizeof(candidate) - strlen(candidate), "%s%s",
               candidate[0] == '\0' ? "" : " ", phenomenon);
    }
    snprintf(candidate + strlen(candidate), sizeof(candidate) - strlen(candidate), "%s%s",
             candidate[0] == '\0' ? "" : " ", wind);

    if (strlen(candidate) <= 16) {
      fitToDisplay(candidate, out_line);
      return;
    }

    if (include_gust) {
      include_gust = false;
      buildWindBlock(estimate, include_gust, wind);
      continue;
    }

    if (include_visibility && include_phenomenon && shouldDropVisibilityForPhenomenon(phenomenon)) {
      include_visibility = false;
      continue;
    }

    if (include_visibility && (strcmp(visibility, "V10") == 0 || strcmp(visibility, "V+") == 0)) {
      include_visibility = false;
      continue;
    }

    fitToDisplay(candidate, out_line);
    return;
  }
}

const char* interpretationText(const interpolation::LocalEstimate& estimate) {
  // Line 2 keeps a single dominant interpretation to preserve space for CXX%.
  const bool visibility_known = !visibilityMissing(estimate.visibility_m);
  if (hasHazard(estimate.hazard_flags, 0) || hasHazard(estimate.hazard_flags, 1)) {
    return "THUNDER";
  }
  if (estimate.precip_kind == 4 || hasHazard(estimate.hazard_flags, 5)) {
    return "ICE";
  }
  if (estimate.precip_kind == 2) {
    return "SNOW";
  }
  if (estimate.precip_kind == 1) {
    return "RAIN";
  }
  if (visibility_known && estimate.visibility_m < 1000) {
    return "FOG";
  }
  if (visibility_known && estimate.visibility_m < 3000) {
    return "SMOKE";
  }
  if (visibility_known && estimate.visibility_m < 8000) {
    return "HAZE";
  }
  if (estimate.precip_kind == 3 || estimate.precip_kind == 5 || estimate.precip_kind == 6 ||
      estimate.precip_kind == 255) {
    return "MIXED";
  }
  if (hasHazard(estimate.hazard_flags, 3)) {
    return "WINDY";
  }

  // Visibility can be missing in Block 1 packets. If no other strong signal is
  // present, keep line 2 neutral instead of inferring CLEAR or UNKNOWN.
  if (!visibility_known) {
    return "NO SIG";
  }

  return "CLEAR";
}

const char* resolvedInterpretation(const interpolation::LocalEstimate& estimate,
                                   const display_formatter::DisplayContext& context) {
  if (context.weather_age_minutes > kStaleThresholdMinutes) {
    return "DATA STALE";
  }
  return interpretationText(estimate);
}

void buildLine2(const interpolation::LocalEstimate& estimate,
                const display_formatter::DisplayContext& context, char* out_line) {
  char confidence[8];
  char interpretation[17];
  snprintf(interpretation, sizeof(interpretation), "%s", resolvedInterpretation(estimate, context));

  const bool stale = strcmp(interpretation, "DATA STALE") == 0;
  const bool suppress_confidence = stale;

  if (!suppress_confidence) {
    snprintf(confidence, sizeof(confidence), "C%u%%",
             static_cast<unsigned>(estimate.confidence_score));
  }

  const size_t confidence_length = suppress_confidence ? 0 : strlen(confidence);
  const size_t max_interpretation_length = suppress_confidence ? 16 : (16 - 1 - confidence_length);
  if (strlen(interpretation) > max_interpretation_length) {
    interpretation[max_interpretation_length] = '\0';
  }

  char candidate[24];
  if (suppress_confidence) {
    snprintf(candidate, sizeof(candidate), "%s", interpretation);
  } else {
    snprintf(candidate, sizeof(candidate), "%s %s", interpretation, confidence);
  }
  fitToDisplay(candidate, out_line);
}

}  // namespace

namespace display_formatter {

DisplayLines formatEstimate(const interpolation::LocalEstimate& estimate,
                           const DisplayContext& context) {
  DisplayLines lines = {};
  buildLine1(estimate, lines.line1);
  buildLine2(estimate, context, lines.line2);
  return lines;
}

void logDecision(const interpolation::LocalEstimate& estimate, const DisplayContext& context,
                 Stream& serial) {
  const bool vis_missing = visibilityMissing(estimate.visibility_m);
  char visibility[4];
  visibilityCode(estimate.visibility_m, visibility);
  serial.print("DISPLAY: decision visibility_m=");
  serial.print(estimate.visibility_m);
  serial.print(" visibility_mi=");
  if (vis_missing) {
    serial.print("NA");
  } else {
    serial.print(static_cast<double>(estimate.visibility_m) / kMetersPerStatuteMile, 2);
  }
  serial.print(" visibility_code=");
  if (vis_missing) {
    serial.print("UNK");
  } else {
    serial.print(visibility);
  }
  serial.print(" source=");
  serial.println(vis_missing ? "missing" : "reported");

  char phenomenon[4];
  const bool has_phenomenon = phenomenonCode(estimate, phenomenon);
  serial.print("DISPLAY: decision phenomenon=");
  serial.print(has_phenomenon ? phenomenon : "NONE");
  serial.print(" precip_kind=");
  serial.print(estimate.precip_kind);
  serial.print(" hazard=0x");
  serial.println(estimate.hazard_flags, HEX);

  const bool stale = context.weather_age_minutes > kStaleThresholdMinutes;
  const bool visibility_missing_only =
      vis_missing && estimate.precip_kind == 0 && estimate.hazard_flags == 0;
  serial.print("DISPLAY: decision weather_age_min=");
  serial.print(context.weather_age_minutes);
  serial.print(" stale_threshold_min=");
  serial.print(kStaleThresholdMinutes);
  serial.print(" stale=");
  serial.println(stale ? 1 : 0);
  serial.print("DISPLAY: decision visibility_missing_only=");
  serial.println(visibility_missing_only ? 1 : 0);

  const char* interpretation = resolvedInterpretation(estimate, context);
  const bool suppress_stale = strcmp(interpretation, "DATA STALE") == 0;
  const uint8_t shown_confidence = suppress_stale ? 0 : estimate.confidence_score;
  const char* suppression_reason = suppress_stale ? "stale" : "none";
  serial.print("DISPLAY: decision interpretation=");
  serial.print(interpretation);
  serial.print(" precedence=");
  if (suppress_stale) {
    serial.print("DATA_STALE");
  } else if (strcmp(interpretation, "THUNDER") == 0 || strcmp(interpretation, "ICE") == 0 ||
             strcmp(interpretation, "SNOW") == 0 || strcmp(interpretation, "RAIN") == 0 ||
             strcmp(interpretation, "FOG") == 0 || strcmp(interpretation, "SMOKE") == 0 ||
             strcmp(interpretation, "HAZE") == 0 || strcmp(interpretation, "MIXED") == 0 ||
             strcmp(interpretation, "WINDY") == 0) {
    serial.print("WEATHER_SIGNAL");
  } else if (strcmp(interpretation, "NO SIG") == 0) {
    serial.print("NEUTRAL");
  } else {
    serial.print("CLEAR");
  }
  serial.println();
  serial.print("DISPLAY: decision confidence_raw=");
  serial.print(estimate.confidence_score);
  serial.print(" confidence_shown=");
  serial.print(shown_confidence);
  serial.print(" suppression_reason=");
  serial.println(suppression_reason);
}

}  // namespace display_formatter
