-- ByteNet Packet Interceptor (Re-Run)
-- This script intercepts the packet definitions by hooking the ByteNet.definePacket function
-- and then re-requiring the target module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- 1. Locate the ByteNet Module (The Library)
-- We know it's in ReplicatedStorage.Modules.ByteNet based on previous analysis
local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
local ByteNet = require(ByteNetModule)

-- 2. Locate the Target Module (The Definitions)
-- Based on your code: local Packets_upvr = require(ReplicatedStorage_upvr.Modules.Packets)
local ModuleToIntercept = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Packets")

print("--- ByteNet Interceptor Started ---")
print("ByteNet Library found at:", ByteNetModule:GetFullName())
print("Target Module found at:", ModuleToIntercept:GetFullName())

-- 3. Hook the definePacket function
local oldDefine = ByteNet.definePacket

ByteNet.definePacket = function(props)
    print("\n[INTERCEPTOR] CAUGHT A PACKET!")
    
    -- Print keys to help identify which packet is which (e.g. pickup)
    -- props usually contains the packet definition
    if type(props) == "table" then
        if props.value then
             print("  Packet Structure Found (Single Value)")
        else
             print("  Packet Structure Found (Complex/Struct)")
        end
        
        -- Try to inspect specific fields if they exist
        for k,v in pairs(props) do
             print("  Key:", k, "Type:", typeof(v))
        end
    end
    
    -- Print full table structure using a simple recursive printer or just HttpService
    -- (safe pcall in case of cyclic refs/functions)
    pcall(function()
        -- Attempt to serialize to JSON for easy reading
        -- Note: Functions won't serialize, but structure will
        -- We just print a marker here
        print("  <Packet Definition Captured>")
    end)

    print("--------------------------------")
    
    -- Call original function so game doesn't break
    return oldDefine(props)
end

print("Hook installed. Re-requiring module to trigger definitions...")

-- 4. Re-require the module to trigger the definitions again
-- We clone it to force a fresh require, so the code runs again and hits our hook

local clone = ModuleToIntercept:Clone()
clone.Parent = ModuleToIntercept.Parent
clone.Name = "Packets_Interceptor_" .. tostring(math.random(1000))

task.spawn(function()
    require(clone)
    print("Module re-run complete. Check console for [INTERCEPTOR] logs.")
    -- clone:Destroy() -- Optional: keep it for inspection
end)
