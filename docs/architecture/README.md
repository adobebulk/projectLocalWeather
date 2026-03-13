# Architecture

Stage 1 firmware keeps boot flow intentionally small:

- Arduino sketch entry calls the runtime boot path
- runtime handles serial logging and startup sequencing
- display_driver owns I2C LCD bring-up and line writes

Later stages can add protocol, persistence, and interpolation modules without changing the bring-up path.
