#include "ingress_router.h"

#include "display_driver.h"
#include "display_formatter.h"
#include "device_state.h"
#include "interpolation.h"
#include "persistence.h"

namespace {

void logEstimate(const interpolation::LocalEstimate& estimate, Stream& serial) {
  char line[96];
  snprintf(line, sizeof(line),
           "ESTIMATE: temp_t10=%d wind_t10=%u gust_t10=%u precip_pct=%u kind=%u intensity=%u",
           estimate.air_temp_c_tenths, estimate.wind_speed_mps_tenths,
           estimate.wind_gust_mps_tenths, estimate.precip_prob_pct, estimate.precip_kind,
           estimate.precip_intensity);
  serial.println(line);

  snprintf(line, sizeof(line), "ESTIMATE: vis_m=%u hazard=0x%X confidence=%u",
           estimate.visibility_m, estimate.hazard_flags, estimate.confidence_score);
  serial.println(line);
}

void updateRuntimeDisplay(const interpolation::LocalEstimate& estimate, Stream& serial) {
  if (!display_driver::isReady()) {
    serial.println("DISPLAY: runtime update skipped, LCD not ready");
    return;
  }

  const display_formatter::DisplayLines lines = display_formatter::formatEstimate(estimate);
  serial.println("DISPLAY: runtime update start");
  serial.print("DISPLAY: line1=");
  serial.println(lines.line1);
  serial.print("DISPLAY: line2=");
  serial.println(lines.line2);

  if (display_driver::writeLines(lines.line1, lines.line2)) {
    serial.println("DISPLAY: runtime update success");
    return;
  }

  serial.println("DISPLAY: runtime update failure");
}

void recomputeEstimate(device_state::DeviceState* state, Stream& serial) {
  if (!state->has_position || !state->has_weather) {
    return;
  }

  const uint32_t recompute_timestamp =
      state->weather_timestamp > state->position_timestamp ? state->weather_timestamp
                                                           : state->position_timestamp;

  serial.println("ESTIMATE: recompute start");
  interpolation::LocalEstimate estimate = {};
  const interpolation::InterpolationStatus status =
      interpolation::estimateLocalConditions(state->weather, state->position, recompute_timestamp,
                                             &estimate);

  if (status != interpolation::kInterpolationOk) {
    state->has_estimate = false;
    state->estimate_timestamp = recompute_timestamp;
    serial.print("ESTIMATE: failed ");
    serial.println(interpolation::statusToString(status));
    return;
  }

  state->estimate = estimate;
  state->has_estimate = true;
  state->estimate_timestamp = recompute_timestamp;
  serial.println("ESTIMATE: success");
  logEstimate(state->estimate, serial);
  updateRuntimeDisplay(state->estimate, serial);
}

}  // namespace

namespace ingress_router {

void handlePacket(const protocol_parser::ParseResult& result, Stream& serial) {
  if (result.status != protocol_parser::kParseOk) {
    return;
  }

  device_state::DeviceState* state = device_state::mutableState();

  if (result.header.packet_type == protocol_parser::kPacketTypePositionUpdateV1) {
    state->position = result.position;
    state->position_timestamp = result.position.header.timestamp_unix;
    state->has_position = true;
    serial.println("INGRESS: stored position update");
    persistence::savePositionUpdate(state->position, serial);
    recomputeEstimate(state, serial);
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeRegionalSnapshotV1) {
    state->weather = result.regional_snapshot;
    state->weather_timestamp = result.regional_snapshot.header.timestamp_unix;
    state->has_weather = true;
    serial.println("INGRESS: stored weather snapshot");
    persistence::saveWeatherSnapshot(state->weather, serial);
    recomputeEstimate(state, serial);
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeAckV1) {
    serial.println("INGRESS: ack ignored");
    return;
  }
}

void recomputeFromState(Stream& serial) {
  recomputeEstimate(device_state::mutableState(), serial);
}

}  // namespace ingress_router
