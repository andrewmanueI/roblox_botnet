import re

# Read the file content
try:
    with open('debug_packets.lua', 'r') as f:
        content = f.read()
except FileNotFoundError:
    print("Error: debug_packets.lua not found.")
    exit(1)

packet_names = re.findall(r'(\w+)\s*=\s*"', content)
packet_names.sort()

print(f"Total Packets Found: {len(packet_names)}")
print("--- Packet IDs ---")

# Print Packet 0 (if valid)
if len(packet_names) > 0:
    print(f"Index 0: {packet_names[0]}")

# Print Packet 213 (0xD5) (if within range)
target_id = 0xD5 # 213
if target_id < len(packet_names):
    print(f"Index {target_id} (0xD5/213): {packet_names[target_id]}")
else:
    print(f"Index {target_id} is out of range (Total: {len(packet_names)})")

# Print Packet ID for 'Pickup'
pickup_id = -1
for i, name in enumerate(packet_names):
    if name == "Pickup":
        print(f"Packet: {name} | Index: {i} ({hex(i)})")
        pickup_id = i

# Payload Analysis (Reprise for Index 213)
# Bytes: 00 D5 39 73 02 00
# Possible Structure: Namespace(0), PacketID(213/D5), Data(39 73 02 00)
# Data: 00027339 (LE) -> 160657 (LE)
# Let's decode as uint32
payload_bytes = [0x39, 0x73, 0x02, 0x00]
val = int.from_bytes(payload_bytes, byteorder='little')
print(f"\nDecoding remaining bytes [39, 73, 02, 00] as uint32:")
print(f"Value: {val}")

# Also check for 'Interact' or similar if 213 matches
