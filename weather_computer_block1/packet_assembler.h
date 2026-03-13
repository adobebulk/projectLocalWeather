#ifndef WEATHER_COMPUTER_PACKET_ASSEMBLER_H
#define WEATHER_COMPUTER_PACKET_ASSEMBLER_H

#include <Arduino.h>

namespace packet_assembler {

struct FeedResult {
  size_t fragment_length;
  size_t bytes_buffered;
  size_t expected_packet_length;
  size_t packet_length;
  size_t dropped_garbage_bytes;
  bool expected_length_known;
  bool packet_complete;
  bool malformed_start;
};

void reset();
FeedResult pushFragment(const uint8_t* data, size_t length);
bool hasCompletePacket();
const uint8_t* completePacketData();
size_t completePacketLength();
void consumePacket();

}  // namespace packet_assembler

#endif  // WEATHER_COMPUTER_PACKET_ASSEMBLER_H
