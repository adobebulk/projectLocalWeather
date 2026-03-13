#ifndef WEATHER_COMPUTER_DISPLAY_DRIVER_H
#define WEATHER_COMPUTER_DISPLAY_DRIVER_H

namespace display_driver {

bool begin();
void writeLines(const char* line1, const char* line2);

}  // namespace display_driver

#endif  // WEATHER_COMPUTER_DISPLAY_DRIVER_H
