#include "protocol_parser.h"

#include <Arduino.h>

namespace {

constexpr size_t kMagicOffset = 0;
constexpr size_t kVersionOffset = 2;
constexpr size_t kPacketTypeOffset = 3;
constexpr size_t kTotalLengthOffset = 4;
constexpr size_t kSequenceOffset = 6;
constexpr size_t kTimestampOffset = 10;
constexpr size_t kCrcOffset = 14;

constexpr size_t kPositionPayloadOffset = protocol_parser::kHeaderSize;
constexpr size_t kAckPayloadOffset = protocol_parser::kHeaderSize;
constexpr size_t kRegionalMetadataOffset = protocol_parser::kHeaderSize;
constexpr size_t kRegionalSlotOffset = protocol_parser::kHeaderSize + 20;
constexpr size_t kWeatherSlotSize = 16;

uint16_t readU16(const uint8_t* data, size_t offset) {
  return static_cast<uint16_t>(data[offset]) |
         (static_cast<uint16_t>(data[offset + 1]) << 8);
}

uint32_t readU32(const uint8_t* data, size_t offset) {
  return static_cast<uint32_t>(data[offset]) |
         (static_cast<uint32_t>(data[offset + 1]) << 8) |
         (static_cast<uint32_t>(data[offset + 2]) << 16) |
         (static_cast<uint32_t>(data[offset + 3]) << 24);
}

int32_t readI32(const uint8_t* data, size_t offset) {
  return static_cast<int32_t>(readU32(data, offset));
}

int16_t readI16(const uint8_t* data, size_t offset) {
  return static_cast<int16_t>(readU16(data, offset));
}

uint32_t crc32Update(uint32_t crc, uint8_t data_byte) {
  crc ^= static_cast<uint32_t>(data_byte);
  for (uint8_t bit = 0; bit < 8; ++bit) {
    if ((crc & 1U) != 0U) {
      crc = (crc >> 1) ^ 0xEDB88320UL;
    } else {
      crc >>= 1;
    }
  }
  return crc;
}

uint32_t computePacketCrc32(const uint8_t* packet, size_t length) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (size_t i = 0; i < length; ++i) {
    uint8_t data_byte = packet[i];
    if (i >= kCrcOffset && i < (kCrcOffset + 4)) {
      data_byte = 0;
    }
    crc = crc32Update(crc, data_byte);
  }
  return crc ^ 0xFFFFFFFFUL;
}

size_t expectedPacketSize(uint8_t packet_type) {
  if (packet_type == protocol_parser::kPacketTypeRegionalSnapshotV1) {
    return protocol_parser::kRegionalSnapshotPacketSize;
  }
  if (packet_type == protocol_parser::kPacketTypePositionUpdateV1) {
    return protocol_parser::kPositionUpdatePacketSize;
  }
  if (packet_type == protocol_parser::kPacketTypeAckV1) {
    return protocol_parser::kAckPacketSize;
  }
  if (packet_type == protocol_parser::kPacketTypeDisplayControlV1) {
    return protocol_parser::kAckPacketSize;
  }
  return 0;
}

protocol_parser::PacketHeader parseHeader(const uint8_t* packet) {
  protocol_parser::PacketHeader header = {};
  header.magic = readU16(packet, kMagicOffset);
  header.version = packet[kVersionOffset];
  header.packet_type = packet[kPacketTypeOffset];
  header.total_length = readU16(packet, kTotalLengthOffset);
  header.sequence = readU32(packet, kSequenceOffset);
  header.timestamp_unix = readU32(packet, kTimestampOffset);
  header.checksum_crc32 = readU32(packet, kCrcOffset);
  return header;
}

void parsePosition(protocol_parser::PositionUpdateV1* position, const uint8_t* packet) {
  position->lat_e5 = readI32(packet, kPositionPayloadOffset + 0);
  position->lon_e5 = readI32(packet, kPositionPayloadOffset + 4);
  position->accuracy_m = readU16(packet, kPositionPayloadOffset + 8);
  position->fix_timestamp_unix = readU32(packet, kPositionPayloadOffset + 10);
}

void parseAck(protocol_parser::AckV1* ack, const uint8_t* packet) {
  ack->echoed_sequence = readU32(packet, kAckPayloadOffset + 0);
  ack->status_code = packet[kAckPayloadOffset + 4];
  ack->active_weather_timestamp_unix = readU32(packet, kAckPayloadOffset + 5);
  ack->active_position_timestamp_unix = readU32(packet, kAckPayloadOffset + 9);
  ack->reserved = packet[kAckPayloadOffset + 13];
}

void parseDisplayControl(protocol_parser::DisplayControlV1* display_control, const uint8_t* packet) {
  display_control->command = packet[kAckPayloadOffset + 0];
  for (size_t i = 0; i < sizeof(display_control->reserved); ++i) {
    display_control->reserved[i] = packet[kAckPayloadOffset + 1 + i];
  }
}

void parseRegionalSnapshot(protocol_parser::RegionalSnapshotV1* snapshot, const uint8_t* packet) {
  snapshot->metadata.field_center_lat_e5 = readI32(packet, kRegionalMetadataOffset + 0);
  snapshot->metadata.field_center_lon_e5 = readI32(packet, kRegionalMetadataOffset + 4);
  snapshot->metadata.field_width_mi = readU16(packet, kRegionalMetadataOffset + 8);
  snapshot->metadata.field_height_mi = readU16(packet, kRegionalMetadataOffset + 10);
  snapshot->metadata.grid_rows = packet[kRegionalMetadataOffset + 12];
  snapshot->metadata.grid_cols = packet[kRegionalMetadataOffset + 13];
  snapshot->metadata.slot_count = packet[kRegionalMetadataOffset + 14];
  snapshot->metadata.reserved0 = packet[kRegionalMetadataOffset + 15];
  snapshot->metadata.forecast_horizon_min = readU16(packet, kRegionalMetadataOffset + 16);
  snapshot->metadata.source_age_min = readU16(packet, kRegionalMetadataOffset + 18);

  size_t offset = kRegionalSlotOffset;
  for (size_t anchor_index = 0; anchor_index < protocol_parser::kAnchorCount; ++anchor_index) {
    for (size_t slot_index = 0; slot_index < protocol_parser::kSlotCount; ++slot_index) {
      protocol_parser::WeatherSlot* slot =
          &snapshot->anchor_slots[anchor_index][slot_index];
      slot->slot_offset_min = readU16(packet, offset + 0);
      slot->air_temp_c_tenths = readI16(packet, offset + 2);
      slot->wind_speed_mps_tenths = readU16(packet, offset + 4);
      slot->wind_gust_mps_tenths = readU16(packet, offset + 6);
      slot->precip_prob_pct = packet[offset + 8];
      slot->precip_kind = packet[offset + 9];
      slot->precip_intensity = packet[offset + 10];
      slot->reserved0 = packet[offset + 11];
      slot->visibility_m = readU16(packet, offset + 12);
      slot->hazard_flags = readU16(packet, offset + 14);
      offset += kWeatherSlotSize;
    }
  }
}

}  // namespace

namespace protocol_parser {

ParseResult parsePacket(const uint8_t* packet, size_t length) {
  ParseResult result = {};
  result.status = kParseBadLength;

  if (packet == nullptr || length < kHeaderSize) {
    return result;
  }

  result.header = parseHeader(packet);

  if (result.header.magic != kMagic) {
    result.status = kParseBadMagic;
    return result;
  }

  if (result.header.version != kVersion) {
    result.status = kParseBadVersion;
    return result;
  }

  const size_t expected_size = expectedPacketSize(result.header.packet_type);
  if (expected_size == 0) {
    result.status = kParseUnknownPacketType;
    return result;
  }

  if (result.header.total_length != expected_size || length != expected_size) {
    result.status = kParseBadLength;
    return result;
  }

  const uint32_t computed_crc = computePacketCrc32(packet, length);
  if (computed_crc != result.header.checksum_crc32) {
    result.status = kParseBadCrc;
    return result;
  }

  if (result.header.packet_type == kPacketTypePositionUpdateV1) {
    result.position.header = result.header;
    parsePosition(&result.position, packet);
    result.status = kParseOk;
    return result;
  }

  if (result.header.packet_type == kPacketTypeAckV1) {
    result.ack.header = result.header;
    parseAck(&result.ack, packet);
    result.status = kParseOk;
    return result;
  }

  if (result.header.packet_type == kPacketTypeDisplayControlV1) {
    result.display_control.header = result.header;
    parseDisplayControl(&result.display_control, packet);
    result.status = kParseOk;
    return result;
  }

  result.regional_snapshot.header = result.header;
  parseRegionalSnapshot(&result.regional_snapshot, packet);
  result.status = kParseOk;
  return result;
}

const char* statusToLogMessage(ParseStatus status, uint8_t packet_type) {
  if (status == kParseOk) {
    if (packet_type == kPacketTypePositionUpdateV1) {
      return "PARSER: position packet valid";
    }
    if (packet_type == kPacketTypeAckV1) {
      return "PARSER: ack packet valid";
    }
    if (packet_type == kPacketTypeRegionalSnapshotV1) {
      return "PARSER: weather packet valid";
    }
    if (packet_type == kPacketTypeDisplayControlV1) {
      return "PARSER: display control packet valid";
    }
    return "PARSER: unknown packet type";
  }

  if (status == kParseBadMagic) {
    return "PARSER: bad magic";
  }
  if (status == kParseBadVersion) {
    return "PARSER: bad version";
  }
  if (status == kParseBadLength) {
    return "PARSER: bad length";
  }
  if (status == kParseBadCrc) {
    return "PARSER: bad crc";
  }
  return "PARSER: unknown packet type";
}

}  // namespace protocol_parser
