# Decision Log

Concise chronological record of major Block 1 decisions.

## 2026-03-10

- Block 1 regional model fixed to a 3x3 anchor grid, 240 miles across.
- Forecast horizon fixed to 2 hours with 0/60/120 minute slots.
- Position update cadence target set to approximately every 10 minutes.
- Confidence remains computed on device; confidence is not on-wire.
- Power-loss resilience required: persist active weather snapshot and latest position across reboot.
- Display policy keeps temperature off Line 1 because vehicles already expose ambient temperature.
- Compact ATIS-inspired weather code policy adopted for Line 1.
- Block 1 weather codes include `RA`, `SN`, `IC`, `FG`, `TS`, `MX`, `HZ`, `SM`.
- Tornado watch display policy: Line 2 only.
