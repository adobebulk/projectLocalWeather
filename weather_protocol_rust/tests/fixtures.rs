use std::fs;
use std::path::PathBuf;

use weather_protocol_rust::device_state::DeviceState;
use weather_protocol_rust::{
    crc32_with_zeroed_checksum, parse_ack_v1, parse_packet, parse_position_update_v1,
    parse_regional_snapshot_v1, ParseError, Packet, CHECKSUM_OFFSET, REGIONAL_PACKET_SIZE,
};

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

fn rewrite_checksum(packet: &mut [u8]) {
    let checksum = crc32_with_zeroed_checksum(packet);
    packet[CHECKSUM_OFFSET..CHECKSUM_OFFSET + 4].copy_from_slice(&checksum.to_le_bytes());
}

#[test]
fn accepts_valid_position_fixture() {
    let packet = load_fixture("valid_position.bin");
    let parsed = parse_position_update_v1(&packet).expect("valid position fixture should parse");

    assert_eq!(parsed.header.total_length, 32);
    assert_eq!(parsed.lat_e5, 3_405_223);
    assert_eq!(parsed.lon_e5, -11_824_368);
    assert_eq!(parsed.accuracy_m, 8);
}

#[test]
fn accepts_valid_ack_fixture() {
    let packet = load_fixture("valid_ack.bin");
    let parsed = parse_ack_v1(&packet).expect("valid ack fixture should parse");

    assert_eq!(parsed.header.total_length, 32);
    assert_eq!(parsed.echoed_sequence, 1);
    assert_eq!(parsed.status_code, 0);
}

#[test]
fn accepts_valid_weather_fixture() {
    let packet = load_fixture("valid_weather.bin");
    let parsed =
        parse_regional_snapshot_v1(&packet).expect("valid weather fixture should parse");

    assert_eq!(parsed.header.total_length as usize, REGIONAL_PACKET_SIZE);
    assert_eq!(parsed.metadata.grid_rows, 3);
    assert_eq!(parsed.metadata.grid_cols, 3);
    assert_eq!(parsed.anchor_slots[0][0].slot_offset_min, 0);
    assert_eq!(parsed.anchor_slots[0][1].slot_offset_min, 60);
    assert_eq!(parsed.anchor_slots[0][2].slot_offset_min, 120);
}

#[test]
fn parse_packet_dispatches_valid_fixtures() {
    let weather = load_fixture("valid_weather.bin");
    let position = load_fixture("valid_position.bin");
    let ack = load_fixture("valid_ack.bin");

    assert!(matches!(
        parse_packet(&weather).expect("weather fixture should parse"),
        Packet::RegionalSnapshotV1(_)
    ));
    assert!(matches!(
        parse_packet(&position).expect("position fixture should parse"),
        Packet::PositionUpdateV1(_)
    ));
    assert!(matches!(
        parse_packet(&ack).expect("ack fixture should parse"),
        Packet::AckV1(_)
    ));
}

#[test]
fn rejects_bad_checksum_fixture() {
    let packet = load_fixture("bad_checksum_weather.bin");
    let error = parse_regional_snapshot_v1(&packet).expect_err("bad checksum should fail");

    assert!(matches!(error, ParseError::BadChecksum { .. }));
}

#[test]
fn rejects_bad_length_fixture() {
    let packet = load_fixture("bad_length_position.bin");
    let error = parse_position_update_v1(&packet).expect_err("bad length should fail");

    assert!(matches!(
        error,
        ParseError::WrongPacketLengthInHeader { expected: 32, actual: 31 }
    ));
}

#[test]
fn rejects_invalid_precip_fixture() {
    let packet = load_fixture("invalid_precip_weather.bin");
    let error =
        parse_regional_snapshot_v1(&packet).expect_err("invalid precip should fail");

    assert!(matches!(error, ParseError::InvalidPrecipProbability(101)));
}

#[test]
fn rejects_bad_magic() {
    let mut packet = load_fixture("valid_weather.bin");
    packet[0..2].copy_from_slice(&0u16.to_le_bytes());
    rewrite_checksum(&mut packet);

    let error = parse_regional_snapshot_v1(&packet).expect_err("bad magic should fail");

    assert!(matches!(
        error,
        ParseError::BadMagic {
            expected: 0x5743,
            actual: 0
        }
    ));
}

#[test]
fn rejects_unsupported_version() {
    let mut packet = load_fixture("valid_weather.bin");
    packet[2] = 9;
    rewrite_checksum(&mut packet);

    let error =
        parse_regional_snapshot_v1(&packet).expect_err("unsupported version should fail");

    assert!(matches!(
        error,
        ParseError::UnsupportedVersion {
            expected: 1,
            actual: 9
        }
    ));
}

#[test]
fn rejects_invalid_grid_shape() {
    let mut packet = load_fixture("valid_weather.bin");
    packet[30] = 4;
    rewrite_checksum(&mut packet);

    let error = parse_regional_snapshot_v1(&packet).expect_err("bad grid shape should fail");

    assert!(matches!(error, ParseError::GridRowsMustBe3(4)));
}

#[test]
fn rejects_invalid_slot_offsets() {
    let mut packet = load_fixture("valid_weather.bin");
    let slot_offset_bytes = 38usize;
    packet[slot_offset_bytes..slot_offset_bytes + 2].copy_from_slice(&30u16.to_le_bytes());
    rewrite_checksum(&mut packet);

    let error = parse_regional_snapshot_v1(&packet).expect_err("bad slot offsets should fail");

    assert!(matches!(
        error,
        ParseError::InvalidSlotOffsets {
            anchor_index: 0,
            expected: [0, 60, 120],
            actual: [30, 60, 120]
        }
    ));
}

#[test]
fn end_to_end_fixture_bytes_to_device_state_estimate() {
    let weather_packet = load_fixture("valid_weather.bin");
    let position_packet = load_fixture("valid_position.bin");

    let weather = parse_regional_snapshot_v1(&weather_packet)
        .expect("valid weather fixture should parse");
    let position = parse_position_update_v1(&position_packet)
        .expect("valid position fixture should parse");

    let mut device_state = DeviceState::new();
    device_state
        .apply_weather_snapshot(weather)
        .expect("weather snapshot should apply");
    device_state
        .apply_position_update(position)
        .expect("position update should apply");

    let estimate = device_state
        .current_estimate()
        .expect("device state should contain an estimate");

    assert!(estimate.air_temp_c_tenths != 0);
    assert!(estimate.wind_speed_mps_tenths != 0);
    assert!(estimate.visibility_m != 0);
    assert!(estimate.precip_prob_pct <= 100);
    assert!(estimate.confidence_score > 0);
}
