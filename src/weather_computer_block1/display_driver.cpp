#include "display_driver.h"

#include <Arduino.h>
#include <SerLCD.h>
#include <Wire.h>

namespace {

constexpr uint8_t kDisplayI2cAddress = 0x72;
constexpr uint8_t kDisplayColumns = 16;
constexpr bool kUseExplicitWirePinsFallback = true;

// Keep fallback pin choices here so they are easy to update for board-specific wiring.
// On Nano ESP32 Qwiic/I2C is commonly routed on SDA=11 and SCL=12.
constexpr uint8_t kQwiicSdaPin = 11;
constexpr uint8_t kQwiicSclPin = 12;

SerLCD lcd;
bool g_ready = false;

void writeLine(uint8_t row, const char* text) {
  lcd.setCursor(0, row);
  uint8_t column = 0;
  for (; column < kDisplayColumns; ++column) {
    const char character = text[column];
    if (character == '\0') {
      break;
    }
    lcd.write(character);
  }

  for (; column < kDisplayColumns; ++column) {
    lcd.write(' ');
  }
}

}  // namespace

namespace display_driver {

bool initI2c(Stream& serial) {
  serial.println("I2C: init start");

  if (Wire.begin()) {
    serial.println("I2C: default Wire.begin() OK");
    return true;
  }

  serial.println("I2C: default Wire.begin() FAILED");
  if (!kUseExplicitWirePinsFallback) {
    serial.println("I2C: explicit pin fallback disabled");
    return false;
  }

  // Fallback for boards/wiring where the default Wire pins are not mapped as expected.
  serial.print("I2C: retry with explicit SDA=");
  serial.print(kQwiicSdaPin);
  serial.print(" SCL=");
  serial.println(kQwiicSclPin);

  if (!Wire.begin(kQwiicSdaPin, kQwiicSclPin)) {
    serial.println("I2C: explicit pin init FAILED");
    return false;
  }

  serial.println("I2C: explicit pin init OK");
  return true;
}

void scanI2cBus(Stream& serial) {
  serial.println("I2C: scan start");

  uint8_t device_count = 0;
  for (uint8_t address = 1; address < 127; ++address) {
    Wire.beginTransmission(address);
    const uint8_t error = Wire.endTransmission();
    if (error == 0) {
      char buffer[32];
      snprintf(buffer, sizeof(buffer), "I2C: found device at 0x%02X", address);
      serial.println(buffer);
      ++device_count;
    }
  }

  if (device_count == 0) {
    serial.println("I2C: no devices found");
    return;
  }

  serial.print("I2C: scan complete, ");
  serial.print(device_count);
  serial.println(" device(s) found");
}

bool beginLcd() {
  g_ready = false;
  delay(50);

  if (!lcd.begin(Wire, kDisplayI2cAddress)) {
    return false;
  }

  lcd.setBacklight(0, 64, 96);
  lcd.clear();
  lcd.setContrast(5);
  lcd.setCursor(0, 0);
  g_ready = true;
  return true;
}

bool writeLines(const char* line1, const char* line2) {
  if (!g_ready) {
    return false;
  }

  writeLine(0, line1);
  writeLine(1, line2);
  return true;
}

bool isReady() {
  return g_ready;
}

}  // namespace display_driver
