import asyncio
from bleak import BleakScanner, BleakClient

DEVICE_NAME = "WeatherComputer"
RX_UUID = "19B10011-E8F2-537E-4F6C-D104768A1214"
TX_UUID = "19B10012-E8F2-537E-4F6C-D104768A1214"

# Example valid 32-byte position packet from earlier work
POSITION_HEX = "4357010220000100000008f8536578d3dc38b2f5330010934bff0800eaf75365"

# Example valid 470-byte weather packet from earlier work
WEATHER_HEX = (
    "43570101d6010200000000f15365a925c1c6b2f5330010934bfff000f0000303030078000500000030"
    "023700410014010200102700003c002b02390043001901020010270000780026023b0045001e010200"
    "1027000000002b023800420016010200de2600003c0026023a0044001b010200de260000780021023c"
    "00460020010200de260000000026023900430018010200ac2600003c0021023b0045001d010200ac26"
    "000078001c023d00470022010200ac26000000003a023900430017010200ac2600003c0035023b0045"
    "001c010200ac260000780030023d00470021010200ac260000000035023a004400190102007a260300"
    "3c0030023c0046001e0102007a26030078002b023e004800230103007a260300000030023b0045001b"
    "010200482600003c002b023d0047002001020048260000780026023f00490025010300482600000000"
    "44023b0045001a010200482600003c003f023d0047001f0102004826000078003a023f004900240103"
    "004826000000003f023c0046001c010200162600003c003a023e004800210102001626000078003502"
    "40004a00260103001626000000003a023d0047001e010200e42500003c0035023f00490023010300e4"
    "2500007800300241004b0028010300e4250000"
)

def chunk_bytes(data: bytes, chunk_size: int = 20):
    for i in range(0, len(data), chunk_size):
        yield data[i:i+chunk_size]

def on_notify(_: str, data: bytearray):
    print(f"NOTIFY: {data.hex()}")

async def main():
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=5.0)

    target = None
    for d in devices:
        if d.name == DEVICE_NAME:
            target = d
            break

    if target is None:
        raise RuntimeError(f"Could not find device named {DEVICE_NAME}")

    print(f"Connecting to {target.name} ({target.address})")
    async with BleakClient(target) as client:
        print("Connected:", client.is_connected)

        await client.start_notify(TX_UUID, on_notify)
        print("Notifications enabled")

        # Send position packet in one write
        pos = bytes.fromhex(POSITION_HEX)
        print(f"Writing position packet: {len(pos)} bytes")
        await client.write_gatt_char(RX_UUID, pos, response=False)

        await asyncio.sleep(1.0)

        # Send weather packet in 20-byte chunks
        weather = bytes.fromhex(WEATHER_HEX)
        print(f"Writing weather packet in chunks: {len(weather)} bytes")
        for i, chunk in enumerate(chunk_bytes(weather, 20), start=1):
            print(f"  chunk {i}: {len(chunk)} bytes")
            await client.write_gatt_char(RX_UUID, chunk, response=False)
            await asyncio.sleep(0.05)

        await asyncio.sleep(2.0)
        await client.stop_notify(TX_UUID)

asyncio.run(main())