from pathlib import Path
import pprint
import sys

from .protocol import ProtocolError, decode_packet, packet_to_dict


def dump_packet(path: Path) -> str:
    packet = decode_packet(path.read_bytes())
    return pprint.pformat(packet_to_dict(packet), sort_dicts=False, width=100)


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: python3 -m weather_protocol.dump <path-to-packet>", file=sys.stderr)
        return 1

    path = Path(args[0])
    try:
        print(dump_packet(path))
    except FileNotFoundError:
        print("file not found: %s" % path, file=sys.stderr)
        return 1
    except ProtocolError as exc:
        print("decode failed: %s" % exc, file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
