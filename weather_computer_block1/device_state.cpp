#include "device_state.h"

namespace {

device_state::DeviceState g_state = {};

}  // namespace

namespace device_state {

void reset() {
  g_state = {};
}

DeviceState* mutableState() {
  return &g_state;
}

const DeviceState* state() {
  return &g_state;
}

}  // namespace device_state
