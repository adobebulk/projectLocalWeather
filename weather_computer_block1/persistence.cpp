#include "persistence.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>

#include "device_state.h"

namespace {

constexpr char kNamespace[] = "wcblock1";
constexpr char kWeatherSlot0Key[] = "wx0";
constexpr char kWeatherSlot1Key[] = "wx1";
constexpr char kPositionSlot0Key[] = "ps0";
constexpr char kPositionSlot1Key[] = "ps1";

constexpr uint32_t kRecordMagic = 0x57435244UL;
constexpr uint16_t kRecordVersion = 1;

struct RecordHeader {
  uint32_t magic;
  uint16_t record_version;
  uint16_t payload_size;
  uint32_t generation;
  uint32_t payload_crc32;
};

template <typename Payload>
struct PersistRecord {
  RecordHeader header;
  Payload payload;
};

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

uint32_t computePayloadCrc32(const uint8_t* data, size_t length) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (size_t i = 0; i < length; ++i) {
    crc = crc32Update(crc, data[i]);
  }
  return crc ^ 0xFFFFFFFFUL;
}

template <typename Payload>
bool validateRecord(const PersistRecord<Payload>& record) {
  if (record.header.magic != kRecordMagic) {
    return false;
  }
  if (record.header.record_version != kRecordVersion) {
    return false;
  }
  if (record.header.payload_size != sizeof(Payload)) {
    return false;
  }

  const uint32_t expected_crc = computePayloadCrc32(
      reinterpret_cast<const uint8_t*>(&record.payload), sizeof(Payload));
  return expected_crc == record.header.payload_crc32;
}

bool validateStoredWeather(const protocol_parser::RegionalSnapshotV1& weather) {
  return weather.header.magic == protocol_parser::kMagic &&
         weather.header.version == protocol_parser::kVersion &&
         weather.header.packet_type == protocol_parser::kPacketTypeRegionalSnapshotV1 &&
         weather.header.total_length == protocol_parser::kRegionalSnapshotPacketSize;
}

bool validateStoredPosition(const protocol_parser::PositionUpdateV1& position) {
  return position.header.magic == protocol_parser::kMagic &&
         position.header.version == protocol_parser::kVersion &&
         position.header.packet_type == protocol_parser::kPacketTypePositionUpdateV1 &&
         position.header.total_length == protocol_parser::kPositionUpdatePacketSize;
}

template <typename Payload>
bool readSlot(Preferences* preferences, const char* key, PersistRecord<Payload>* out_record) {
  if (preferences->getBytesLength(key) != sizeof(PersistRecord<Payload>)) {
    return false;
  }

  if (preferences->getBytes(key, out_record, sizeof(PersistRecord<Payload>)) !=
      sizeof(PersistRecord<Payload>)) {
    return false;
  }

  return validateRecord(*out_record);
}

template <typename Payload>
bool writeRecord(Preferences* preferences, const char* key, uint32_t generation,
                 const Payload& payload) {
  PersistRecord<Payload> record = {};
  record.header.magic = kRecordMagic;
  record.header.record_version = kRecordVersion;
  record.header.payload_size = sizeof(Payload);
  record.header.generation = generation;
  record.payload = payload;
  record.header.payload_crc32 = computePayloadCrc32(
      reinterpret_cast<const uint8_t*>(&record.payload), sizeof(Payload));

  return preferences->putBytes(key, &record, sizeof(record)) == sizeof(record);
}

template <typename Payload>
bool saveWithTwoSlots(const char* key0, const char* key1, const Payload& payload) {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) {
    return false;
  }

  PersistRecord<Payload> slot0 = {};
  PersistRecord<Payload> slot1 = {};
  const bool slot0_valid = readSlot(&preferences, key0, &slot0);
  const bool slot1_valid = readSlot(&preferences, key1, &slot1);

  uint32_t next_generation = 1;
  const char* target_key = key0;

  if (slot0_valid && slot1_valid) {
    next_generation =
        (slot0.header.generation > slot1.header.generation ? slot0.header.generation
                                                           : slot1.header.generation) +
        1;
    target_key = slot0.header.generation <= slot1.header.generation ? key0 : key1;
  } else if (slot0_valid) {
    next_generation = slot0.header.generation + 1;
    target_key = key1;
  } else if (slot1_valid) {
    next_generation = slot1.header.generation + 1;
    target_key = key0;
  }

  const bool success = writeRecord(&preferences, target_key, next_generation, payload);
  preferences.end();
  return success;
}

template <typename Payload>
bool restoreWithTwoSlots(const char* key0, const char* key1, Payload* out_payload) {
  Preferences preferences;
  if (!preferences.begin(kNamespace, true)) {
    return false;
  }

  PersistRecord<Payload> slot0 = {};
  PersistRecord<Payload> slot1 = {};
  const bool slot0_valid = readSlot(&preferences, key0, &slot0);
  const bool slot1_valid = readSlot(&preferences, key1, &slot1);
  preferences.end();

  if (!slot0_valid && !slot1_valid) {
    return false;
  }

  if (slot0_valid && (!slot1_valid || slot0.header.generation >= slot1.header.generation)) {
    *out_payload = slot0.payload;
    return true;
  }

  *out_payload = slot1.payload;
  return true;
}

}  // namespace

namespace persistence {

bool saveWeatherSnapshot(const protocol_parser::RegionalSnapshotV1& weather, Stream& serial) {
  if (!saveWithTwoSlots(kWeatherSlot0Key, kWeatherSlot1Key, weather)) {
    serial.println("PERSIST: weather save failure");
    return false;
  }

  serial.println("PERSIST: weather save success");
  return true;
}

bool savePositionUpdate(const protocol_parser::PositionUpdateV1& position, Stream& serial) {
  if (!saveWithTwoSlots(kPositionSlot0Key, kPositionSlot1Key, position)) {
    serial.println("PERSIST: position save failure");
    return false;
  }

  serial.println("PERSIST: position save success");
  return true;
}

void restoreDeviceState(Stream& serial) {
  device_state::DeviceState* state = device_state::mutableState();

  protocol_parser::RegionalSnapshotV1 restored_weather = {};
  if (restoreWithTwoSlots(kWeatherSlot0Key, kWeatherSlot1Key, &restored_weather) &&
      validateStoredWeather(restored_weather)) {
    state->weather = restored_weather;
    state->weather_timestamp = restored_weather.header.timestamp_unix;
    state->has_weather = true;
    serial.println("PERSIST: weather restore success");
  } else {
    state->has_weather = false;
    serial.println("PERSIST: no valid weather record");
  }

  protocol_parser::PositionUpdateV1 restored_position = {};
  if (restoreWithTwoSlots(kPositionSlot0Key, kPositionSlot1Key, &restored_position) &&
      validateStoredPosition(restored_position)) {
    state->position = restored_position;
    state->position_timestamp = restored_position.header.timestamp_unix;
    state->has_position = true;
    serial.println("PERSIST: position restore success");
  } else {
    state->has_position = false;
    serial.println("PERSIST: no valid position record");
  }

  serial.println("PERSIST: restore complete");
}

}  // namespace persistence
