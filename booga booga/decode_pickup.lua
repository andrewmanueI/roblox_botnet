-- ByteNet Payload Decoder
-- Decodes payload: \000\2139s\002\000
-- Expected Packet: Pickup (ID 213 confirmed in previous session)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
local Replicated = ByteNetModule:WaitForChild("replicated")
local Values = require(Replicated.values)

-- 1. Get Dynamic ID for 'Pickup'
local packetID = 0
local success, boogaData = pcall(function() 
    return Values.access("booga"):read()
end)

if success and boogaData and boogaData.packets then
    packetID = boogaData.packets.Pickup
    print("Runtime Packet ID for 'Pickup':", packetID)
else
    -- Fallback to the ID you confirmed if reading fails
    packetID = 213 
    print("Could not read runtime ID, using confirmed fallback:", packetID)
end

-- 2. Validate Payload Header
-- Payload: \000 \213 (0, 213)
-- Byte 1: 0 (Namespace?)
-- Byte 2: 213 (Packet ID)
local payloadBytes = {0, 213, 57, 115, 2, 0} -- Bytes of \000\2139s\002\000

print("Payload Header: ", payloadBytes[1], payloadBytes[2])
if payloadBytes[2] == packetID then
    print("MATCH! Payload ID matches 'Pickup' ID.")
else
    print("WARNING: Payload ID (213) does not match runtime ID ("..packetID..").")
    print("This is normal if you rejoined the server. IDs change on every restart.")
end

-- 3. Decode Data (uint32)
-- Data Bytes: 39, 73, 02, 00 (0x39, 0x73, 0x02, 0x00)
-- Little Endian: 0x00027339
local b1 = payloadBytes[3]
local b2 = payloadBytes[4]
local b3 = payloadBytes[5]
local b4 = payloadBytes[6]

local entityID = b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)

print("--------------------------------------------------")
print("DECODED ENTITY ID:", entityID)
print("--------------------------------------------------")

-- 4. Verify in-game
-- Does this ID exist?
local found = false
for _, v in pairs(workspace:GetDescendants()) do
    if v:GetAttribute("EntityID") == entityID then
        print("SUCCESS! Found object with this EntityID:", v:GetFullName())
        found = true
        break
    end
end

if not found then
    print("Object with EntityID " .. entityID .. " not found in workspace (might be despawned or in storage).")
end
