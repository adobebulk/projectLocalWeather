
from weather_protocol.protocol import encode_position

def test_position_packet_size():
    pkt = encode_position(
        sequence=1,
        timestamp=1700000000,
        lat_e5=3405223,
        lon_e5=-11824368,
        accuracy_m=8,
        fix_timestamp=1700000000
    )
    assert len(pkt) == 32
