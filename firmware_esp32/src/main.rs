use firmware_esp32::assembler::AssemblerResult;
use firmware_esp32::persistence::InMemoryPersistenceBackend;
use firmware_esp32::runtime::FirmwareRuntime;

fn main() {
    // Boot scaffold for first hardware-deployment attempts.
    // Replace stdout logging with board serial output in target integration.
    let mut runtime = FirmwareRuntime::new(InMemoryPersistenceBackend::default());
    let mut now_unix: u32 = 1_700_000_000;

    println!("BOOT start");
    match runtime.restore_on_boot(now_unix) {
        Ok(()) => println!("BOOT restore rc=0"),
        Err(error) => println!("BOOT restore error: {:?}", error),
    }

    if runtime.current_display_lines().is_none() {
        println!("DISPLAY none");
    }

    // Loop shape for board integration:
    // 1. receive BLE fragment bytes
    // 2. call runtime.on_ble_fragment(...)
    // 3. if ACK available, send over BLE
    // 4. if display lines available, write to LCD
    let fake_fragment: [u8; 0] = [];
    now_unix = now_unix.saturating_add(1);
    match runtime.on_ble_fragment(&fake_fragment, now_unix) {
        Ok(AssemblerResult::NeedMore { .. }) => println!("RX need more"),
        Ok(AssemblerResult::PacketComplete(_)) => println!("RX packet complete"),
        Ok(AssemblerResult::Malformed(error)) => println!("RX malformed: {:?}", error),
        Err(error) => println!("RX error: {:?}", error),
    }

    if let Some(ack) = runtime.take_pending_ack() {
        println!("ACK bytes={}", ack.len());
    } else {
        println!("ACK none");
    }
}
