use firmware_esp32::board::{
    BleAckTransmitter, Esp32BoardApp, LcdOutput, SerialLogger, TimestampSource,
};
use firmware_esp32::persistence::InMemoryPersistenceBackend;
use firmware_esp32::runtime::FirmwareRuntime;

#[cfg(any(target_arch = "xtensa", target_os = "espidf"))]
mod platform {
    use core::ffi::c_char;

    const SERIAL_BUFFER_LEN: usize = 192;

    unsafe extern "C" {
        fn ets_printf(fmt: *const c_char, ...) -> i32;
        fn esp_timer_get_time() -> i64;
    }

    pub fn serial_log(message: &str) {
        let mut buf = [0u8; SERIAL_BUFFER_LEN];
        let bytes = message.as_bytes();
        let max_payload = SERIAL_BUFFER_LEN.saturating_sub(2);
        let copy_len = bytes.len().min(max_payload);
        buf[..copy_len].copy_from_slice(&bytes[..copy_len]);
        buf[copy_len] = b'\n';
        buf[copy_len + 1] = 0;

        static FORMAT: &[u8] = b"%s\0";
        unsafe {
            let _ = ets_printf(
                FORMAT.as_ptr().cast::<c_char>(),
                buf.as_ptr().cast::<c_char>(),
            );
        }
    }

    pub fn now_unix() -> u32 {
        let micros = unsafe { esp_timer_get_time() };
        if micros <= 0 {
            return 0;
        }
        let secs = micros as u64 / 1_000_000;
        secs.min(u32::MAX as u64) as u32
    }
}

#[cfg(not(any(target_arch = "xtensa", target_os = "espidf")))]
mod platform {
    pub fn serial_log(message: &str) {
        println!("{}", message);
    }

    pub fn now_unix() -> u32 {
        static mut COUNTER: u32 = 1_700_000_000;
        unsafe {
            COUNTER = COUNTER.saturating_add(1);
            COUNTER
        }
    }
}

#[derive(Default)]
struct PlatformSerialLogger;

impl SerialLogger for PlatformSerialLogger {
    fn log(&mut self, message: &str) {
        platform::serial_log(message);
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

#[derive(Default)]
struct PlatformTimestampSource;

impl TimestampSource for PlatformTimestampSource {
    fn now_unix(&mut self) -> u32 {
        platform::now_unix()
    }
}

fn main() {
    // Minimal board-like bootstrap for first deployment attempts.
    let runtime = FirmwareRuntime::new(InMemoryPersistenceBackend::default());
    let serial = PlatformSerialLogger;
    let ack_tx = StdoutAckTx;
    let lcd = StdoutLcd;
    let clock = PlatformTimestampSource;
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
