#include "ble_transport.h"

#include <Arduino.h>
#include <cstring>
#include <string>

#include <BLE2902.h>
#include <BLEAdvertising.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include "device_state.h"
#include "ingress_router.h"
#include "packet_assembler.h"
#include "protocol_parser.h"

namespace {

constexpr char kDeviceName[] = "WeatherComputer";
constexpr size_t kRxBufferSize = 512;
constexpr size_t kPendingPacketBufferSize = 512;
constexpr size_t kPendingPacketQueueDepth = 2;
constexpr size_t kHexPreviewBytes = 16;

constexpr char kServiceUuid[] = "19B10010-E8F2-537E-4F6C-D104768A1214";
constexpr char kRxCharacteristicUuid[] = "19B10011-E8F2-537E-4F6C-D104768A1214";
constexpr char kTxCharacteristicUuid[] = "19B10012-E8F2-537E-4F6C-D104768A1214";

BLEServer* g_server = nullptr;
BLECharacteristic* g_rx_characteristic = nullptr;
BLECharacteristic* g_tx_characteristic = nullptr;
Stream* g_serial = nullptr;
bool g_ready = false;
bool g_device_connected = false;
bool g_restart_advertising = false;
uint8_t g_ack_payload[3] = {'A', 'C', 'K'};
uint8_t g_rx_buffer[kRxBufferSize];
size_t g_rx_length = 0;
uint8_t g_pending_packets[kPendingPacketQueueDepth][kPendingPacketBufferSize];
size_t g_pending_packet_lengths[kPendingPacketQueueDepth] = {};
size_t g_pending_packet_head = 0;
size_t g_pending_packet_tail = 0;
size_t g_pending_packet_count = 0;

void logLine(const char* message) {
  if (g_serial == nullptr) {
    return;
  }
  g_serial->println(message);
}

void logHexPreview(const uint8_t* data, size_t length) {
  if (g_serial == nullptr || length == 0) {
    return;
  }

  char line[96];
  size_t offset = 0;
  offset += snprintf(line + offset, sizeof(line) - offset, "BLE: rx hex");

  const size_t preview_length = length < kHexPreviewBytes ? length : kHexPreviewBytes;
  for (size_t i = 0; i < preview_length && offset < sizeof(line); ++i) {
    offset += snprintf(line + offset, sizeof(line) - offset, " %02X", data[i]);
  }

  if (length > kHexPreviewBytes && offset < sizeof(line)) {
    snprintf(line + offset, sizeof(line) - offset, " ...");
  }

  g_serial->println(line);
}

void logUnsignedValueLine(const char* prefix, size_t value, const char* suffix = nullptr) {
  if (g_serial == nullptr) {
    return;
  }

  char line[64];
  if (suffix == nullptr) {
    snprintf(line, sizeof(line), "%s%u", prefix, static_cast<unsigned>(value));
  } else {
    snprintf(line, sizeof(line), "%s%u%s", prefix, static_cast<unsigned>(value), suffix);
  }
  g_serial->println(line);
}

void sendAck() {
  if (g_tx_characteristic == nullptr) {
    logLine("BLE: tx skipped, TX characteristic not ready");
    return;
  }

  g_tx_characteristic->setValue(g_ack_payload, 3);

  if (g_device_connected) {
    g_tx_characteristic->notify();
    logLine("BLE: tx ACK");
    return;
  }

  logLine("BLE: tx ACK queued, no subscriber");
}

void logAssemblerResult(const packet_assembler::FeedResult& result) {
  logUnsignedValueLine("ASSEMBLER: fragment len=", result.fragment_length);

  if (result.dropped_garbage_bytes > 0) {
    logUnsignedValueLine("ASSEMBLER: dropped garbage len=", result.dropped_garbage_bytes);
  }

  logUnsignedValueLine("ASSEMBLER: buffered=", result.bytes_buffered);

  if (result.expected_length_known) {
    logUnsignedValueLine("ASSEMBLER: expected len=", result.expected_packet_length);
  }

  if (result.malformed_start) {
    logUnsignedValueLine("ASSEMBLER: malformed start len=", result.expected_packet_length);
  }

  if (result.packet_complete) {
    logUnsignedValueLine("ASSEMBLER: packet complete len=", result.packet_length);
  }
}

void logParserResult(const protocol_parser::ParseResult& result) {
  logLine(protocol_parser::statusToLogMessage(result.status, result.header.packet_type));
}

bool enqueueCompletedPacket() {
  if (!packet_assembler::hasCompletePacket()) {
    return false;
  }

  const size_t packet_length = packet_assembler::completePacketLength();
  if (packet_length == 0 || packet_length > kPendingPacketBufferSize) {
    logLine("BLE: packet queue rejected oversized packet");
    packet_assembler::consumePacket();
    return false;
  }

  if (g_pending_packet_count >= kPendingPacketQueueDepth) {
    logLine("BLE: packet queue full, dropping complete packet");
    packet_assembler::consumePacket();
    return false;
  }

  memcpy(g_pending_packets[g_pending_packet_tail], packet_assembler::completePacketData(),
         packet_length);
  g_pending_packet_lengths[g_pending_packet_tail] = packet_length;
  g_pending_packet_tail = (g_pending_packet_tail + 1) % kPendingPacketQueueDepth;
  ++g_pending_packet_count;
  packet_assembler::consumePacket();
  return true;
}

void processPendingPackets() {
  while (g_pending_packet_count > 0) {
    const uint8_t* packet = g_pending_packets[g_pending_packet_head];
    const size_t packet_length = g_pending_packet_lengths[g_pending_packet_head];

    const protocol_parser::ParseResult parse_result =
        protocol_parser::parsePacket(packet, packet_length);
    logParserResult(parse_result);
    if (g_serial != nullptr) {
      ingress_router::handlePacket(parse_result, *g_serial);
    }

    g_pending_packet_lengths[g_pending_packet_head] = 0;
    g_pending_packet_head = (g_pending_packet_head + 1) % kPendingPacketQueueDepth;
    --g_pending_packet_count;
  }
}

class ServerCallbacks : public BLEServerCallbacks {
 public:
  void onConnect(BLEServer* server) override {
    (void)server;
    g_device_connected = true;
    logLine("BLE: central connected");
  }

  void onDisconnect(BLEServer* server) override {
    (void)server;
    g_device_connected = false;
    g_restart_advertising = true;
    logLine("BLE: central disconnected");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
 public:
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    const size_t incoming_length = value.length();

    g_rx_length = incoming_length < kRxBufferSize ? incoming_length : kRxBufferSize;
    if (g_rx_length > 0) {
      memcpy(g_rx_buffer, value.data(), g_rx_length);
    }

    logUnsignedValueLine("BLE: rx chunk ", incoming_length, " bytes");

    if (incoming_length > kRxBufferSize) {
      logUnsignedValueLine("BLE: rx chunk truncated to ", kRxBufferSize, " bytes");
    }

    logHexPreview(g_rx_buffer, g_rx_length);
    const packet_assembler::FeedResult assembler_result =
        packet_assembler::pushFragment(g_rx_buffer, g_rx_length);
    logAssemblerResult(assembler_result);
    if (packet_assembler::hasCompletePacket()) {
      enqueueCompletedPacket();
    }
    sendAck();
  }
};

ServerCallbacks g_server_callbacks;
RxCallbacks g_rx_callbacks;

}  // namespace

namespace ble_transport {

bool begin(Stream& serial) {
  g_serial = &serial;
  g_ready = false;
  device_state::reset();
  packet_assembler::reset();
  g_pending_packet_head = 0;
  g_pending_packet_tail = 0;
  g_pending_packet_count = 0;

  serial.println("BLE: init start");

  BLEDevice::init(kDeviceName);

  g_server = BLEDevice::createServer();
  if (g_server == nullptr) {
    serial.println("BLE: init failed creating server");
    return false;
  }
  g_server->setCallbacks(&g_server_callbacks);

  BLEService* service = g_server->createService(kServiceUuid);
  if (service == nullptr) {
    serial.println("BLE: init failed creating service");
    return false;
  }

  g_rx_characteristic = service->createCharacteristic(
      kRxCharacteristicUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  g_tx_characteristic = service->createCharacteristic(
      kTxCharacteristicUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);

  if (g_rx_characteristic == nullptr || g_tx_characteristic == nullptr) {
    serial.println("BLE: init failed creating characteristic");
    return false;
  }

  g_rx_characteristic->setCallbacks(&g_rx_callbacks);
  g_tx_characteristic->addDescriptor(new BLE2902());
  g_tx_characteristic->setValue(g_ack_payload, 3);

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(false);
  advertising->start();

  serial.print("BLE: advertising as ");
  serial.println(kDeviceName);
  serial.println("BLE: init success");
  g_ready = true;
  return true;
}

void tick(Stream& serial) {
  if (!g_ready) {
    return;
  }

  processPendingPackets();

  if (g_restart_advertising) {
    g_restart_advertising = false;
    BLEDevice::startAdvertising();
    serial.println("BLE: advertising restarted");
  }
}

bool isReady() {
  return g_ready;
}

}  // namespace ble_transport
