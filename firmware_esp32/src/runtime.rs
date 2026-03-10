use crate::assembler::AssemblerResult;
use crate::ble_adapter::BleAdapter;
use crate::core::FirmwareCoreError;
use crate::display::DisplayLines;
use crate::persistence::PersistenceBackend;

/// Product-facing runtime boundary for Block 1 firmware.
///
/// This is the thin edge where hardware integrations should connect:
/// - BLE fragments in
/// - ACK bytes out
/// - display lines out
/// - boot restore trigger
pub struct FirmwareRuntime<B>
where
    B: PersistenceBackend,
{
    adapter: BleAdapter<B>,
}

impl<B> FirmwareRuntime<B>
where
    B: PersistenceBackend,
{
    pub fn new(backend: B) -> Self {
        Self {
            adapter: BleAdapter::new(backend),
        }
    }

    pub fn restore_on_boot(&mut self, now_unix_timestamp: u32) -> Result<(), FirmwareCoreError> {
        self.adapter.restore_on_boot(now_unix_timestamp)
    }

    pub fn on_ble_fragment(
        &mut self,
        fragment: &[u8],
        now_unix_timestamp: u32,
    ) -> Result<AssemblerResult, FirmwareCoreError> {
        self.adapter.on_rx_fragment(fragment, now_unix_timestamp)
    }

    pub fn take_pending_ack(&mut self) -> Option<Vec<u8>> {
        self.adapter.take_pending_ack()
    }

    pub fn current_display_lines(&self) -> Option<&DisplayLines> {
        self.adapter.current_display_lines()
    }
}
