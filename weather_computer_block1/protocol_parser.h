#ifndef WEATHER_COMPUTER_PROTOCOL_PARSER_H
#define WEATHER_COMPUTER_PROTOCOL_PARSER_H

#include <Arduino.h>

namespace protocol_parser {

constexpr uint16_t kMagic = 0x5743;
constexpr uint8_t kVersion = 1;
constexpr uint8_t kPacketTypeRegionalSnapshotV1 = 1;
constexpr uint8_t kPacketTypePositionUpdateV1 = 2;
constexpr uint8_t kPacketTypeAckV1 = 3;
constexpr uint8_t kPacketTypeDisplayControlV1 = 4;

constexpr size_t kHeaderSize = 18;
constexpr size_t kRegionalSnapshotPacketSize = 470;
constexpr size_t kPositionUpdatePacketSize = 32;
constexpr size_t kAckPacketSize = 32;
constexpr size_t kAnchorCount = 9;
constexpr size_t kSlotCount = 3;

enum ParseStatus {
  kParseOk = 0,
  kParseBadMagic,
  kParseBadVersion,
  kParseBadLength,
  kParseBadCrc,
  kParseUnknownPacketType,
};

struct __attribute__((packed)) PacketHeader {
  uint16_t magic;
  uint8_t version;
  uint8_t packet_type;
  uint16_t total_length;
  uint32_t sequence;
  uint32_t timestamp_unix;
  uint32_t checksum_crc32;
};

struct __attribute__((packed)) PositionUpdateV1 {
  PacketHeader header;
  int32_t lat_e5;
  int32_t lon_e5;
  uint16_t accuracy_m;
  uint32_t fix_timestamp_unix;
};

struct __attribute__((packed)) AckV1 {
  PacketHeader header;
  uint32_t echoed_sequence;
  uint8_t status_code;
  uint32_t active_weather_timestamp_unix;
  uint32_t active_position_timestamp_unix;
  uint8_t reserved;
};

struct __attribute__((packed)) DisplayControlV1 {
  PacketHeader header;
  uint8_t command;
  uint8_t reserved[13];
};

struct __attribute__((packed)) RegionalSnapshotMetadataV1 {
  int32_t field_center_lat_e5;
  int32_t field_center_lon_e5;
  uint16_t field_width_mi;
  uint16_t field_height_mi;
  uint8_t grid_rows;
  uint8_t grid_cols;
  uint8_t slot_count;
  uint8_t reserved0;
  uint16_t forecast_horizon_min;
  uint16_t source_age_min;
};

struct __attribute__((packed)) WeatherSlot {
  uint16_t slot_offset_min;
  int16_t air_temp_c_tenths;
  uint16_t wind_speed_mps_tenths;
  uint16_t wind_gust_mps_tenths;
  uint8_t precip_prob_pct;
  uint8_t precip_kind;
  uint8_t precip_intensity;
  uint8_t reserved0;
  uint16_t visibility_m;
  uint16_t hazard_flags;
};

struct __attribute__((packed)) RegionalSnapshotV1 {
  PacketHeader header;
  RegionalSnapshotMetadataV1 metadata;
  WeatherSlot anchor_slots[kAnchorCount][kSlotCount];
};

struct ParseResult {
  ParseStatus status;
  PacketHeader header;
  PositionUpdateV1 position;
  AckV1 ack;
  DisplayControlV1 display_control;
  RegionalSnapshotV1 regional_snapshot;
};

ParseResult parsePacket(const uint8_t* packet, size_t length);
const char* statusToLogMessage(ParseStatus status, uint8_t packet_type);

static_assert(sizeof(PacketHeader) == kHeaderSize, "PacketHeader size must match protocol");
static_assert(sizeof(PositionUpdateV1) == kPositionUpdatePacketSize,
              "PositionUpdateV1 size must match protocol");
static_assert(sizeof(AckV1) == kAckPacketSize, "AckV1 size must match protocol");
static_assert(sizeof(DisplayControlV1) == kAckPacketSize,
              "DisplayControlV1 size must match protocol");
static_assert(sizeof(RegionalSnapshotMetadataV1) == 20,
              "RegionalSnapshotMetadataV1 size must match protocol");
static_assert(sizeof(WeatherSlot) == 16, "WeatherSlot size must match protocol");
static_assert(sizeof(RegionalSnapshotV1) == kRegionalSnapshotPacketSize,
              "RegionalSnapshotV1 size must match protocol");

}  // namespace protocol_parser

#endif  // WEATHER_COMPUTER_PROTOCOL_PARSER_H
