use crate::assembler::AssemblerResult;
use crate::ble_adapter::BleAdapter;
use crate::core::FirmwareCoreError;
use crate::display::DisplayLines;
use crate::persistence::{InMemoryPersistenceBackend, PersistenceBackend};

/// Fixed-size snapshot of display lines for boundary crossing.
///
/// Strings are copied into fixed 16-byte buffers and accompanied by explicit lengths.
/// This avoids borrowing/lifetime coupling across the board-shell seam.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeDisplayLines {
    pub line1_bytes: [u8; 16],
    pub line1_len: u8,
    pub line2_bytes: [u8; 16],
    pub line2_len: u8,
}

impl BridgeDisplayLines {
    fn from_display_lines(lines: &DisplayLines) -> Self {
        let mut line1_bytes = [0u8; 16];
        let mut line2_bytes = [0u8; 16];

        let line1 = lines.line1.as_bytes();
        let line2 = lines.line2.as_bytes();

        line1_bytes[..line1.len()].copy_from_slice(line1);
        line2_bytes[..line2.len()].copy_from_slice(line2);

        Self {
            line1_bytes,
            line1_len: line1.len() as u8,
            line2_bytes,
            line2_len: line2.len() as u8,
        }
    }
}

/// Minimal Rust bridge surface for a thin Arduino/Nano shell.
///
/// This wrapper keeps the boundary explicit:
/// - push bytes in (`push_ble_fragment`)
/// - pull ACK bytes out (`take_pending_ack_bytes`)
/// - pull display snapshots out (`current_display_lines_snapshot`)
pub struct FirmwareBridge<B>
where
    B: PersistenceBackend,
{
    adapter: BleAdapter<B>,
}

impl<B> FirmwareBridge<B>
where
    B: PersistenceBackend,
{
    /// Creates a new bridge over the existing adapter/core pipeline.
    pub fn new(backend: B) -> Self {
        Self {
            adapter: BleAdapter::new(backend),
        }
    }

    /// Restores persisted weather/position state and recomputes estimate on boot.
    pub fn restore_on_boot(&mut self, now_unix_timestamp: u32) -> Result<(), FirmwareCoreError> {
        self.adapter.restore_on_boot(now_unix_timestamp)
    }

    /// Forwards one incoming BLE fragment into the existing core pipeline.
    pub fn push_ble_fragment(
        &mut self,
        fragment: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<AssemblerResult, FirmwareCoreError> {
        self.adapter.on_rx_fragment(fragment, now_unix_timestamp)
    }

    /// Returns and clears the next pending ACK bytes, if available.
    pub fn take_pending_ack_bytes(&mut self) -> Option<Vec<u8>> {
        self.adapter.take_pending_ack()
    }

    /// Returns the latest display lines as an owned fixed-size snapshot.
    pub fn current_display_lines_snapshot(&self) -> Option<BridgeDisplayLines> {
        self.adapter
            .current_display_lines()
            .map(BridgeDisplayLines::from_display_lines)
    }

}

/// Convenience alias for host-side bring-up and tests.
pub type InMemoryFirmwareBridge = FirmwareBridge<InMemoryPersistenceBackend>;

impl InMemoryFirmwareBridge {
    pub fn new_in_memory() -> Self {
        Self::new(InMemoryPersistenceBackend::default())
    }
}

#[cfg(test)]
mod tests {
    use super::InMemoryFirmwareBridge;
    use crate::persistence::InMemoryPersistenceBackend;
    use crate::{parse_ack_v1, STATUS_ACCEPTED};
    use std::fs;
    use std::path::PathBuf;

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
    fn pending_ack_bytes_are_exposed_and_cleared() {
        let mut bridge = InMemoryFirmwareBridge::new(InMemoryPersistenceBackend::default());

        bridge
            .push_ble_fragment(&load_fixture("valid_position.bin"), 10_000)
            .unwrap();
        let ack = bridge
            .take_pending_ack_bytes()
            .expect("expected pending ack bytes");
        let parsed = parse_ack_v1(&ack).expect("ack should parse");
        assert_eq!(parsed.status_code, STATUS_ACCEPTED);
        assert!(bridge.take_pending_ack_bytes().is_none());
    }

    #[test]
    fn display_snapshot_is_exposed_after_weather_and_position() {
        let mut bridge = InMemoryFirmwareBridge::new_in_memory();
        bridge
            .push_ble_fragment(&load_fixture("valid_weather.bin"), 11_000)
            .unwrap();
        bridge
            .push_ble_fragment(&load_fixture("valid_position.bin"), 11_100)
            .unwrap();

        let lines = bridge
            .current_display_lines_snapshot()
            .expect("display lines should be available");
        assert!(lines.line1_len > 0);
        assert!(lines.line2_len > 0);
        assert!(usize::from(lines.line1_len) <= 16);
        assert!(usize::from(lines.line2_len) <= 16);
    }
}
