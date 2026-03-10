use crate::assembler::AssemblerResult;
use crate::bridge::{BridgeDisplayLines, InMemoryFirmwareBridge};

/// Opaque bridge handle for C/Arduino callers.
///
/// Ownership rule:
/// - created by `bridge_new_in_memory`
/// - released by `bridge_free`
pub struct FirmwareBridgeHandle {
    bridge: InMemoryFirmwareBridge,
}

/// Result codes returned by the minimal C ABI.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeResultCode {
    Ok = 0,
    NoData = 1,
    NullPointer = 2,
    InvalidArgument = 3,
    BufferTooSmall = 4,
    RuntimeError = 5,
}

/// Packet ingestion state returned by `bridge_push_ble_fragment`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeIngestState {
    NeedMore = 0,
    PacketComplete = 1,
    Malformed = 2,
}

/// C-friendly snapshot of two display lines.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeDisplayLinesC {
    pub line1: [u8; 16],
    pub line1_len: u8,
    pub line2: [u8; 16],
    pub line2_len: u8,
}

impl From<BridgeDisplayLines> for BridgeDisplayLinesC {
    fn from(value: BridgeDisplayLines) -> Self {
        Self {
            line1: value.line1_bytes,
            line1_len: value.line1_len,
            line2: value.line2_bytes,
            line2_len: value.line2_len,
        }
    }
}

fn ingest_state_from_result(result: AssemblerResult) -> BridgeIngestState {
    match result {
        AssemblerResult::NeedMore { .. } => BridgeIngestState::NeedMore,
        AssemblerResult::PacketComplete(_) => BridgeIngestState::PacketComplete,
        AssemblerResult::Malformed(_) => BridgeIngestState::Malformed,
    }
}

/// Creates a new bridge handle using the in-memory persistence backend.
///
/// Future board integration can replace this with a flash-backed constructor while keeping
/// the rest of the ABI shape stable.
#[no_mangle]
pub extern "C" fn bridge_new_in_memory() -> *mut FirmwareBridgeHandle {
    let handle = FirmwareBridgeHandle {
        bridge: InMemoryFirmwareBridge::new_in_memory(),
    };
    Box::into_raw(Box::new(handle))
}

/// Releases a bridge handle allocated by `bridge_new_in_memory`.
#[no_mangle]
pub unsafe extern "C" fn bridge_free(handle: *mut FirmwareBridgeHandle) {
    if handle.is_null() {
        return;
    }
    let _ = Box::from_raw(handle);
}

/// Restores persisted state and recomputes estimate at boot.
#[no_mangle]
pub unsafe extern "C" fn bridge_restore_on_boot(
    handle: *mut FirmwareBridgeHandle,
    now_unix_timestamp: u32,
) -> BridgeResultCode {
    let Some(handle_ref) = handle.as_mut() else {
        return BridgeResultCode::NullPointer;
    };

    match handle_ref.bridge.restore_on_boot(now_unix_timestamp) {
        Ok(()) => BridgeResultCode::Ok,
        Err(_) => BridgeResultCode::RuntimeError,
    }
}

/// Pushes one BLE fragment into the Rust firmware pipeline.
#[no_mangle]
pub unsafe extern "C" fn bridge_push_ble_fragment(
    handle: *mut FirmwareBridgeHandle,
    fragment_ptr: *const u8,
    fragment_len: usize,
    now_unix_timestamp: u32,
    out_ingest_state: *mut BridgeIngestState,
) -> BridgeResultCode {
    let Some(handle_ref) = handle.as_mut() else {
        return BridgeResultCode::NullPointer;
    };
    let Some(out_state_ref) = out_ingest_state.as_mut() else {
        return BridgeResultCode::NullPointer;
    };
    if fragment_len > 0 && fragment_ptr.is_null() {
        return BridgeResultCode::InvalidArgument;
    }

    let fragment = std::slice::from_raw_parts(fragment_ptr, fragment_len);
    match handle_ref
        .bridge
        .push_ble_fragment(fragment, now_unix_timestamp)
    {
        Ok(result) => {
            *out_state_ref = ingest_state_from_result(result);
            BridgeResultCode::Ok
        }
        Err(_) => BridgeResultCode::RuntimeError,
    }
}

/// Retrieves and clears the next pending ACK bytes, if any.
///
/// If an ACK exists but `out_capacity` is too small, returns `BufferTooSmall` and
/// writes the required length to `out_ack_len`.
#[no_mangle]
pub unsafe extern "C" fn bridge_take_pending_ack(
    handle: *mut FirmwareBridgeHandle,
    out_buf: *mut u8,
    out_capacity: usize,
    out_ack_len: *mut usize,
) -> BridgeResultCode {
    let Some(handle_ref) = handle.as_mut() else {
        return BridgeResultCode::NullPointer;
    };
    let Some(out_len_ref) = out_ack_len.as_mut() else {
        return BridgeResultCode::NullPointer;
    };

    let Some(ack) = handle_ref.bridge.take_pending_ack_bytes() else {
        *out_len_ref = 0;
        return BridgeResultCode::NoData;
    };

    *out_len_ref = ack.len();
    if ack.len() > out_capacity {
        return BridgeResultCode::BufferTooSmall;
    }
    if ack.is_empty() {
        return BridgeResultCode::Ok;
    }
    if out_buf.is_null() {
        return BridgeResultCode::NullPointer;
    }

    std::ptr::copy_nonoverlapping(ack.as_ptr(), out_buf, ack.len());
    BridgeResultCode::Ok
}

/// Returns the latest display lines snapshot, if available.
#[no_mangle]
pub unsafe extern "C" fn bridge_get_display_lines(
    handle: *const FirmwareBridgeHandle,
    out_lines: *mut BridgeDisplayLinesC,
) -> BridgeResultCode {
    let Some(handle_ref) = handle.as_ref() else {
        return BridgeResultCode::NullPointer;
    };
    let Some(out_lines_ref) = out_lines.as_mut() else {
        return BridgeResultCode::NullPointer;
    };

    let Some(lines) = handle_ref.bridge.current_display_lines_snapshot() else {
        return BridgeResultCode::NoData;
    };

    *out_lines_ref = lines.into();
    BridgeResultCode::Ok
}

#[cfg(test)]
mod tests {
    use super::{
        bridge_free, bridge_get_display_lines, bridge_new_in_memory, bridge_push_ble_fragment,
        bridge_take_pending_ack, BridgeDisplayLinesC, BridgeIngestState, BridgeResultCode,
    };
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
    fn ffi_ack_and_display_flow() {
        unsafe {
            let handle = bridge_new_in_memory();
            assert!(!handle.is_null());

            let weather = load_fixture("valid_weather.bin");
            let mut state = BridgeIngestState::NeedMore;
            let rc = bridge_push_ble_fragment(
                handle,
                weather.as_ptr(),
                weather.len(),
                20_000,
                &mut state,
            );
            assert_eq!(rc, BridgeResultCode::Ok);

            let mut ack_buf = [0u8; 64];
            let mut ack_len = 0usize;
            let rc_ack = bridge_take_pending_ack(
                handle,
                ack_buf.as_mut_ptr(),
                ack_buf.len(),
                &mut ack_len,
            );
            assert_eq!(rc_ack, BridgeResultCode::Ok);
            assert!(ack_len > 0);

            let mut lines = BridgeDisplayLinesC {
                line1: [0u8; 16],
                line1_len: 0,
                line2: [0u8; 16],
                line2_len: 0,
            };
            let no_lines_rc = bridge_get_display_lines(handle, &mut lines);
            assert_eq!(no_lines_rc, BridgeResultCode::NoData);

            let position = load_fixture("valid_position.bin");
            let rc_pos = bridge_push_ble_fragment(
                handle,
                position.as_ptr(),
                position.len(),
                20_100,
                &mut state,
            );
            assert_eq!(rc_pos, BridgeResultCode::Ok);

            let display_rc = bridge_get_display_lines(handle, &mut lines);
            assert_eq!(display_rc, BridgeResultCode::Ok);
            assert!(lines.line1_len > 0);
            assert!(lines.line2_len > 0);

            bridge_free(handle);
        }
    }

    #[test]
    fn ffi_ack_buffer_too_small_reports_required_length() {
        unsafe {
            let handle = bridge_new_in_memory();
            assert!(!handle.is_null());

            let position = load_fixture("valid_position.bin");
            let mut state = BridgeIngestState::NeedMore;
            let rc = bridge_push_ble_fragment(
                handle,
                position.as_ptr(),
                position.len(),
                30_000,
                &mut state,
            );
            assert_eq!(rc, BridgeResultCode::Ok);

            let mut ack_buf = [0u8; 2];
            let mut ack_len = 0usize;
            let rc_ack = bridge_take_pending_ack(
                handle,
                ack_buf.as_mut_ptr(),
                ack_buf.len(),
                &mut ack_len,
            );
            assert_eq!(rc_ack, BridgeResultCode::BufferTooSmall);
            assert!(ack_len > ack_buf.len());

            bridge_free(handle);
        }
    }
}
