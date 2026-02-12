-- Get Packet ID for 'Pickup' (Corrected Path)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- Correct Path: ByteNet > replicated > values
local ByteNetModule = ReplicatedStorage:WaitForChild("Modules", 10):WaitForChild("ByteNet", 10)
local Replicated = ByteNetModule:WaitForChild("replicated", 10)
local Values = require(Replicated.values)

print("--- Reading ByteNet Packet IDs ---")

-- Try 'booga' namespace based on user's packet file ("booga")
local namespaceName = "booga"
local success, boogaData = pcall(function() 
    return Values.access(namespaceName):read()
end)

if not success or not boogaData then
    print("Could not read 'booga' namespace. Trying to list all...")
    -- Values.access might not expose a list, but let's check what we can
    if Values.list then
        for k,v in pairs(Values.list) do
             print("Found Namespace:", k)
        end
    end
else
    print("Accessed Namespace: " .. namespaceName)
    if boogaData.packets then
        for name, id in pairs(boogaData.packets) do
            if name == "Pickup" then
                print("--------------------------------------------------")
                print(string.format("Packet: %s | ID: %d (0x%X)", name, id, id))
                print("--------------------------------------------------")
            end
        end
    else
        print("No 'packets' table found in namespace data.")
    end
end
