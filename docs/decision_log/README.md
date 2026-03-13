# Decision Log

- Firmware language: C++ with Arduino framework for ESP32
- Hardware bring-up starts with serial and I2C display verification
- Display access is isolated behind a dedicated module to keep hardware code explicit
- Dynamic allocation is avoided in the initial firmware scaffold
