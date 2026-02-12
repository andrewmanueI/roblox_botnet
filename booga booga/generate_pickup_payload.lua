-- Generate Payload for Nearest Object
-- Finds the nearest object with an "EntityID" and generates the ByteNet payload to pick it up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- 1. Get Dynamic ID for 'Pickup' (Same logic as before)
local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
local Replicated = ByteNetModule:WaitForChild("replicated")
local Values = require(Replicated.values)

local packetID = 0
local success, boogaData = pcall(function() 
    return Values.access("booga"):read()
end)

if success and boogaData and boogaData.packets then
    packetID = boogaData.packets.Pickup
    print("Runtime Packet ID for 'Pickup':", packetID)
else
    packetID = 213 -- Fallback (only valid for current session if not restarted)
    warn("Could not read runtime ID, using fallback:", packetID)
end

-- 2. Find Nearest Object
local function getNearestObject()
    local character = Players.LocalPlayer.Character
    if not character or not character.PrimaryPart then return nil end
    
    local rootPart = character.PrimaryPart
    local nearestDist = math.huge
    local nearestObj = nil
    
    -- Scan workspace.Items for objects with EntityID attribute
    local itemsFolder = workspace:FindFirstChild("Items")
    if not itemsFolder then
        warn("workspace.Items folder not found!")
        return nil, nil
    end

    for _, v in ipairs(itemsFolder:GetChildren()) do
        if v:IsA("BasePart") or v:IsA("Model") then
            -- Check for EntityID attribute (used by game logic)
            local entityID = v:GetAttribute("EntityID")
            if entityID then
                local pos = v:IsA("BasePart") and v.Position or (v.PrimaryPart and v.PrimaryPart.Position)
                if pos then
                    local dist = (rootPart.Position - pos).Magnitude
                    if dist < nearestDist then
                        nearestDist = dist
                        nearestObj = v
                    end
                end
            end
        end
    end
    
    return nearestObj, nearestDist
end

-- 3. Run Logic
local obj, dist = getNearestObject()

if obj then
    local entityID = obj:GetAttribute("EntityID")
    print("--------------------------------------------------")
    print("Found Nearest Object: " .. obj:GetFullName())
    print("Distance: " .. string.format("%.2f", dist))
    print("EntityID: " .. entityID)
    
    -- Encode EntityID (uint32 Little Endian)
    -- Example: 160569 -> 0x00027339 -> \57\115\2\0
    local b1 = bit32.band(entityID, 0xFF)
    local b2 = bit32.band(bit32.rshift(entityID, 8), 0xFF)
    local b3 = bit32.band(bit32.rshift(entityID, 16), 0xFF)
    local b4 = bit32.band(bit32.rshift(entityID, 24), 0xFF)
    
    -- Construct Payload String: \Namespace \PacketID \Data
    -- Namespace is 0 (usually)
    local payload = string.char(0) .. string.char(packetID) .. string.char(b1, b2, b3, b4)
    
    print("--------------------------------------------------")
    print("GENERATED PAYLOAD:")
    -- Print in readable escape format for user
    local readable = ""
    for i = 1, #payload do
        local b = string.byte(payload, i, i)
        readable = readable .. "\\" .. b
    end
    print(readable)
    print("--------------------------------------------------")
    
    -- Optional: Fire the remote if you want to test it
    -- local remote = ReplicatedStorage.Events.ByteNet -- Verify remote name!
    -- remote:FireServer(payload)
    -- print("Payload fired!")
else
    print("No objects with 'EntityID' found nearby.")
end
