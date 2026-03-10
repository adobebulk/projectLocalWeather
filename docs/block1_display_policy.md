# Block 1 Display Policy

This document defines the current Block 1 display policy for the 16x2 device screen.

It is a policy record for current behavior, not a frozen long-term specification.

## Line 1 Policy

Line 1 is a compact ATIS-inspired condition strip.

Temperature is intentionally omitted because the vehicle already provides ambient temperature.

Line 1 may include:

- visibility (`V5`, `V2`, `V1`, `V0.5`)
- weather type codes
- intensity markers
- precipitation probability
- wind / gust

## Weather Codes

Codes kept for Block 1:

- `RA`
- `SN`
- `IC`
- `FG`
- `TS`
- `MX`
- `HZ`
- `SM`

## Intensity Markers

- `-` = light
- no marker = moderate
- `+` = heavy / severe

## Policy Decisions

- type-first display on Line 1
- mixed precipitation displayed as `MX`
- severe thunderstorm displayed as `TS` on Line 1 and `SVRSTM` on Line 2
- tornado watch appears on Line 2 only
- visibility should be quickly understandable and generally numeric on Line 1
- Line 2 remains hazard/status + confidence oriented

## Deterministic Line 1 Truncation and Priority

Line 1 uses this block order:

1. visibility
2. phenomenon
3. wind

Only one phenomenon block is shown.

When multiple phenomena are present, select the dominant phenomenon using this fixed priority:

`TS`, `IC`, `SN`, `RA`, `FG`, `SM`, `HZ`, `MX`

If Line 1 is too long, truncate deterministically in this order:

1. drop wind gust first (keep base wind if possible)
2. drop redundant visibility for `FG` / `SM` / `HZ` if needed
3. drop benign `V10` / `V5` visibility if still needed

Final minimum behavior:

- preserve phenomenon + wind when possible
- avoid dropping phenomenon unless there is no other option

### Worked Examples

- Full line available: `V2 +RA P70 14G28`
- Needs mild truncation: `V2 +RA P70 14`
- Fog with visibility redundancy under tight width: `FG P80 12`
- Haze with benign visibility removed: `HZ 10`
- Thunderstorm kept as dominant phenomenon: `TS P60 18`
- Snow kept over rain when both present: `V1 SN P65 16`

## Future Evolution

This policy may evolve in Block 1.1 or Block 2.0 as operational feedback is collected.

Any revisions should preserve fast readability and deterministic rendering behavior.
