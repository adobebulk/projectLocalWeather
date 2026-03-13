#include "runtime/boot.h"

#include <Arduino.h>

#include "display_driver/display_driver.h"

namespace {

constexpr unsigned long kIdleDelayMs = 1000;

}  // namespace

namespace runtime {

void boot() {
  Serial.begin(115200);
  delay(250);

  Serial.println();
  Serial.println("Weather Computer Block 1.0");
  Serial.println("Stage 1 bring-up starting");
  Serial.println("Initializing display...");

  const bool display_ready = display_driver::begin();
  if (display_ready) {
    display_driver::writeLines("WEATHER NODE", "BOOT OK");
    Serial.println("Display initialization OK");
  } else {
    Serial.println("Display initialization FAILED");
  }

  Serial.println("Boot sequence complete");
}

void tick() {
  delay(kIdleDelayMs);
}

}  // namespace runtime
