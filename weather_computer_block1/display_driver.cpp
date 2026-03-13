#include "display_driver.h"

#include <Arduino.h>
#include <SerLCD.h>
#include <Wire.h>

namespace {

constexpr uint8_t kDisplayI2cAddress = 0x72;
constexpr uint8_t kDisplayColumns = 16;
constexpr bool kUseExplicitWirePinsFallback = true;

// Keep fallback pin choices here so they are easy to change for board-specific wiring.
// The Nano ESP32 commonly exposes Qwiic/I2C on SDA=11 and SCL=12 if the default
// Wire pin mapping does not match the connected hardware.
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

bool scanI2cBus(Stream& serial) {
  serial.println("I2C: scan start");

  uint8_t device_count = 0;
  bool lcd_found = false;

  for (uint8_t address = 1; address < 127; ++address) {
    Wire.beginTransmission(address);
    const uint8_t error = Wire.endTransmission();
    if (error != 0) {
      continue;
    }

    char buffer[32];
    snprintf(buffer, sizeof(buffer), "I2C: found device at 0x%02X", address);
    serial.println(buffer);

    if (address == kDisplayI2cAddress) {
      lcd_found = true;
    }

    ++device_count;
  }

  if (device_count == 0) {
    serial.println("I2C: no devices found");
    return false;
  }

  serial.print("I2C: scan complete, ");
  serial.print(device_count);
  serial.println(" device(s) found");
  return lcd_found;
}

void beginLcd() {
  g_ready = false;
  delay(50);

  // SerLCD library 1.0.9 exposes begin() as void, so device presence is checked
  // with the I2C scanner before calling this.
  lcd.begin(Wire, kDisplayI2cAddress);
  lcd.setBacklight(0, 64, 96);
  lcd.clear();
  lcd.setContrast(5);
  lcd.setCursor(0, 0);
  g_ready = true;
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
