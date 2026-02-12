-- Voodoo Remote (Keybind: F1, Terminate: F2)
-- Uses Direct Buffer firing for maximum compatibility.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)

-- Configuration
local FIRE_KEY = Enum.KeyCode.F1
local TERM_KEY = Enum.KeyCode.F2

local function notify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 3
    })
end

local function fireVoodoo(targetPos)
    if not ByteNetRemote then return end
    
    -- Create 14-byte buffer: [0][10][f32][f32][f32]
    local b = buffer.create(14)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, 10)  -- Packet ID 10
    buffer.writef32(b, 2, targetPos.X)
    buffer.writef32(b, 6, targetPos.Y)
    buffer.writef32(b, 10, targetPos.Z)
    
    -- Fire the buffer object DIRECTLY
    ByteNetRemote:FireServer(b)
end

local connection
connection = UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == FIRE_KEY then
        local pos = Mouse.Hit and Mouse.Hit.Position
        if pos then
            fireVoodoo(pos)
            print("Voodoo: Fired at " .. tostring(pos))
        end
    elseif input.KeyCode == TERM_KEY then
        if connection then connection:Disconnect() end
        notify("Voodoo Remote", "Terminated.")
    end
end)

notify("Voodoo Remote", "Loaded! F1: Cast | F2: End")
