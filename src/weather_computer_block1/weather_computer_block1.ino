#include <SerLCD.h>

#include "boot.h"

void setup() {
  runtime::boot();
}

void loop() {
  runtime::tick();
}
