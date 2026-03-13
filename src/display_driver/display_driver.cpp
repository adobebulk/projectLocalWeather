#include "display_driver/display_driver.h"

#include <Arduino.h>
#include <SparkFunSerLCD.h>
#include <Wire.h>

namespace {

constexpr uint8_t kDisplayI2cAddress = 0x72;
constexpr uint8_t kDisplayColumns = 16;
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

bool begin() {
  Wire.begin(kQwiicSdaPin, kQwiicSclPin);
  delay(50);

  if (!lcd.begin(Wire, kDisplayI2cAddress)) {
    g_ready = false;
    return false;
  }

  lcd.setBacklight(0, 64, 96);
  lcd.clear();
  lcd.setContrast(5);
  lcd.setCursor(0, 0);
  g_ready = true;
  return true;
}

void writeLines(const char* line1, const char* line2) {
  if (!g_ready) {
    return;
  }

  writeLine(0, line1);
  writeLine(1, line2);
}

}  // namespace display_driver
