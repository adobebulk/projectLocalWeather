#include "display_formatter.h"

#include <Arduino.h>
#include <stdio.h>
#include <string.h>

namespace {

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

int roundedUnsignedTenthsToWhole(uint16_t value_tenths) {
  return (static_cast<int>(value_tenths) + 5) / 10;
}

bool hasHazard(uint16_t hazard_flags, uint8_t bit_index) {
  return (hazard_flags & (1U << bit_index)) != 0U;
}

const char* visibilityCode(uint16_t visibility_m) {
  if (visibility_m < 1000) {
    return "VL";
  }
  if (visibility_m < 3000) {
    return "V2";
  }
  if (visibility_m < 8000) {
    return "V5";
  }
  return "V10";
}

char intensityMarker(uint8_t precip_intensity) {
  if (precip_intensity == 1) {
    return '-';
  }
  if (precip_intensity >= 3 && precip_intensity != 255) {
    return '+';
  }
  return '\0';
}

bool phenomenonCode(const interpolation::LocalEstimate& estimate, char* out_code) {
  // Hazard mapping is intentionally conservative: any thunder-related flag
  // takes precedence over precip-kind-derived phenomena on Line 1.
  const bool thunder = hasHazard(estimate.hazard_flags, 0) || hasHazard(estimate.hazard_flags, 1);
  const bool icing = estimate.precip_kind == 4 || hasHazard(estimate.hazard_flags, 5);
  const bool snow = estimate.precip_kind == 2;
  const bool rain = estimate.precip_kind == 1;
  const bool fog = estimate.visibility_m < 1000;
  const bool smoke = estimate.visibility_m >= 1000 && estimate.visibility_m < 3000;
  const bool haze = estimate.visibility_m >= 3000 && estimate.visibility_m < 8000;
  const bool mixed = estimate.precip_kind == 3 || estimate.precip_kind == 5 ||
                     estimate.precip_kind == 6 || estimate.precip_kind == 255;

  const char* base_code = "";
  if (thunder) {
    base_code = "TS";
  } else if (icing) {
    base_code = "IC";
  } else if (snow) {
    base_code = "SN";
  } else if (rain) {
    base_code = "RA";
  } else if (fog) {
    base_code = "FG";
  } else if (smoke) {
    base_code = "SM";
  } else if (haze) {
    base_code = "HZ";
  } else if (mixed) {
    base_code = "MX";
  } else {
    out_code[0] = '\0';
    return false;
  }

  const char marker = intensityMarker(estimate.precip_intensity);
  if (marker != '\0' && (strcmp(base_code, "RA") == 0 || strcmp(base_code, "SN") == 0 ||
                         strcmp(base_code, "IC") == 0 || strcmp(base_code, "MX") == 0)) {
    out_code[0] = marker;
    out_code[1] = base_code[0];
    out_code[2] = base_code[1];
    out_code[3] = '\0';
  } else {
    out_code[0] = base_code[0];
    out_code[1] = base_code[1];
    out_code[2] = '\0';
  }

  return true;
}

bool shouldDropVisibilityForPhenomenon(const char* phenomenon) {
  return strcmp(phenomenon, "FG") == 0 || strcmp(phenomenon, "SM") == 0 ||
         strcmp(phenomenon, "HZ") == 0;
}

void buildWindBlock(const interpolation::LocalEstimate& estimate, bool include_gust, char* out_block) {
  const int wind = roundedUnsignedTenthsToWhole(estimate.wind_speed_mps_tenths);
  const int gust = roundedUnsignedTenthsToWhole(estimate.wind_gust_mps_tenths);

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
  bool include_visibility = true;
  bool include_phenomenon = phenomenonCode(estimate, phenomenon);
  bool include_gust = true;

  snprintf(visibility, sizeof(visibility), "%s", visibilityCode(estimate.visibility_m));
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

    if (include_visibility && (strcmp(visibility, "V10") == 0 || strcmp(visibility, "V5") == 0)) {
      include_visibility = false;
      continue;
    }

    fitToDisplay(candidate, out_line);
    return;
  }
}

const char* interpretationText(const interpolation::LocalEstimate& estimate) {
  // Line 2 keeps a single dominant interpretation to preserve space for CXX%.
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
  if (estimate.visibility_m < 1000) {
    return "FOG";
  }
  if (estimate.visibility_m < 3000) {
    return "SMOKE";
  }
  if (estimate.visibility_m < 8000) {
    return "HAZE";
  }
  if (estimate.precip_kind == 3 || estimate.precip_kind == 5 || estimate.precip_kind == 6 ||
      estimate.precip_kind == 255) {
    return "MIXED";
  }
  if (hasHazard(estimate.hazard_flags, 3)) {
    return "WINDY";
  }
  return "CLEAR";
}

void buildLine2(const interpolation::LocalEstimate& estimate, char* out_line) {
  char confidence[8];
  char interpretation[17];
  snprintf(confidence, sizeof(confidence), "C%u%%",
           static_cast<unsigned>(estimate.confidence_score));
  snprintf(interpretation, sizeof(interpretation), "%s", interpretationText(estimate));

  const size_t confidence_length = strlen(confidence);
  const size_t max_interpretation_length = 16 - 1 - confidence_length;
  if (strlen(interpretation) > max_interpretation_length) {
    interpretation[max_interpretation_length] = '\0';
  }

  char candidate[24];
  snprintf(candidate, sizeof(candidate), "%s %s", interpretation, confidence);
  fitToDisplay(candidate, out_line);
}

}  // namespace

namespace display_formatter {

DisplayLines formatEstimate(const interpolation::LocalEstimate& estimate) {
  DisplayLines lines = {};
  buildLine1(estimate, lines.line1);
  buildLine2(estimate, lines.line2);
  return lines;
}

}  // namespace display_formatter
