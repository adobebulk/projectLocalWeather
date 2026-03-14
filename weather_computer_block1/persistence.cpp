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

struct __attribute__((packed)) RecordHeader {
  uint32_t magic;
  uint16_t record_version;
  uint16_t payload_size;
  uint32_t generation;
  uint32_t payload_crc32;
};

template <typename Payload>
struct __attribute__((packed)) PersistRecord {
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

static_assert(sizeof(protocol_parser::RegionalSnapshotV1) ==
                  protocol_parser::kRegionalSnapshotPacketSize,
              "RegionalSnapshotV1 must remain byte-identical to protocol packet size");
static_assert(sizeof(protocol_parser::PositionUpdateV1) ==
                  protocol_parser::kPositionUpdatePacketSize,
              "PositionUpdateV1 must remain byte-identical to protocol packet size");
static_assert(sizeof(RecordHeader) == 16, "RecordHeader size must remain 16 bytes");
static_assert(sizeof(PersistRecord<protocol_parser::PositionUpdateV1>) == 48,
              "Persisted PositionUpdateV1 record must remain 48 bytes");
static_assert(sizeof(PersistRecord<protocol_parser::RegionalSnapshotV1>) == 486,
              "Persisted RegionalSnapshotV1 record must remain 486 bytes");

const char* parseStatusLabel(protocol_parser::ParseStatus status) {
  if (status == protocol_parser::kParseBadMagic) {
    return "bad magic";
  }
  if (status == protocol_parser::kParseBadVersion) {
    return "bad version";
  }
  if (status == protocol_parser::kParseBadLength) {
    return "bad length";
  }
  if (status == protocol_parser::kParseBadCrc) {
    return "bad crc";
  }
  if (status == protocol_parser::kParseUnknownPacketType) {
    return "unknown packet type";
  }
  return "parse failure";
}

template <typename Payload>
protocol_parser::ParseResult parseStoredPayload(const Payload& payload) {
  return protocol_parser::parsePacket(reinterpret_cast<const uint8_t*>(&payload),
                                      sizeof(Payload));
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
                 const Payload& payload, const char* record_name, Stream& serial) {
  PersistRecord<Payload> record = {};
  record.header.magic = kRecordMagic;
  record.header.record_version = kRecordVersion;
  record.header.payload_size = sizeof(Payload);
  record.header.generation = generation;
  record.payload = payload;
  record.header.payload_crc32 = computePayloadCrc32(
      reinterpret_cast<const uint8_t*>(&record.payload), sizeof(Payload));

  serial.print("PERSIST: ");
  serial.print(record_name);
  serial.print(" write start key=");
  serial.print(key);
  serial.print(" gen=");
  serial.print(generation);
  serial.print(" payload_bytes=");
  serial.print(sizeof(Payload));
  serial.print(" record_bytes=");
  serial.println(sizeof(record));

  return preferences->putBytes(key, &record, sizeof(record)) == sizeof(record);
}

template <typename Payload>
bool saveWithTwoSlots(const char* key0, const char* key1, const Payload& payload,
                      const char* record_name, Stream& serial) {
  Preferences preferences;
  serial.print("PERSIST: ");
  serial.print(record_name);
  serial.println(" save start");
  if (!preferences.begin(kNamespace, false)) {
    serial.print("PERSIST: ");
    serial.print(record_name);
    serial.println(" NVS open failure");
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

  const bool success =
      writeRecord(&preferences, target_key, next_generation, payload, record_name, serial);
  preferences.end();
  serial.print("PERSIST: ");
  serial.print(record_name);
  serial.println(" save end");
  return success;
}

template <typename Payload>
bool restoreWithTwoSlots(const char* key0, const char* key1, Payload* out_payload,
                         const char* record_name, Stream& serial) {
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

  bool slot0_protocol_valid = false;
  bool slot1_protocol_valid = false;

  if (slot0_valid) {
    const protocol_parser::ParseResult parsed = parseStoredPayload(slot0.payload);
    slot0_protocol_valid = parsed.status == protocol_parser::kParseOk;
    if (!slot0_protocol_valid) {
      serial.print("PERSIST: ");
      serial.print(record_name);
      serial.print(" slot 0 validation failed: ");
      serial.println(parseStatusLabel(parsed.status));
    }
  }

  if (slot1_valid) {
    const protocol_parser::ParseResult parsed = parseStoredPayload(slot1.payload);
    slot1_protocol_valid = parsed.status == protocol_parser::kParseOk;
    if (!slot1_protocol_valid) {
      serial.print("PERSIST: ");
      serial.print(record_name);
      serial.print(" slot 1 validation failed: ");
      serial.println(parseStatusLabel(parsed.status));
    }
  }

  if (!slot0_protocol_valid && !slot1_protocol_valid) {
    return false;
  }

  if (slot0_protocol_valid &&
      (!slot1_protocol_valid || slot0.header.generation >= slot1.header.generation)) {
    *out_payload = slot0.payload;
    return true;
  }

  *out_payload = slot1.payload;
  return true;
}

bool removeKey(const char* key) {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) {
    return false;
  }
  const bool success = preferences.remove(key);
  preferences.end();
  return success;
}

template <typename Payload>
bool corruptSlot(const char* key) {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) {
    return false;
  }

  PersistRecord<Payload> record = {};
  if (preferences.getBytesLength(key) != sizeof(PersistRecord<Payload>)) {
    preferences.end();
    return false;
  }

  if (preferences.getBytes(key, &record, sizeof(PersistRecord<Payload>)) !=
      sizeof(PersistRecord<Payload>)) {
    preferences.end();
    return false;
  }

  record.header.payload_crc32 ^= 0xFFFFFFFFUL;
  const bool success = preferences.putBytes(key, &record, sizeof(record)) == sizeof(record);
  preferences.end();
  return success;
}

}  // namespace

namespace persistence {

bool saveWeatherSnapshot(const protocol_parser::RegionalSnapshotV1& weather, Stream& serial) {
  if (!saveWithTwoSlots(kWeatherSlot0Key, kWeatherSlot1Key, weather, "weather", serial)) {
    serial.println("PERSIST: weather save failure");
    return false;
  }

  serial.println("PERSIST: weather save success");
  return true;
}

bool savePositionUpdate(const protocol_parser::PositionUpdateV1& position, Stream& serial) {
  if (!saveWithTwoSlots(kPositionSlot0Key, kPositionSlot1Key, position, "position", serial)) {
    serial.println("PERSIST: position save failure");
    return false;
  }

  serial.println("PERSIST: position save success");
  return true;
}

void restoreDeviceState(Stream& serial) {
  device_state::DeviceState* state = device_state::mutableState();

  protocol_parser::RegionalSnapshotV1 restored_weather = {};
  if (restoreWithTwoSlots(kWeatherSlot0Key, kWeatherSlot1Key, &restored_weather, "weather",
                          serial)) {
    state->weather = restored_weather;
    state->weather_timestamp = restored_weather.header.timestamp_unix;
    state->has_weather = true;
    serial.println("PERSIST: weather restore success");
  } else {
    state->has_weather = false;
    serial.println("PERSIST: no valid weather record");
  }

  protocol_parser::PositionUpdateV1 restored_position = {};
  if (restoreWithTwoSlots(kPositionSlot0Key, kPositionSlot1Key, &restored_position, "position",
                          serial)) {
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

void clearAllRecords(Stream& serial) {
  clearWeatherRecords(serial);
  clearPositionRecords(serial);
}

void clearWeatherRecords(Stream& serial) {
  const bool slot0_removed = removeKey(kWeatherSlot0Key);
  const bool slot1_removed = removeKey(kWeatherSlot1Key);
  if (slot0_removed || slot1_removed) {
    serial.println("PERSIST: weather records cleared");
    return;
  }
  serial.println("PERSIST: weather records already clear");
}

void clearPositionRecords(Stream& serial) {
  const bool slot0_removed = removeKey(kPositionSlot0Key);
  const bool slot1_removed = removeKey(kPositionSlot1Key);
  if (slot0_removed || slot1_removed) {
    serial.println("PERSIST: position records cleared");
    return;
  }
  serial.println("PERSIST: position records already clear");
}

bool corruptWeatherSlotForTest(uint8_t slot_index, Stream& serial) {
  const char* key = slot_index == 0 ? kWeatherSlot0Key : kWeatherSlot1Key;
  const bool success = corruptSlot<protocol_parser::RegionalSnapshotV1>(key);
  if (success) {
    serial.print("PERSIST: weather slot corrupted ");
    serial.println(slot_index);
    return true;
  }
  serial.print("PERSIST: weather slot corrupt failed ");
  serial.println(slot_index);
  return false;
}

bool corruptPositionSlotForTest(uint8_t slot_index, Stream& serial) {
  const char* key = slot_index == 0 ? kPositionSlot0Key : kPositionSlot1Key;
  const bool success = corruptSlot<protocol_parser::PositionUpdateV1>(key);
  if (success) {
    serial.print("PERSIST: position slot corrupted ");
    serial.println(slot_index);
    return true;
  }
  serial.print("PERSIST: position slot corrupt failed ");
  serial.println(slot_index);
  return false;
}

}  // namespace persistence
