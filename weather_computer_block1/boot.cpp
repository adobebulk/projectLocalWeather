#include "boot.h"

#include <Arduino.h>

#include "ble_transport.h"
#include "display_driver.h"
#include "ingress_router.h"
#include "persistence.h"

namespace {

constexpr unsigned long kIdleDelayMs = 20;

}  // namespace

namespace runtime {

void boot() {
  Serial.begin(115200);
  delay(250);

  Serial.println("BOOT: start");
  Serial.println("BOOT: Weather Computer Block 1.0");

  const bool i2c_ready = display_driver::initI2c(Serial);
  if (!i2c_ready) {
    Serial.println("I2C: init failed");
    Serial.println("LCD: init start");
    Serial.println("LCD: init skipped, I2C not ready");
    Serial.println("DISPLAY: write skipped, LCD not ready");
    Serial.println("BOOT: complete with errors");
    return;
  }

  const bool lcd_present = display_driver::scanI2cBus(Serial);

  Serial.println("LCD: init start");
  if (!lcd_present) {
    Serial.println("LCD: init failed at address 0x72");
    Serial.println("DISPLAY: write skipped, LCD not ready");
    Serial.println("BOOT: complete with errors");
    return;
  }

  display_driver::beginLcd();
  display_driver::setBacklightEnabled(false);
  Serial.println("DISPLAY: backlight off");
  Serial.println("LCD: init success");

  Serial.println("DISPLAY: write start");
  if (display_driver::writeLines("WEATHER NODE", "BOOT OK")) {
    Serial.println("DISPLAY: write success");
  } else {
    Serial.println("DISPLAY: write failure");
    Serial.println("BOOT: complete with errors");
    return;
  }

  const bool ble_ready = ble_transport::begin(Serial);
  if (!ble_ready) {
    Serial.println("BOOT: complete with errors");
    return;
  }

  persistence::restoreDeviceState(Serial);
  ingress_router::recomputeFromState(Serial);
  Serial.println("BOOT: complete");
}

void tick() {
  ble_transport::tick(Serial);
  delay(kIdleDelayMs);
}

}  // namespace runtime
