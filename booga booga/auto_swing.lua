-- Auto-Swing Script (Toggle: F4, Terminate: F5)
-- Automatically swings tool at the nearest valid target (Resource/Item/Player) of interest.
-- Packet ID: 17 (SwingTool) | Payload: [0x00][0x11][Len_u16][EntityID_u32]...

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Configuration
local ENABLED = false
local PACKET_ID = 17            -- Default SwingTool ID
local RANGE = 15                -- Max range to swing
local SWING_DELAY = 0.05         -- Delay between swings (seconds)
local DEBUG_MODE = true         -- Print debug info to console

-- Locals
local LocalPlayer = Players.LocalPlayer
local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true) or ReplicatedStorage:WaitForChild("ByteNetReliable", 5)

if not ByteNetRemote then
    warn("Auto-Swing: ByteNet Remote not found!")
end

-- UI Notification Helper
local function notify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title;
        Text = text;
        Duration = 3;
    })
    print(title .. ": " .. text)
end

-- Helper: Build Payload (Packet 17 format: Namespace 0, ID 17, Len u16 LE, IDs u32 LE)
local function buildPayload(entityIDs)
    local count = #entityIDs
    
    -- Namespace (0) + PacketID (17) -> 2 bytes
    local payload = string.char(0, PACKET_ID)
    
    -- Length (u16 LE) -> 2 bytes
    local lenLow = bit32.band(count, 0xFF)
    local lenHigh = bit32.band(bit32.rshift(count, 8), 0xFF)
    payload = payload .. string.char(lenLow, lenHigh)
    
    -- Entity IDs (u32 LE) -> 4 bytes each
    for _, id in ipairs(entityIDs) do
        local b1 = bit32.band(id, 0xFF)
        local b2 = bit32.band(bit32.rshift(id, 8), 0xFF)
        local b3 = bit32.band(bit32.rshift(id, 16), 0xFF)
        local b4 = bit32.band(bit32.rshift(id, 24), 0xFF)
        payload = payload .. string.char(b1, b2, b3, b4)
    end
    
    -- Use buffer if available for performance (optional, string works fine)
    if buffer and buffer.fromstring then
        return buffer.fromstring(payload)
    end
    return payload
end

-- Helper: Find ALL valid targets in range (OPTIMIZED)
local function getTargetsInRange()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return {} end
    
    local targets = {}
    local seenIDs = {} -- To avoid hitting the same entity multiple times
    local firstPos = nil
    
    -- Setup Spatial Query Params
    local params = OverlapParams.new()
    -- Only check specific folders to avoid hitting the floor/baseplate/terrain
    local containers = {}
    if workspace:FindFirstChild("Resources") then table.insert(containers, workspace.Resources) end
    
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = containers
    
    -- Query parts in the 10-stud radius
    local parts = workspace:GetPartBoundsInRadius(root.Position, RANGE, params)
    
    for _, part in ipairs(parts) do
        -- Check if the part or its parent has the EntityID
        local eid = part:GetAttribute("EntityID") or (part.Parent and part.Parent:GetAttribute("EntityID"))
        
        if eid and not seenIDs[eid] then
            seenIDs[eid] = true
            table.insert(targets, eid)
            if not firstPos then firstPos = part.Position end
        end
    end
    
    return targets, firstPos
end

-- Connection Holders
local renderConnection
local inputConnection

-- Main Loop
local lastSwing = 0

renderConnection = RunService.Heartbeat:Connect(function()
    if not ENABLED then return end
    
    local now = tick()
    if now - lastSwing < SWING_DELAY then return end
    
    local targetIDs, firstPos = getTargetsInRange()
    if #targetIDs > 0 then
        lastSwing = now
        
        -- Build payload with ALL target IDs
        local payload = buildPayload(targetIDs)
        
        -- Fire Remote
        if ByteNetRemote then
            ByteNetRemote:FireServer(payload)
        end
        
        -- Optional: Face the first target
        if firstPos and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local root = LocalPlayer.Character.HumanoidRootPart
            local lookAtPos = Vector3.new(firstPos.X, root.Position.Y, firstPos.Z)
            root.CFrame = CFrame.new(root.Position, lookAtPos)
        end
        
        if DEBUG_MODE then
            -- print("Swung at " .. #targetIDs .. " targets.")
        end
    end
end)

-- Input Handler
inputConnection = UserInputService.InputBegan:Connect(function(input, gp)
    if not gp then
        if input.KeyCode == Enum.KeyCode.F4 then
            ENABLED = not ENABLED
            notify("Auto-Swing", ENABLED and "Enabled" or "Disabled")
        elseif input.KeyCode == Enum.KeyCode.F5 then
            if renderConnection then renderConnection:Disconnect() end
            if inputConnection then inputConnection:Disconnect() end
            ENABLED = false
            notify("Auto-Swing", "Script Terminated.")
        end
    end
end)

notify("Auto-Swing", "Loaded! F4: Toggle | F5: Terminate")
