local packets = require("c:\\Users\\Lenovo\\Downloads\\scripts\\roblox_army\\debug_packets")

local packetNames = {}
for name, _ in pairs(packets) do
    table.insert(packetNames, name)
end

table.sort(packetNames)

print("Total Packets: " .. #packetNames)
print("--- Packet IDs ---")
local pickupID = -1
for i, name in ipairs(packetNames) do
    -- ByteNet IDs usually start at 1 or 0 depending on implementation.
    -- Most Luau networking libs use 0-indexed for bytes to save space if possible, or 1-indexed.
    -- Let's print index (1-based) and index-1 (0-based)
    if name == "Pickup" then
        print(string.format("Packet: %s | ID (1-based): %d | ID (0-based): %d", name, i, i-1))
        pickupID = i
    end
end

-- Simulating the user's payload: \000\2139s\002\000
-- Bytes: 00, D5, 39, 73, 02, 00

-- If ByteNet uses 1-byte for ID (common for < 256 packets):
-- Byte 1: 00 -> Packet ID 0? 
-- If Packet ID is 0, what packet is it?
print("\n--- Packet at ID 0 (1st in list) ---")
print("Packet: " .. packetNames[1])

if packetNames[1] == "Pickup" then
    print("MATCH! 'Pickup' is the first packet alphabetically.")
else
    print("MISMATCH. Payload starts with 00, but Pickup is not ID 0.")
end

-- Let's look at the payload value: \2139s\002\000
-- D5 39 73 02 00
-- \213 = 11010101 (213 decimal, D5 hex)
-- 9 = 57 decimal (39 hex)
-- s = 115 decimal (73 hex)
-- \002 = 2 decimal (02 hex)
-- \000 = 0 decimal (00 hex)

-- Pickup is defined as uint32.
-- uint32 takes 4 bytes.
-- If payload is just one packet: ID + 4 bytes = 5 bytes total?
-- User string: \000 \213 9 s \002 \000 (6 bytes?)
-- Let's print the bytes of the user's string
local payload = "\000\2139s\002\000"
print("\n--- Payload Analysis ---")
print("Payload Length: " .. #payload)
for i = 1, #payload do
    local b = string.byte(payload, i, i)
    print(string.format("Byte %d: %d (0x%02X) Char: %s", i, b, b, string.char(b)))
end
