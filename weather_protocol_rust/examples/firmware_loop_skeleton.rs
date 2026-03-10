use std::fs;
use std::path::PathBuf;

use weather_protocol_rust::assembler::AssemblerResult;
use weather_protocol_rust::ble_adapter::BleAdapter;
use weather_protocol_rust::core::FirmwareCore;
use weather_protocol_rust::display::DisplayLines;
use weather_protocol_rust::driver::{DisplayError, TextDisplay};
use weather_protocol_rust::persistence::InMemoryPersistenceBackend;

/// Minimal stand-in for the future SparkFun SerLCD driver.
///
/// In board firmware, this is where the real I2C/Qwiic transport implementation will connect.
#[derive(Default)]
struct ConsoleDisplay {
    last: Option<DisplayLines>,
}

impl TextDisplay for ConsoleDisplay {
    fn render(&mut self, lines: &DisplayLines) -> Result<(), DisplayError> {
        if lines.line1.len() > 16 {
            return Err(DisplayError::LineTooLong {
                line_index: 1,
                length: lines.line1.len(),
            });
        }
        if lines.line2.len() > 16 {
            return Err(DisplayError::LineTooLong {
                line_index: 2,
                length: lines.line2.len(),
            });
        }

        if self.last.as_ref() != Some(lines) {
            println!("LCD:");
            println!("{}", lines.line1);
            println!("{}", lines.line2);
            self.last = Some(lines.clone());
        }
        Ok(())
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
    // Flash persistence backend connection point:
    // swap InMemoryPersistenceBackend with the board-specific flash backend implementation.
    let persistence_backend = InMemoryPersistenceBackend::default();
    let mut adapter = BleAdapter::new(persistence_backend);
    let mut display = ConsoleDisplay::default();

    // FirmwareCore is owned inside BleAdapter.
    let _core_type_marker: &str =
        std::any::type_name::<FirmwareCore<InMemoryPersistenceBackend, ConsoleDisplay>>();

    let mut now_unix: u32 = 1_700_000_000;

    // Simulated boot path.
    if let Err(error) = adapter.restore_on_boot(now_unix) {
        eprintln!("restore_on_boot failed: {:?}", error);
        return;
    }

    // Simulated BLE callback inputs.
    // On real hardware, BLE receive callbacks should pass fragment bytes here.
    let weather = load_fixture("valid_weather.bin");
    let position = load_fixture("valid_position.bin");
    let simulated_fragments: Vec<Vec<u8>> = vec![
        weather[..128].to_vec(),
        weather[128..256].to_vec(),
        weather[256..].to_vec(),
        position,
    ];

    // Final Block 1 runtime loop shape.
    for fragment in simulated_fragments {
        now_unix = now_unix.saturating_add(1);

        let assemble_state = match adapter.on_rx_fragment(&fragment, now_unix) {
            Ok(result) => result,
            Err(error) => {
                eprintln!("on_rx_fragment failed: {:?}", error);
                continue;
            }
        };
        match assemble_state {
            AssemblerResult::NeedMore {
                bytes_collected,
                expected_total_length,
            } => {
                println!(
                    "RX fragment accepted: need more bytes (collected={}, expected={:?})",
                    bytes_collected, expected_total_length
                );
            }
            AssemblerResult::PacketComplete(_) => {
                println!("RX fragment completed one packet");
            }
            AssemblerResult::Malformed(error) => {
                println!("RX fragment caused assembler reset: {:?}", error);
            }
        }

        if let Some(ack) = adapter.take_pending_ack() {
            // BLE transmit connection point:
            // on real hardware, write these ACK bytes back to the BLE characteristic.
            println!("SEND ACK {} bytes", ack.len());
        }

        if let Some(lines) = adapter.current_display_lines() {
            // LCD driver connection point:
            // on real hardware, pass these lines to the SerLCD TextDisplay implementation.
            if let Err(error) = display.render(lines) {
                eprintln!("display render failed: {:?}", error);
            }
        }
    }
}
