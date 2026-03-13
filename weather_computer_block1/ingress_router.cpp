#include "ingress_router.h"

#include "display_driver.h"
#include "display_formatter.h"
#include "device_state.h"
#include "interpolation.h"

namespace {

void logEstimate(const interpolation::LocalEstimate& estimate, Stream& serial) {
  serial.print("ESTIMATE: temp_t10=");
  serial.print(estimate.air_temp_c_tenths);
  serial.print(" wind_t10=");
  serial.print(estimate.wind_speed_mps_tenths);
  serial.print(" gust_t10=");
  serial.print(estimate.wind_gust_mps_tenths);
  serial.print(" precip_pct=");
  serial.print(estimate.precip_prob_pct);
  serial.print(" kind=");
  serial.print(estimate.precip_kind);
  serial.print(" intensity=");
  serial.println(estimate.precip_intensity);

  serial.print("ESTIMATE: vis_m=");
  serial.print(estimate.visibility_m);
  serial.print(" hazard=0x");
  serial.print(estimate.hazard_flags, HEX);
  serial.print(" confidence=");
  serial.println(estimate.confidence_score);
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
    recomputeEstimate(state, serial);
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeRegionalSnapshotV1) {
    state->weather = result.regional_snapshot;
    state->weather_timestamp = result.regional_snapshot.header.timestamp_unix;
    state->has_weather = true;
    serial.println("INGRESS: stored weather snapshot");
    recomputeEstimate(state, serial);
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeAckV1) {
    serial.println("INGRESS: ack ignored");
    return;
  }
}

}  // namespace ingress_router
