-- Bow Remote Script (Keybind: F1, Terminate: F2)
-- Corrected "God Layout" based on byte-by-byte analysis of manual firing capture.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)

-- Configuration
local FIRE_KEY = Enum.KeyCode.F1
local TERM_KEY = Enum.KeyCode.F2
local PROJECTILE_ID = 701 -- Standard Bow

local function notify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 3
    })
end

local function fireBow(targetPos)
    if not ByteNetRemote then return end
    
    local char = LocalPlayer.Character
    local head = char and char:FindFirstChild("Head")
    if not head then return end
    
    local pos = head.Position
    local guid = HttpService:GenerateGUID(false):upper()
    local timestamp = tick()
    
    -- Create 75-byte buffer (Exact length of capture)
    local b = buffer.create(75)
    
    -- [0-1] Header
    buffer.writeu8(b, 0, 0)         -- Namespace
    buffer.writeu8(b, 1, 179)       -- ID 179
    
    -- [2-5] drawStrength (f32) - Manual code has 00 00 80 3F here
    buffer.writef32(b, 2, 1.0)
    
    -- [6-17] Position (Vec3 - 12 bytes)
    buffer.writef32(b, 6, pos.X)
    buffer.writef32(b, 10, pos.Y)
    buffer.writef32(b, 14, pos.Z)
    
    -- [18-25] timeStamp (f64 - 8 bytes)
    buffer.writef64(b, 18, timestamp)
    
    -- [26-31] Mystery Constant from capture (FE 72 75 63 DA 41)
    buffer.writeu8(b, 26, 0xFE)
    buffer.writeu8(b, 27, 0x72)
    buffer.writeu8(b, 28, 0x75)
    buffer.writeu8(b, 29, 0x63)
    buffer.writeu8(b, 30, 0xDA)
    buffer.writeu8(b, 31, 0x41)
    
    -- [32-33] GUID Length (u16: 36)
    buffer.writeu16(b, 32, 36)
    
    -- [34-69] GUID String
    for i = 1, 36 do
        buffer.writeu8(b, 34 + (i-1), string.byte(guid, i))
    end
    
    -- [70-71] Trailer Length (u16: 36)
    buffer.writeu16(b, 70, 36)
    
    -- [72-73] projectileID (u16: 701)
    buffer.writeu16(b, 72, PROJECTILE_ID)
    
    -- [74] Terminator
    buffer.writeu8(b, 74, 0)
    
    -- FIRE THE BUFFER DIRECTLY
    ByteNetRemote:FireServer(b)
end

local connection
connection = UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == FIRE_KEY then
        if Mouse.Hit then
            fireBow(Mouse.Hit.Position)
            print("Bow: Fired towards " .. tostring(Mouse.Hit.Position))
        end
    elseif input.KeyCode == TERM_KEY then
        if connection then connection:Disconnect() end
        notify("Bow Remote", "Terminated.")
    end
end)

notify("Bow Remote", "Loaded! F1: Fire | F2: End")
