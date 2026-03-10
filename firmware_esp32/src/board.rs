use crate::assembler::AssemblerResult;
use crate::core::FirmwareCoreError;
use crate::display::DisplayLines;
use crate::persistence::PersistenceBackend;
use crate::runtime::FirmwareRuntime;

pub trait SerialLogger {
    fn log(&mut self, message: &str);
}

pub trait BleAckTransmitter {
    fn send_ack(&mut self, ack_bytes: &[u8]);
}

pub trait LcdOutput {
    fn write_lines(&mut self, line1: &str, line2: &str);
}

pub trait TimestampSource {
    fn now_unix(&mut self) -> u32;
}

/// Board-facing adapter that wires hardware boundaries to the firmware runtime pipeline.
///
/// Pipeline remains:
/// BLE fragment -> assembler -> parser -> ingress -> device state -> interpolation
/// -> display formatter -> display output.
pub struct Esp32BoardApp<B, S, A, L, T>
where
    B: PersistenceBackend,
    S: SerialLogger,
    A: BleAckTransmitter,
    L: LcdOutput,
    T: TimestampSource,
{
    runtime: FirmwareRuntime<B>,
    serial: S,
    ack_tx: A,
    lcd: L,
    clock: T,
    last_display: Option<DisplayLines>,
}

impl<B, S, A, L, T> Esp32BoardApp<B, S, A, L, T>
where
    B: PersistenceBackend,
    S: SerialLogger,
    A: BleAckTransmitter,
    L: LcdOutput,
    T: TimestampSource,
{
    pub fn new(runtime: FirmwareRuntime<B>, serial: S, ack_tx: A, lcd: L, clock: T) -> Self {
        Self {
            runtime,
            serial,
            ack_tx,
            lcd,
            clock,
            last_display: None,
        }
    }

    pub fn boot(&mut self) -> Result<(), FirmwareCoreError> {
        self.serial.log("BOOT start");
        let now = self.clock.now_unix();
        self.runtime.restore_on_boot(now)?;
        self.serial.log("BOOT restore rc=0");
        self.refresh_display_output();
        Ok(())
    }

    /// BLE RX fragment callback entry point for board integration.
    pub fn on_ble_rx_fragment(&mut self, fragment: &[u8]) -> Result<(), FirmwareCoreError> {
        let now = self.clock.now_unix();
        let ingest_result = self.runtime.on_ble_fragment(fragment, now)?;
        match ingest_result {
            AssemblerResult::NeedMore { .. } => self.serial.log("RX need more"),
            AssemblerResult::PacketComplete(_) => self.serial.log("RX packet complete"),
            AssemblerResult::Malformed(_) => self.serial.log("RX malformed"),
        }

        if let Some(ack) = self.runtime.take_pending_ack() {
            self.ack_tx.send_ack(&ack);
            self.serial.log("ACK sent");
        } else {
            self.serial.log("ACK none");
        }

        self.refresh_display_output();
        Ok(())
    }

    /// Display update path for periodic loop calls if needed.
    pub fn refresh_display_output(&mut self) {
        let Some(lines) = self.runtime.current_display_lines() else {
            self.serial.log("DISPLAY none");
            return;
        };

        if self.last_display.as_ref() == Some(lines) {
            return;
        }

        self.lcd.write_lines(lines.line1.as_str(), lines.line2.as_str());
        self.serial.log("DISPLAY updated");
        self.last_display = Some(lines.clone());
    }

    pub fn serial_mut(&mut self) -> &mut S {
        &mut self.serial
    }

    pub fn ack_tx_mut(&mut self) -> &mut A {
        &mut self.ack_tx
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BleAckTransmitter, Esp32BoardApp, LcdOutput, SerialLogger, TimestampSource,
    };
    use crate::persistence::InMemoryPersistenceBackend;
    use crate::runtime::FirmwareRuntime;
    use std::fs;
    use std::path::PathBuf;

    #[derive(Default)]
    struct VecSerial {
        logs: Vec<String>,
    }

    impl SerialLogger for VecSerial {
        fn log(&mut self, message: &str) {
            self.logs.push(message.to_string());
        }
    }

    #[derive(Default)]
    struct VecAckTx {
        sent: Vec<Vec<u8>>,
    }

    impl BleAckTransmitter for VecAckTx {
        fn send_ack(&mut self, ack_bytes: &[u8]) {
            self.sent.push(ack_bytes.to_vec());
        }
    }

    #[derive(Default)]
    struct VecLcd {
        writes: Vec<(String, String)>,
    }

    impl LcdOutput for VecLcd {
        fn write_lines(&mut self, line1: &str, line2: &str) {
            self.writes.push((line1.to_string(), line2.to_string()));
        }
    }

    struct CounterClock {
        now: u32,
    }

    impl CounterClock {
        fn new(start: u32) -> Self {
            Self { now: start }
        }
    }

    impl TimestampSource for CounterClock {
        fn now_unix(&mut self) -> u32 {
            self.now = self.now.saturating_add(1);
            self.now
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

    #[test]
    fn boot_and_fragment_path_produces_ack_and_display() {
        let runtime = FirmwareRuntime::new(InMemoryPersistenceBackend::default());
        let serial = VecSerial::default();
        let ack_tx = VecAckTx::default();
        let lcd = VecLcd::default();
        let clock = CounterClock::new(1_700_000_000);
        let mut app = Esp32BoardApp::new(runtime, serial, ack_tx, lcd, clock);

        app.boot().unwrap();
        app.on_ble_rx_fragment(&load_fixture("valid_weather.bin")).unwrap();
        app.on_ble_rx_fragment(&load_fixture("valid_position.bin")).unwrap();

        assert!(!app.ack_tx_mut().sent.is_empty());
        assert!(!app.serial_mut().logs.is_empty());
    }
}
