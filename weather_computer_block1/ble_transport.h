#ifndef WEATHER_COMPUTER_BLE_TRANSPORT_H
#define WEATHER_COMPUTER_BLE_TRANSPORT_H

#include <Arduino.h>

namespace ble_transport {

// Expected library: ESP32 BLE Arduino library from the ESP32 board package
// (<BLEDevice.h>, <BLEServer.h>, <BLE2902.h>).

bool begin(Stream& serial);
void tick(Stream& serial);
bool isReady();

}  // namespace ble_transport

#endif  // WEATHER_COMPUTER_BLE_TRANSPORT_H
