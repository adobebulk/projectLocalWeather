use crate::assembler::AssemblerResult;
use crate::core::{FirmwareCore, FirmwareCoreError};
use crate::display::DisplayLines;
use crate::driver::{DisplayError, LoggableDisplay, TextDisplay};
use crate::parse_ack_v1;
use crate::persistence::{PersistenceBackend, StatePersistence};

/// Simple display implementation that records serial-style log entries.
#[derive(Debug, Default)]
pub struct SerialDisplay {
    log: Vec<String>,
}

impl SerialDisplay {
    pub fn new() -> Self {
        Self { log: Vec::new() }
    }
}

impl TextDisplay for SerialDisplay {
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
        self.log
            .push(format!("DISPLAY | {} | {}", lines.line1, lines.line2));
        Ok(())
    }
}

impl LoggableDisplay for SerialDisplay {
    fn drain_logs(&mut self) -> Vec<String> {
        std::mem::take(&mut self.log)
    }
}

/// Runtime harness that drives `FirmwareCore` and exposes serial logs.
pub struct SerialRuntime<B>
where
    B: PersistenceBackend + Clone,
{
    core: FirmwareCore<B, SerialDisplay>,
    display_log: Vec<String>,
    ack_log: Vec<String>,
    last_logged_ack: Option<Vec<u8>>,
}

impl<B> SerialRuntime<B>
where
    B: PersistenceBackend + Clone,
{
    pub fn new(backend: B) -> Self {
        let display = SerialDisplay::new();
        let persistence = StatePersistence::new(backend);
        let core = FirmwareCore::new(persistence, display);
        Self {
            core,
            display_log: Vec::new(),
            ack_log: Vec::new(),
            last_logged_ack: None,
        }
    }

    pub fn restore_on_boot(&mut self, now_unix_timestamp: u32) -> Result<(), FirmwareCoreError> {
        self.core.restore_on_boot(now_unix_timestamp)?;
        self.flush_display_logs();
        Ok(())
    }

    pub fn push_transport_bytes(
        &mut self,
        chunk: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<AssemblerResult, FirmwareCoreError> {
        let result = self.core.push_transport_bytes(chunk, now_unix_timestamp)?;
        self.flush_display_logs();
        self.capture_ack_log();
        Ok(result)
    }

    pub fn logs(&self) -> &[String] {
        &self.display_log
    }

    pub fn ack_logs(&self) -> &[String] {
        &self.ack_log
    }

    fn flush_display_logs(&mut self) {
        let new_entries = self.core.take_display_logs();
        self.display_log.extend(new_entries);
    }

    fn capture_ack_log(&mut self) {
        if let Some(bytes) = self.core.latest_ack_bytes() {
            if self.last_logged_ack.as_deref() == Some(bytes) {
                return;
            }
            if let Ok(ack) = parse_ack_v1(bytes) {
                self.ack_log.push(format!(
                    "ACK seq={} status={}",
                    ack.header.sequence, ack.status_code
                ));
                self.last_logged_ack = Some(bytes.to_vec());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SerialRuntime;
    use crate::persistence::InMemoryPersistenceBackend;

    fn load_fixture(name: &str) -> Vec<u8> {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("fixtures")
            .join(name);
        std::fs::read(path).expect("fixture should exist")
    }

    #[test]
    fn valid_weather_and_position_yield_display_lines() {
        let mut runtime = SerialRuntime::new(InMemoryPersistenceBackend::default());

        runtime
            .push_transport_bytes(&load_fixture("valid_weather.bin"), 1_000)
            .unwrap();
        runtime
            .push_transport_bytes(&load_fixture("valid_position.bin"), 1_100)
            .unwrap();

        assert!(runtime
            .logs()
            .iter()
            .any(|entry| entry.starts_with("DISPLAY")));
        assert!(runtime.ack_logs().len() >= 2);
    }

    #[test]
    fn rejection_path_logs_ack_without_crash() {
        let mut runtime = SerialRuntime::new(InMemoryPersistenceBackend::default());

        runtime
            .push_transport_bytes(&load_fixture("bad_checksum_weather.bin"), 2_000)
            .unwrap();

        assert!(runtime
            .ack_logs()
            .iter()
            .any(|entry| entry.contains("status=4")));
        assert!(runtime.logs().is_empty());
    }

    #[test]
    fn boot_restore_replays_display_after_restore() {
        let mut runtime = SerialRuntime::new(InMemoryPersistenceBackend::default());
        runtime
            .push_transport_bytes(&load_fixture("valid_weather.bin"), 3_000)
            .unwrap();
        runtime
            .push_transport_bytes(&load_fixture("valid_position.bin"), 3_100)
            .unwrap();

        let persistence = runtime.core.into_persistence();
        let backend = persistence.backend().clone();

        let mut restored_runtime = SerialRuntime::new(backend);
        restored_runtime.restore_on_boot(3_200).unwrap();

        assert!(restored_runtime
            .logs()
            .iter()
            .any(|entry| entry.starts_with("DISPLAY")));
    }
}
