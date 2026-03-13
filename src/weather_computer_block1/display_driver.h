#ifndef WEATHER_COMPUTER_DISPLAY_DRIVER_H
#define WEATHER_COMPUTER_DISPLAY_DRIVER_H

#include <Arduino.h>

namespace display_driver {

// Expected library: SparkFun SerLCD Arduino Library (<SparkFunSerLCD.h>).
// Expected default I2C address for the SerLCD backpack: 0x72.
// Successful Stage 1 bring-up should produce serial logs showing:
// BOOT start, I2C init, I2C scan results, LCD init success, and display write success.

bool initI2c(Stream& serial);
void scanI2cBus(Stream& serial);
bool beginLcd();
bool writeLines(const char* line1, const char* line2);
bool isReady();

}  // namespace display_driver

#endif  // WEATHER_COMPUTER_DISPLAY_DRIVER_H
