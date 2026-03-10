use crate::assembler::{AssemblerError, AssemblerResult, PacketAssembler};
use crate::display::{format_display, DisplayLines};
use crate::driver::{DisplayError, TextDisplay};
use crate::ingress::{IngressResult, PacketIngress};
use crate::persistence::{PersistenceBackend, PersistenceError, StatePersistence};
use crate::{PACKET_TYPE_POSITION_UPDATE_V1, PACKET_TYPE_REGIONAL_SNAPSHOT_V1};

/// Errors emitted by the firmware core harness.
#[derive(Debug, PartialEq, Eq)]
pub enum FirmwareCoreError {
    Assembler(AssemblerError),
    Persistence(PersistenceError),
    Display(DisplayError),
}

impl From<AssemblerError> for FirmwareCoreError {
    fn from(value: AssemblerError) -> Self {
        FirmwareCoreError::Assembler(value)
    }
}

impl From<PersistenceError> for FirmwareCoreError {
    fn from(value: PersistenceError) -> Self {
        FirmwareCoreError::Persistence(value)
    }
}

impl From<DisplayError> for FirmwareCoreError {
    fn from(value: DisplayError) -> Self {
        FirmwareCoreError::Display(value)
    }
}

/// Minimal firmware core that stitches together assembler, ingress, persistence, and display
/// while exposing the latest ack bytes and rendered display lines.
pub struct FirmwareCore<B, D>
where
    B: PersistenceBackend,
    D: TextDisplay,
{
    assembler: PacketAssembler,
    ingress: PacketIngress,
    persistence: StatePersistence<B>,
    display: D,
    latest_display_lines: Option<DisplayLines>,
    latest_ack_bytes: Option<Vec<u8>>,
}

impl<B, D> FirmwareCore<B, D>
where
    B: PersistenceBackend,
    D: TextDisplay,
{
    /// Creates a new firmware core with the provided persistence store and display.
    pub fn new(persistence: StatePersistence<B>, display: D) -> Self {
        Self {
            assembler: PacketAssembler::new(),
            ingress: PacketIngress::new(),
            persistence,
            display,
            latest_display_lines: None,
            latest_ack_bytes: None,
        }
    }

    /// Restores persisted weather / position state and refreshes the display estimate.
    pub fn restore_on_boot(
        &mut self,
        current_unix_timestamp: u32,
    ) -> Result<(), FirmwareCoreError> {
        let state = self
            .persistence
            .restore_device_state(current_unix_timestamp)?;
        self.ingress.replace_device_state(state);
        self.refresh_display_lines()?;
        Ok(())
    }

    /// Feeds transport bytes into the packet assembler. When a complete packet is ready it is
    /// routed through the ingress/ persistence/ display pipeline.
    pub fn push_transport_bytes(
        &mut self,
        chunk: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<AssemblerResult, FirmwareCoreError> {
        let result = self.assembler.push_bytes(chunk);
        if let AssemblerResult::PacketComplete(ref packet) = result {
            self.process_packet(packet, now_unix_timestamp)?;
        }
        Ok(result)
    }

    /// Returns the most recently rendered display lines, if any.
    pub fn current_display_lines(&self) -> Option<&DisplayLines> {
        self.latest_display_lines.as_ref()
    }

    /// Returns the most recently produced ack bytes, if any.
    pub fn latest_ack_bytes(&self) -> Option<&[u8]> {
        self.latest_ack_bytes.as_deref()
    }

    /// Consumes the firmware core and returns the owned persistence for reuse.
    pub fn into_persistence(self) -> StatePersistence<B> {
        self.persistence
    }

    fn process_packet(
        &mut self,
        packet: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<(), FirmwareCoreError> {
        let ingress_result = self.ingress.ingest_packet(packet, now_unix_timestamp);

        match ingress_result {
            IngressResult::Accepted(success) => {
                self.latest_ack_bytes = Some(success.ack_bytes.clone());
                self.persist_record(success.accepted_packet_type)?;
                self.refresh_display_lines()?;
            }
            IngressResult::Rejected(rejection) => {
                self.latest_ack_bytes = Some(rejection.ack_bytes.clone());
            }
        }

        Ok(())
    }

    fn persist_record(&mut self, packet_type: u8) -> Result<(), FirmwareCoreError> {
        match packet_type {
            PACKET_TYPE_REGIONAL_SNAPSHOT_V1 => {
                if let Some(snapshot) = self.ingress.device_state().active_weather_snapshot() {
                    self.persistence.save_weather_snapshot(snapshot)?;
                }
            }
            PACKET_TYPE_POSITION_UPDATE_V1 => {
                if let Some(position) = self.ingress.device_state().latest_position_update() {
                    self.persistence.save_position_update(position)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn refresh_display_lines(&mut self) -> Result<(), FirmwareCoreError> {
        if let Some(estimate) = self.ingress.device_state().current_estimate() {
            let lines = format_display(estimate);
            self.display.render(&lines)?;
            self.latest_display_lines = Some(lines);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::FirmwareCore;
    use crate::assembler::AssemblerResult;
    use crate::driver::MockDisplay;
    use crate::persistence::{InMemoryPersistenceBackend, StatePersistence};
    use crate::{parse_ack_v1, parse_packet, AckV1, Packet, STATUS_ACCEPTED, STATUS_BAD_CHECKSUM};
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

    fn parse_ack(bytes: &[u8]) -> AckV1 {
        parse_ack_v1(bytes).expect("ack bytes should parse")
    }

    fn build_persistent_state() -> StatePersistence<InMemoryPersistenceBackend> {
        let mut persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let weather_bytes = load_fixture("valid_weather.bin");
        if let Packet::RegionalSnapshotV1(snapshot) = parse_packet(&weather_bytes).unwrap() {
            persistence.save_weather_snapshot(&snapshot).unwrap();
        }
        let position_bytes = load_fixture("valid_position.bin");
        if let Packet::PositionUpdateV1(position) = parse_packet(&position_bytes).unwrap() {
            persistence.save_position_update(&position).unwrap();
        }
        persistence
    }

    #[test]
    fn boot_with_no_persisted_state() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.restore_on_boot(1_000).unwrap();

        assert!(core.current_display_lines().is_none());
        assert!(core.latest_ack_bytes().is_none());
    }

    #[test]
    fn boot_with_restored_weather_and_position() {
        let persistence = build_persistent_state();
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.restore_on_boot(2_000).unwrap();

        assert!(core.current_display_lines().is_some());
        assert!(core.latest_ack_bytes().is_none());
    }

    #[test]
    fn valid_weather_updates_display_output() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.push_transport_bytes(&load_fixture("valid_position.bin"), 2_900)
            .unwrap();
        let result = core
            .push_transport_bytes(&load_fixture("valid_weather.bin"), 3_000)
            .unwrap();
        assert!(matches!(result, AssemblerResult::PacketComplete(_)));

        let ack = parse_ack(core.latest_ack_bytes().unwrap());
        assert_eq!(ack.status_code, STATUS_ACCEPTED);
        assert!(core.current_display_lines().is_some());
    }

    #[test]
    fn valid_position_after_weather_updates_display() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.push_transport_bytes(&load_fixture("valid_weather.bin"), 4_000)
            .unwrap();
        let initial_lines = core.current_display_lines().cloned();

        let result = core
            .push_transport_bytes(&load_fixture("valid_position.bin"), 4_100)
            .unwrap();
        assert!(matches!(result, AssemblerResult::PacketComplete(_)));
        let ack = parse_ack(core.latest_ack_bytes().unwrap());
        assert_eq!(ack.status_code, STATUS_ACCEPTED);
        assert_ne!(core.current_display_lines(), initial_lines.as_ref());
    }

    #[test]
    fn invalid_packet_produces_rejection_ack() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.push_transport_bytes(&load_fixture("bad_checksum_weather.bin"), 5_000)
            .unwrap();
        let ack = parse_ack(core.latest_ack_bytes().unwrap());
        assert_eq!(ack.status_code, STATUS_BAD_CHECKSUM);
    }

    #[test]
    fn fragmented_weather_packet_updates_display() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());
        let packet = load_fixture("valid_weather.bin");
        let first = &packet[..100];
        let second = &packet[100..200];
        let third = &packet[200..];

        core.push_transport_bytes(&load_fixture("valid_position.bin"), 5_000)
            .unwrap();

        core.push_transport_bytes(first, 6_000).unwrap();
        core.push_transport_bytes(second, 6_000).unwrap();
        let result = core.push_transport_bytes(third, 6_000).unwrap();
        assert!(matches!(result, AssemblerResult::PacketComplete(_)));
        assert!(core.current_display_lines().is_some());
    }

    #[test]
    fn persistence_restore_followed_by_display_update() {
        let persistence = StatePersistence::new(InMemoryPersistenceBackend::default());
        let mut core = FirmwareCore::new(persistence, MockDisplay::new());

        core.push_transport_bytes(&load_fixture("valid_weather.bin"), 7_000)
            .unwrap();
        core.push_transport_bytes(&load_fixture("valid_position.bin"), 7_100)
            .unwrap();

        let persistence = core.into_persistence();
        let mut restored_core = FirmwareCore::new(persistence, MockDisplay::new());
        restored_core.restore_on_boot(7_200).unwrap();

        assert!(restored_core.current_display_lines().is_some());
    }
}
