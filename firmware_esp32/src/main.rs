use firmware_esp32::board::{
    BleAckTransmitter, Esp32BoardApp, LcdOutput, SerialLogger, TimestampSource,
};
use firmware_esp32::persistence::InMemoryPersistenceBackend;
use firmware_esp32::runtime::FirmwareRuntime;

#[derive(Default)]
struct StdoutSerial;

impl SerialLogger for StdoutSerial {
    fn log(&mut self, message: &str) {
        println!("{}", message);
    }
}

#[derive(Default)]
struct StdoutAckTx;

impl BleAckTransmitter for StdoutAckTx {
    fn send_ack(&mut self, ack_bytes: &[u8]) {
        println!("BLE ACK TX bytes={}", ack_bytes.len());
    }
}

#[derive(Default)]
struct StdoutLcd;

impl LcdOutput for StdoutLcd {
    fn write_lines(&mut self, line1: &str, line2: &str) {
        println!("LCD:");
        println!("{}", line1);
        println!("{}", line2);
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

fn main() {
    // Minimal board-like bootstrap for first deployment attempts.
    let runtime = FirmwareRuntime::new(InMemoryPersistenceBackend::default());
    let serial = StdoutSerial;
    let ack_tx = StdoutAckTx;
    let lcd = StdoutLcd;
    let clock = CounterClock::new(1_700_000_000);
    let mut app = Esp32BoardApp::new(runtime, serial, ack_tx, lcd, clock);

    if let Err(error) = app.boot() {
        println!("BOOT error: {:?}", error);
    }

    // BLE callback shape:
    // board RX callback should pass actual fragments here.
    let fragment: [u8; 0] = [];
    if let Err(error) = app.on_ble_rx_fragment(&fragment) {
        println!("RX error: {:?}", error);
    }

    // Periodic display refresh shape:
    app.refresh_display_output();
}
