# Persistence Validation

This checklist is for Block 1.0 persistence and reboot robustness validation.

Production boot behavior is unchanged:

1. initialize LCD
2. initialize BLE
3. restore persisted weather and position
4. recompute estimate if both are valid
5. refresh runtime LCD through the normal estimate path

## Validation Hooks

Validation-only helper functions are available in `persistence.h`:

- `persistence::clearAllRecords(Stream&)`
- `persistence::clearWeatherRecords(Stream&)`
- `persistence::clearPositionRecords(Stream&)`
- `persistence::corruptWeatherSlotForTest(uint8_t slot_index, Stream&)`
- `persistence::corruptPositionSlotForTest(uint8_t slot_index, Stream&)`

These are intended for bench testing only. They are not used by the production boot flow.

## Checklist

### 1. Both Invalid

Setup:

1. call `clearAllRecords(...)`
2. reboot

Expected serial logs:

```text
PERSIST: no valid weather record
PERSIST: no valid position record
PERSIST: restore complete
```

Expected behavior:

- no estimate recompute
- LCD remains at boot banner until real packets arrive

### 2. Weather Only

Setup:

1. clear all records
2. send one valid weather packet
3. call `clearPositionRecords(...)`
4. reboot

Expected serial logs:

```text
PERSIST: weather restore success
PERSIST: no valid position record
PERSIST: restore complete
```

Expected behavior:

- no estimate recompute
- LCD remains at boot banner until a valid position packet arrives

### 3. Position Only

Setup:

1. clear all records
2. send one valid position packet
3. call `clearWeatherRecords(...)`
4. reboot

Expected serial logs:

```text
PERSIST: no valid weather record
PERSIST: position restore success
PERSIST: restore complete
```

Expected behavior:

- no estimate recompute
- LCD remains at boot banner until a valid weather packet arrives

### 4. Both Valid

Setup:

1. clear all records
2. send one valid weather packet
3. send one valid position packet
4. reboot

Expected serial logs:

```text
PERSIST: weather restore success
PERSIST: position restore success
PERSIST: restore complete
ESTIMATE: recompute start
ESTIMATE: success
DISPLAY: runtime update start
DISPLAY: runtime update success
```

Expected behavior:

- estimate recomputes immediately on boot
- LCD updates from boot banner to runtime weather view without debug seed

### 5. Corrupted Weather Slot, Backup Valid

Setup:

1. clear all records
2. send valid weather twice so both slots cycle
3. send valid position
4. corrupt one weather slot with `corruptWeatherSlotForTest(0 or 1, ...)`
5. reboot

Expected serial logs:

```text
PERSIST: weather restore success
PERSIST: position restore success
PERSIST: restore complete
ESTIMATE: recompute start
ESTIMATE: success
DISPLAY: runtime update start
DISPLAY: runtime update success
```

Expected behavior:

- restore falls back to the newest still-valid weather slot

### 6. Corrupted Position Slot, Backup Valid

Setup:

1. clear all records
2. send valid weather
3. send valid position twice so both slots cycle
4. corrupt one position slot with `corruptPositionSlotForTest(0 or 1, ...)`
5. reboot

Expected serial logs:

```text
PERSIST: weather restore success
PERSIST: position restore success
PERSIST: restore complete
ESTIMATE: recompute start
ESTIMATE: success
DISPLAY: runtime update start
DISPLAY: runtime update success
```

Expected behavior:

- restore falls back to the newest still-valid position slot

### 7. Both Slots Corrupted for One Record Type

Weather invalid, position valid setup:

1. persist valid weather and valid position
2. corrupt both weather slots
3. reboot

Expected serial logs:

```text
PERSIST: no valid weather record
PERSIST: position restore success
PERSIST: restore complete
```

Position invalid, weather valid setup:

1. persist valid weather and valid position
2. corrupt both position slots
3. reboot

Expected serial logs:

```text
PERSIST: weather restore success
PERSIST: no valid position record
PERSIST: restore complete
```

Expected behavior:

- no estimate recompute when either restored input is missing

### 8. Repeated Reboot

Setup:

1. persist valid weather and valid position
2. reboot at least 5 times without sending new packets

Expected serial logs on each reboot:

```text
PERSIST: weather restore success
PERSIST: position restore success
PERSIST: restore complete
ESTIMATE: recompute start
ESTIMATE: success
DISPLAY: runtime update start
DISPLAY: runtime update success
```

Expected behavior:

- same estimate and same LCD output each reboot
- no dependence on BLE traffic for restore

## Release Risks To Watch

- NVS corruption or namespace exhaustion under very high rewrite counts
- power loss during a slot write should be tolerated by the two-slot approach, but should still be spot-checked on real hardware
- persisted payload validity is currently checked by record CRC and basic packet header checks, not full semantic re-validation
