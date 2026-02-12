local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- Function to find the nearest player
local function getNearestPlayer()
    local nearest = nil
    local minDist = math.huge
    local char = LocalPlayer.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    
    if not myRoot then return nil end
    
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            local dist = (p.Character.HumanoidRootPart.Position - myRoot.Position).Magnitude
            if dist < minDist then
                minDist = dist
                nearest = p
            end
        end
    end
    return nearest
end

local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

-- Logic from IY / Army Script to handle seats
if humanoid.SeatPart then
    humanoid.Sit = false
    task.wait(0.1)
end

-- Speed setting (1 as requested)
local speed = 2 

print("TP-Walk Inching enabled. Target: Nearest Player. Speed: " .. speed)

-- The loop that mimics IY's tpwalk logic
while true do
    local delta = RunService.Heartbeat:Wait()
    local targetPlr = getNearestPlayer()
    
    if targetPlr and targetPlr.Character and targetPlr.Character:FindFirstChild("HumanoidRootPart") then
        local myChar = LocalPlayer.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        
        if myRoot then
            local targetPos = targetPlr.Character.HumanoidRootPart.Position
            local direction = (targetPos - myRoot.Position).Unit
            
            -- IY tpwalk logic: TranslateBy(direction * speed * delta * 10)
            -- This moves you without triggering default walk physics/animations as much
            myChar:TranslateBy(direction * speed * delta * 10)
        end
    end
end
