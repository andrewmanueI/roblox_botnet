-- List All ByteNet Packet IDs
-- Prints every packet name and its current runtime ID to the console.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
local Replicated = ByteNetModule:WaitForChild("replicated")
local Values = require(Replicated.values)

local success, boogaData = pcall(function() 
    return Values.access("booga"):read()
end)

if success then
    print("--------------------------------------------------")
    print("--- Reading ALL ByteNet Packet IDs ---")
    print("--------------------------------------------------")
    
    if boogaData and boogaData.packets then
        -- Collect into a list for sorting
        local packetList = {}
        for name, id in pairs(boogaData.packets) do
            table.insert(packetList, {Name = name, ID = id})
        end
        
        -- Sort alphabetically by Name
        table.sort(packetList, function(a, b)
            return a.Name < b.Name
        end)
        
        -- Print sorted table
        for _, packet in ipairs(packetList) do
            print(string.format("Packet: %-30s | ID: %d", packet.Name, packet.ID))
        end
        
        print("--------------------------------------------------")
        print("Total Packets Found: " .. #packetList)
        print("--------------------------------------------------")
    else
        warn("Could not find 'packets' table in boogaData")
    end
else
    warn("Failed to read values: " .. tostring(boogaData))
end
