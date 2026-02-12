local player = game:GetService("Players").LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

-- Set target position here
local targetPos = Vector3.new(0, 0, 0) 

-- Logic from IY / Army Script
if humanoid.SeatPart then
    humanoid.Sit = false
    task.wait(0.1)
end

humanoid.WalkToPoint = targetPos
print("Walking to: " .. tostring(targetPos))
