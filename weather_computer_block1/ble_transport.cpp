#include "ble_transport.h"

#include <Arduino.h>
#include <cstring>
#include <string>

#include <BLE2902.h>
#include <BLEAdvertising.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

namespace {

constexpr char kDeviceName[] = "WeatherComputer";
constexpr char kAckPayload[] = "ACK";
constexpr size_t kRxBufferSize = 128;
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
uint8_t g_rx_buffer[kRxBufferSize];
size_t g_rx_length = 0;

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

void sendAck() {
  if (g_tx_characteristic == nullptr) {
    logLine("BLE: tx skipped, TX characteristic not ready");
    return;
  }

  g_tx_characteristic->setValue(reinterpret_cast<const uint8_t*>(kAckPayload), 3);

  if (g_device_connected) {
    g_tx_characteristic->notify();
    logLine("BLE: tx ACK");
    return;
  }

  logLine("BLE: tx ACK queued, no subscriber");
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

    if (g_serial != nullptr) {
      g_serial->print("BLE: rx ");
      g_serial->print(incoming_length);
      g_serial->println(" bytes");
    }

    if (incoming_length > kRxBufferSize && g_serial != nullptr) {
      g_serial->print("BLE: rx truncated to ");
      g_serial->print(kRxBufferSize);
      g_serial->println(" bytes");
    }

    logHexPreview(g_rx_buffer, g_rx_length);
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
  g_tx_characteristic->setValue(reinterpret_cast<const uint8_t*>(kAckPayload), 3);

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
