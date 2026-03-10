# Block 1.0 Nano Rust Static Library Target Strategy

This note defines the practical next build strategy for producing a Rust static library that can be linked into the Arduino Nano ESP32 shell.

## 1. Actual Build Problem

Current command:

```bash
cd weather_protocol_rust
cargo build --release
```

produces a host library for `aarch64-apple-darwin` in this environment.

That artifact is not link-compatible with Nano ESP32 firmware builds.

Local validation also showed:

- `cargo +esp ...` fails because toolchain `esp` is not installed.
- `cargo build --target xtensa-esp32s3-none-elf` currently fails with missing `std`.

So the current setup proves ABI shape, but not target-compatible board linking.

## 2. Likely Viable Build Paths

### Path A: Xtensa ESP target toolchain (preferred for Nano ESP32)

Use Espressif Rust toolchain (`espup`) and build for:

- `xtensa-esp32s3-none-elf`

Output:

- target-arch static library `.a` for Nano ESP32 (ESP32-S3)

Notes:

- this path aligns with current Arduino Nano ESP32 hardware architecture
- this is the most direct route to test real link compatibility

### Path B: Keep host-only staticlib (not viable for board linking)

Keep using host build as ABI/prototype validation only.

This does not test board linker compatibility and should not be treated as hardware-ready.

## 3. Most Practical Path for Block 1.0

Path A is the practical next attempt:

1. install Espressif Rust toolchain
2. build `weather_protocol_rust` for `xtensa-esp32s3-none-elf`
3. verify `bridge_*` symbols in target artifact
4. attempt Arduino shell link against target `.a`

This keeps the chosen architecture intact (thin shell + Rust core) without rewriting protocol/runtime logic.

## 4. Exact Next Setup / Command Attempts

From repository root:

```bash
# 1) Install Espressif Rust toolchain manager (if missing)
cargo install espup

# 2) Install esp toolchain + export env
espup install

# 3) Activate env in shell session
source "$HOME/export-esp.sh"

# 4) Verify esp toolchain is available
cargo +esp --version

# 5) Build target static library
cd weather_protocol_rust
cargo +esp build --release --target xtensa-esp32s3-none-elf -Zbuild-std=core,alloc

# 6) Verify exported bridge symbols in target artifact
nm -g target/xtensa-esp32s3-none-elf/release/libweather_protocol_rust.a | \
  rg "bridge_(new_in_memory|restore_on_boot|push_ble_fragment|take_pending_ack|get_display_lines|free)"
```

Then use:

- `weather_protocol_rust/include/weather_bridge_ffi.h`
- `weather_protocol_rust/target/xtensa-esp32s3-none-elf/release/libweather_protocol_rust.a`

for the first real Arduino link attempt.

## 5. Likely Risks / Blockers

- toolchain mismatch: Arduino build uses Espressif GCC/linker settings that may require additional flags.
- `std` dependency pressure: current crate is host-friendly; target builds may need explicit `no_std + alloc` gating to avoid pulling `std`.
- allocator/panic/runtime expectations for staticlib in freestanding target may require explicit configuration.
- transitive linking issues from Rust staticlib into Arduino link step (missing symbols or duplicate runtime components).

These are expected first-pass integration blockers, not architecture failures.
