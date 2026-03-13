#include "packet_assembler.h"

#include <Arduino.h>
#include <cstring>

namespace {

constexpr uint8_t kMagicFirstByte = 0x43;
constexpr uint8_t kMagicSecondByte = 0x57;
constexpr uint8_t kSupportedVersion = 1;
constexpr uint8_t kPacketTypeRegionalSnapshotV1 = 1;
constexpr uint8_t kPacketTypePositionUpdateV1 = 2;
constexpr uint8_t kPacketTypeAckV1 = 3;

constexpr size_t kMagicOffset = 0;
constexpr size_t kVersionOffset = 2;
constexpr size_t kPacketTypeOffset = 3;
constexpr size_t kLengthFieldOffset = 4;
constexpr size_t kLengthFieldSize = 2;
constexpr size_t kSequenceOffset = 6;
constexpr size_t kTimestampOffset = 10;
constexpr size_t kCrcOffset = 14;
constexpr size_t kCrcSize = 4;
constexpr size_t kHeaderSize = 18;

constexpr size_t kPositionPacketSize = 32;
constexpr size_t kAckPacketSize = 32;
constexpr size_t kRegionalSnapshotPacketSize = 470;
constexpr size_t kMaxPacketLength = 512;
constexpr size_t kAssemblerBufferSize = 768;

uint8_t g_buffer[kAssemblerBufferSize];
size_t g_buffer_length = 0;

uint8_t g_complete_packet[kMaxPacketLength];
size_t g_complete_packet_length = 0;
bool g_has_complete_packet = false;

size_t readExpectedPacketLength() {
  return static_cast<size_t>(g_buffer[kLengthFieldOffset]) |
         (static_cast<size_t>(g_buffer[kLengthFieldOffset + 1]) << 8);
}

size_t expectedLengthForPacketType(uint8_t packet_type) {
  if (packet_type == kPacketTypeRegionalSnapshotV1) {
    return kRegionalSnapshotPacketSize;
  }

  if (packet_type == kPacketTypePositionUpdateV1) {
    return kPositionPacketSize;
  }

  if (packet_type == kPacketTypeAckV1) {
    return kAckPacketSize;
  }

  return 0;
}

size_t findMagicOffset() {
  if (g_buffer_length < 2) {
    return g_buffer_length;
  }

  for (size_t i = 0; i + 1 < g_buffer_length; ++i) {
    if (g_buffer[i] == kMagicFirstByte && g_buffer[i + 1] == kMagicSecondByte) {
      return i;
    }
  }

  if (g_buffer[g_buffer_length - 1] == kMagicFirstByte) {
    return g_buffer_length - 1;
  }

  return g_buffer_length;
}

void dropBytes(size_t count) {
  if (count == 0) {
    return;
  }

  if (count >= g_buffer_length) {
    g_buffer_length = 0;
    return;
  }

  memmove(g_buffer, g_buffer + count, g_buffer_length - count);
  g_buffer_length -= count;
}

void appendByte(uint8_t byte) {
  if (g_buffer_length == kAssemblerBufferSize) {
    dropBytes(1);
  }

  g_buffer[g_buffer_length] = byte;
  ++g_buffer_length;
}

}  // namespace

namespace packet_assembler {

void reset() {
  g_buffer_length = 0;
  g_complete_packet_length = 0;
  g_has_complete_packet = false;
}

FeedResult pushFragment(const uint8_t* data, size_t length) {
  FeedResult result = {};
  result.fragment_length = length;

  if (g_has_complete_packet) {
    consumePacket();
  }

  for (size_t i = 0; i < length; ++i) {
    appendByte(data[i]);
  }

  while (g_buffer_length > 0) {
    const size_t magic_offset = findMagicOffset();
    if (magic_offset > 0) {
      dropBytes(magic_offset);
      result.dropped_garbage_bytes += magic_offset;
      continue;
    }

    if (g_buffer_length < 2) {
      break;
    }

    if (g_buffer[0] != kMagicFirstByte || g_buffer[1] != kMagicSecondByte) {
      dropBytes(1);
      result.dropped_garbage_bytes += 1;
      continue;
    }

    if (g_buffer_length < kHeaderSize) {
      break;
    }

    const uint8_t version = g_buffer[kVersionOffset];
    const uint8_t packet_type = g_buffer[kPacketTypeOffset];
    const size_t expected_length = readExpectedPacketLength();
    result.expected_length_known = true;
    result.expected_packet_length = expected_length;

    if (version != kSupportedVersion) {
      result.malformed_start = true;
      dropBytes(1);
      continue;
    }

    const size_t fixed_packet_length = expectedLengthForPacketType(packet_type);
    if (fixed_packet_length == 0) {
      result.malformed_start = true;
      dropBytes(1);
      continue;
    }

    if (expected_length != fixed_packet_length) {
      result.malformed_start = true;
      dropBytes(1);
      continue;
    }

    if (expected_length < kHeaderSize || expected_length > kMaxPacketLength) {
      result.malformed_start = true;
      dropBytes(1);
      continue;
    }

    if (g_buffer_length < expected_length) {
      break;
    }

    memcpy(g_complete_packet, g_buffer, expected_length);
    g_complete_packet_length = expected_length;
    g_has_complete_packet = true;
    result.packet_complete = true;
    result.packet_length = expected_length;

    dropBytes(expected_length);
    break;
  }

  result.bytes_buffered = g_buffer_length;
  return result;
}

bool hasCompletePacket() {
  return g_has_complete_packet;
}

const uint8_t* completePacketData() {
  if (!g_has_complete_packet) {
    return nullptr;
  }

  return g_complete_packet;
}

size_t completePacketLength() {
  if (!g_has_complete_packet) {
    return 0;
  }

  return g_complete_packet_length;
}

void consumePacket() {
  g_has_complete_packet = false;
  g_complete_packet_length = 0;
}

}  // namespace packet_assembler
