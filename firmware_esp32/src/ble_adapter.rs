use crate::assembler::AssemblerResult;
use crate::core::{FirmwareCore, FirmwareCoreError};
use crate::display::DisplayLines;
use crate::driver::{DisplayError, TextDisplay};
use crate::persistence::{PersistenceBackend, StatePersistence};

#[derive(Debug, Default)]
struct BleAdapterDisplay;

impl TextDisplay for BleAdapterDisplay {
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
        Ok(())
    }
}

/// Thin board-facing boundary for future BLE callbacks.
///
/// This adapter forwards transport fragments into `FirmwareCore` and tracks whether a new ACK
/// is pending for transmit.
pub struct BleAdapter<B>
where
    B: PersistenceBackend,
{
    core: FirmwareCore<B, BleAdapterDisplay>,
    pending_ack: Option<Vec<u8>>,
    last_seen_ack: Option<Vec<u8>>,
}

impl<B> BleAdapter<B>
where
    B: PersistenceBackend,
{
    pub fn new(backend: B) -> Self {
        let persistence = StatePersistence::new(backend);
        let core = FirmwareCore::new(persistence, BleAdapterDisplay);
        Self {
            core,
            pending_ack: None,
            last_seen_ack: None,
        }
    }

    pub fn restore_on_boot(&mut self, now_unix_timestamp: u32) -> Result<(), FirmwareCoreError> {
        self.core.restore_on_boot(now_unix_timestamp)
    }

    pub fn on_rx_fragment(
        &mut self,
        fragment: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<AssemblerResult, FirmwareCoreError> {
        let result = self
            .core
            .push_transport_bytes(fragment, now_unix_timestamp)?;
        self.capture_new_ack();
        Ok(result)
    }

    pub fn take_pending_ack(&mut self) -> Option<Vec<u8>> {
        self.pending_ack.take()
    }

    pub fn current_display_lines(&self) -> Option<&DisplayLines> {
        self.core.current_display_lines()
    }

    pub fn into_persistence(self) -> StatePersistence<B> {
        self.core.into_persistence()
    }

    fn capture_new_ack(&mut self) {
        let Some(ack) = self.core.latest_ack_bytes() else {
            return;
        };
        if self.last_seen_ack.as_deref() == Some(ack) {
            return;
        }
        let new_ack = ack.to_vec();
        self.last_seen_ack = Some(new_ack.clone());
        self.pending_ack = Some(new_ack);
    }
}

#[cfg(test)]
mod tests {
    use super::BleAdapter;
    use crate::assembler::AssemblerResult;
    use crate::parse_ack_v1;
    use crate::persistence::InMemoryPersistenceBackend;
    use crate::{STATUS_ACCEPTED, STATUS_BAD_CHECKSUM};
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
    fn fragmented_weather_without_position_has_no_display() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        let weather = load_fixture("valid_weather.bin");

        let result_a = adapter.on_rx_fragment(&weather[..100], 1_000).unwrap();
        let result_b = adapter.on_rx_fragment(&weather[100..300], 1_000).unwrap();
        let result_c = adapter.on_rx_fragment(&weather[300..], 1_000).unwrap();

        assert!(matches!(result_a, AssemblerResult::NeedMore { .. }));
        assert!(matches!(result_b, AssemblerResult::NeedMore { .. }));
        assert!(matches!(result_c, AssemblerResult::PacketComplete(_)));
        assert!(adapter.current_display_lines().is_none());
    }

    #[test]
    fn fragmented_weather_then_position_yields_display_lines() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        let weather = load_fixture("valid_weather.bin");

        adapter.on_rx_fragment(&weather[..128], 2_000).unwrap();
        adapter.on_rx_fragment(&weather[128..], 2_000).unwrap();
        adapter
            .on_rx_fragment(&load_fixture("valid_position.bin"), 2_100)
            .unwrap();

        assert!(adapter.current_display_lines().is_some());
    }

    #[test]
    fn accepted_packet_yields_pending_ack() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        let position = load_fixture("valid_position.bin");

        adapter.on_rx_fragment(&position, 3_000).unwrap();
        let ack = adapter.take_pending_ack().expect("ack should be present");
        let parsed = parse_ack_v1(&ack).expect("ack bytes should parse");
        assert_eq!(parsed.status_code, STATUS_ACCEPTED);
    }

    #[test]
    fn rejected_packet_yields_pending_ack() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        let invalid = load_fixture("bad_checksum_weather.bin");

        adapter.on_rx_fragment(&invalid, 4_000).unwrap();
        let ack = adapter.take_pending_ack().expect("ack should be present");
        let parsed = parse_ack_v1(&ack).expect("ack bytes should parse");
        assert_eq!(parsed.status_code, STATUS_BAD_CHECKSUM);
    }

    #[test]
    fn take_pending_ack_clears_pending_ack() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        let position = load_fixture("valid_position.bin");

        adapter.on_rx_fragment(&position, 5_000).unwrap();
        let first = adapter.take_pending_ack();
        let second = adapter.take_pending_ack();

        assert!(first.is_some());
        assert!(second.is_none());
    }

    #[test]
    fn boot_restore_through_adapter_restores_display() {
        let mut adapter = BleAdapter::new(InMemoryPersistenceBackend::default());
        adapter
            .on_rx_fragment(&load_fixture("valid_weather.bin"), 6_000)
            .unwrap();
        adapter
            .on_rx_fragment(&load_fixture("valid_position.bin"), 6_100)
            .unwrap();

        let persistence = adapter.into_persistence();
        let backend = persistence.backend().clone();

        let mut restored = BleAdapter::new(backend);
        restored.restore_on_boot(6_200).unwrap();

        assert!(restored.current_display_lines().is_some());
    }
}
