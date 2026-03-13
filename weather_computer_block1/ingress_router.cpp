#include "ingress_router.h"

#include "device_state.h"

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
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeRegionalSnapshotV1) {
    state->weather = result.regional_snapshot;
    state->weather_timestamp = result.regional_snapshot.header.timestamp_unix;
    state->has_weather = true;
    serial.println("INGRESS: stored weather snapshot");
    return;
  }

  if (result.header.packet_type == protocol_parser::kPacketTypeAckV1) {
    serial.println("INGRESS: ack ignored");
    return;
  }
}

}  // namespace ingress_router
