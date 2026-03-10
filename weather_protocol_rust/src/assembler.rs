use crate::{HEADER_SIZE, MAGIC};

const MAX_PACKET_SIZE: usize = 65_535;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssemblerError {
    MalformedStart,
    WrongTotalLength(u16),
    PacketTooLarge(u16),
    TrailingBytesAfterPacket(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssemblerResult {
    NeedMore {
        bytes_collected: usize,
        expected_total_length: Option<usize>,
    },
    PacketComplete(Vec<u8>),
    Malformed(AssemblerError),
}

#[derive(Debug, Clone, Default)]
pub struct PacketAssembler {
    buffer: Vec<u8>,
    expected_total_length: Option<usize>,
}

impl PacketAssembler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push_bytes(&mut self, chunk: &[u8]) -> AssemblerResult {
        if chunk.is_empty() {
            return self.need_more();
        }

        if self.buffer.is_empty() {
            if let Some(start_offset) = find_magic_start(chunk) {
                if start_offset != 0 {
                    self.reset();
                    return AssemblerResult::Malformed(AssemblerError::MalformedStart);
                }
            } else {
                self.reset();
                return AssemblerResult::Malformed(AssemblerError::MalformedStart);
            }
        }

        self.buffer.extend_from_slice(chunk);

        if self.expected_total_length.is_none() && self.buffer.len() >= HEADER_SIZE {
            let total_length = u16::from_le_bytes([self.buffer[4], self.buffer[5]]);
            if usize::from(total_length) < HEADER_SIZE {
                self.reset();
                return AssemblerResult::Malformed(AssemblerError::WrongTotalLength(total_length));
            }
            if usize::from(total_length) > MAX_PACKET_SIZE {
                self.reset();
                return AssemblerResult::Malformed(AssemblerError::PacketTooLarge(total_length));
            }
            self.expected_total_length = Some(usize::from(total_length));
        }

        if let Some(expected_total_length) = self.expected_total_length {
            if self.buffer.len() == expected_total_length {
                let packet = std::mem::take(&mut self.buffer);
                self.expected_total_length = None;
                return AssemblerResult::PacketComplete(packet);
            }

            if self.buffer.len() > expected_total_length {
                let trailing_bytes = self.buffer.len() - expected_total_length;
                self.reset();
                return AssemblerResult::Malformed(AssemblerError::TrailingBytesAfterPacket(
                    trailing_bytes,
                ));
            }
        }

        self.need_more()
    }

    pub fn reset(&mut self) {
        self.buffer.clear();
        self.expected_total_length = None;
    }

    pub fn bytes_collected(&self) -> usize {
        self.buffer.len()
    }

    pub fn expected_total_length(&self) -> Option<usize> {
        self.expected_total_length
    }

    fn need_more(&self) -> AssemblerResult {
        AssemblerResult::NeedMore {
            bytes_collected: self.buffer.len(),
            expected_total_length: self.expected_total_length,
        }
    }
}

fn find_magic_start(bytes: &[u8]) -> Option<usize> {
    let magic_bytes = MAGIC.to_le_bytes();
    bytes.windows(2).position(|window| window == magic_bytes)
}

#[cfg(test)]
mod tests {
    use super::{AssemblerError, AssemblerResult, PacketAssembler};
    use crate::HEADER_SIZE;
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
    fn complete_packet_in_one_chunk() {
        let packet = load_fixture("valid_position.bin");
        let mut assembler = PacketAssembler::new();

        let result = assembler.push_bytes(&packet);

        assert_eq!(result, AssemblerResult::PacketComplete(packet));
        assert_eq!(assembler.bytes_collected(), 0);
    }

    #[test]
    fn complete_packet_split_across_multiple_chunks() {
        let packet = load_fixture("valid_position.bin");
        let mut assembler = PacketAssembler::new();

        let result_a = assembler.push_bytes(&packet[..10]);
        let result_b = assembler.push_bytes(&packet[10..20]);
        let result_c = assembler.push_bytes(&packet[20..]);

        assert!(matches!(
            result_a,
            AssemblerResult::NeedMore {
                bytes_collected: 10,
                expected_total_length: None
            }
        ));
        assert!(matches!(
            result_b,
            AssemblerResult::NeedMore {
                bytes_collected: 20,
                expected_total_length: Some(32)
            }
        ));
        assert_eq!(result_c, AssemblerResult::PacketComplete(packet));
    }

    #[test]
    fn chunk_smaller_than_header_needs_more() {
        let packet = load_fixture("valid_position.bin");
        let mut assembler = PacketAssembler::new();

        let result = assembler.push_bytes(&packet[..5]);

        assert!(matches!(
            result,
            AssemblerResult::NeedMore {
                bytes_collected: 5,
                expected_total_length: None
            }
        ));
    }

    #[test]
    fn malformed_start_bytes_are_rejected() {
        let mut assembler = PacketAssembler::new();

        let result = assembler.push_bytes(&[0x00, 0x01, 0x02, 0x03]);

        assert_eq!(result, AssemblerResult::Malformed(AssemblerError::MalformedStart));
        assert_eq!(assembler.bytes_collected(), 0);
    }

    #[test]
    fn wrong_total_length_causes_rejection_and_reset() {
        let mut packet = load_fixture("valid_position.bin");
        packet[4..6].copy_from_slice(&10u16.to_le_bytes());
        let mut assembler = PacketAssembler::new();

        let result = assembler.push_bytes(&packet[..HEADER_SIZE]);

        assert_eq!(
            result,
            AssemblerResult::Malformed(AssemblerError::WrongTotalLength(10))
        );
        assert_eq!(assembler.bytes_collected(), 0);
        assert_eq!(assembler.expected_total_length(), None);
    }

    #[test]
    fn two_packets_fed_sequentially_are_both_emitted() {
        let first_packet = load_fixture("valid_position.bin");
        let second_packet = load_fixture("valid_ack.bin");
        let mut assembler = PacketAssembler::new();

        let first_result = assembler.push_bytes(&first_packet);
        let second_result = assembler.push_bytes(&second_packet);

        assert_eq!(first_result, AssemblerResult::PacketComplete(first_packet));
        assert_eq!(second_result, AssemblerResult::PacketComplete(second_packet));
    }

    #[test]
    fn valid_weather_packet_split_into_realistic_fragments() {
        let packet = load_fixture("valid_weather.bin");
        let mut assembler = PacketAssembler::new();

        let fragments = [&packet[..20], &packet[20..180], &packet[180..320], &packet[320..]];
        let mut last_result = AssemblerResult::NeedMore {
            bytes_collected: 0,
            expected_total_length: None,
        };

        for fragment in fragments {
            last_result = assembler.push_bytes(fragment);
        }

        assert_eq!(last_result, AssemblerResult::PacketComplete(packet));
    }
}
