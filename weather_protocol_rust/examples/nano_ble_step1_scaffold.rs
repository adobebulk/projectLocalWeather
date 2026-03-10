use std::fs;
use std::path::PathBuf;

use weather_protocol_rust::assembler::AssemblerResult;
use weather_protocol_rust::ble_adapter::BleAdapter;
use weather_protocol_rust::persistence::InMemoryPersistenceBackend;

/// Minimal board-shell scaffold for Nano ESP32 step-1 integration.
///
/// This demonstrates the callback handoff path:
/// BLE fragment -> BleAdapter/FirmwareCore -> ACK + display lines to serial.
struct NanoBoardShell {
    adapter: BleAdapter<InMemoryPersistenceBackend>,
    now_unix: u32,
}

impl NanoBoardShell {
    fn new(now_unix: u32) -> Self {
        Self {
            adapter: BleAdapter::new(InMemoryPersistenceBackend::default()),
            now_unix,
        }
    }

    fn setup(&mut self) {
        self.serial_init();
        self.setup_ble_service_and_characteristics();

        match self.adapter.restore_on_boot(self.now_unix) {
            Ok(()) => println!("[SERIAL] boot restore complete"),
            Err(error) => println!("[SERIAL] boot restore error: {:?}", error),
        }

        if let Some(lines) = self.adapter.current_display_lines() {
            self.print_display_lines(lines.line1.as_str(), lines.line2.as_str());
        } else {
            println!("[SERIAL] no display lines yet");
        }
    }

    /// Board BLE RX callback entry point.
    ///
    /// Real board BLE callback should forward the received fragment bytes here.
    fn on_ble_rx_fragment(&mut self, fragment: &[u8]) {
        self.now_unix = self.now_unix.saturating_add(1);

        match self.adapter.on_rx_fragment(fragment, self.now_unix) {
            Ok(AssemblerResult::NeedMore {
                bytes_collected,
                expected_total_length,
            }) => println!(
                "[SERIAL] RX need more: collected={} expected={:?}",
                bytes_collected, expected_total_length
            ),
            Ok(AssemblerResult::PacketComplete(_)) => {
                println!("[SERIAL] RX packet complete");
            }
            Ok(AssemblerResult::Malformed(error)) => {
                println!("[SERIAL] RX malformed: {:?}", error);
            }
            Err(error) => {
                println!("[SERIAL] RX processing error: {:?}", error);
            }
        }

        if let Some(ack_bytes) = self.adapter.take_pending_ack() {
            println!("[SERIAL] SEND ACK {} bytes", ack_bytes.len());
            self.send_ack_over_ble(&ack_bytes);
        }

        if let Some(lines) = self.adapter.current_display_lines() {
            self.print_display_lines(lines.line1.as_str(), lines.line2.as_str());
        }
    }

    fn serial_init(&self) {
        println!("[SERIAL] init");
    }

    fn setup_ble_service_and_characteristics(&self) {
        // Hardware integration point:
        // configure service UUIDs, RX characteristic, TX/ACK characteristic,
        // and register the board BLE receive callback.
        println!("[SERIAL] BLE setup point");
    }

    fn send_ack_over_ble(&self, ack_bytes: &[u8]) {
        // Hardware integration point:
        // write `ack_bytes` to BLE TX/notify characteristic.
        println!("[SERIAL] BLE TX hook ({} bytes)", ack_bytes.len());
    }

    fn print_display_lines(&self, line1: &str, line2: &str) {
        println!("[SERIAL] LCD:");
        println!("[SERIAL] {}", line1);
        println!("[SERIAL] {}", line2);
    }
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("crate has repo root parent")
        .join("fixtures")
        .join(name)
}

fn load_fixture(name: &str) -> Vec<u8> {
    fs::read(fixture_path(name)).expect("fixture file should be readable")
}

fn main() {
    let mut board = NanoBoardShell::new(1_700_000_000);
    board.setup();

    // Simulated fragmented weather write.
    let weather = load_fixture("valid_weather.bin");
    board.on_ble_rx_fragment(&weather[..120]);
    board.on_ble_rx_fragment(&weather[120..250]);
    board.on_ble_rx_fragment(&weather[250..]);

    // Simulated position update write.
    let position = load_fixture("valid_position.bin");
    board.on_ble_rx_fragment(&position);

    // Simulated bad packet write to show rejection ACK path.
    let bad = load_fixture("bad_checksum_weather.bin");
    board.on_ble_rx_fragment(&bad);
}
