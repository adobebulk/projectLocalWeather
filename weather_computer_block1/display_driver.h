#ifndef WEATHER_COMPUTER_DISPLAY_DRIVER_H
#define WEATHER_COMPUTER_DISPLAY_DRIVER_H

#include <Arduino.h>

namespace display_driver {

// Expected library: SparkFun SerLCD Arduino Library 1.0.9 (<SerLCD.h>).
// Expected default I2C address for the SerLCD backpack: 0x72.
// Successful Stage 1 bring-up should show BOOT start, I2C init, I2C scan,
// LCD init success, DISPLAY write success, and BOOT complete on serial.

bool initI2c(Stream& serial);
bool scanI2cBus(Stream& serial);
void beginLcd();
bool writeLines(const char* line1, const char* line2);
bool isReady();

}  // namespace display_driver

#endif  // WEATHER_COMPUTER_DISPLAY_DRIVER_H
