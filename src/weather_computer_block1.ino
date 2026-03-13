#include "runtime/boot.h"

void setup() {
  runtime::boot();
}

void loop() {
  runtime::tick();
}
