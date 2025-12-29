-- [[ ARMY SOLDIER - GTA 5 WHEEL UI ]]
-- Hold G to open command wheel
-- F3 to terminate script

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local SERVER_URL = "http://157.20.32.201:5555"
local POLL_RATE = 0.5
local lastCommandId = 0
local isRunning = true
local connections = {}

-- Command definitions
local COMMANDS = {
    {Name = "Move", Icon = "🚶", Action = "move"},
    {Name = "Jump", Icon = "⬆", Action = "jump"},
    {Name = "Dance", Icon = "💃", Action = "dance"},
    {Name = "Sit", Icon = "🪑", Action = "sit"},
    {Name = "Wave", Icon = "👋", Action = "wave"},
    {Name = "Follow", Icon = "👥", Action = "follow"},
    {Name = "Stop", Icon = "🛑", Action = "stop"},
    {Name = "Rejoin", Icon = "🔄", Action = "rejoin"}
}

local wheelGui = nil
local isWheelOpen = false

local function sendNotify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 3
    })
end

local function sendCommand(cmd)
    task.spawn(function()
        local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
        if request then
            request({
                Url = SERVER_URL,
                Method = "POST",
                Body = cmd,
                Headers = { ["Content-Type"] = "text/plain" }
            })
        else
            pcall(function() game:HttpPost(SERVER_URL, cmd) end)
        end
    end)
end

-- Create GTA 5 Style Wheel
local function createWheel()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "ArmyWheel"
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.ResetOnSpawn = false
    
    -- Background blur/dim
    local dimFrame = Instance.new("Frame", screenGui)
    dimFrame.Size = UDim2.new(1, 0, 1, 0)
    dimFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    dimFrame.BackgroundTransparency = 0.5
    dimFrame.BorderSizePixel = 0
    
    -- Main wheel container
    local wheelFrame = Instance.new("Frame", screenGui)
    wheelFrame.Size = UDim2.new(0, 400, 0, 400)
    wheelFrame.Position = UDim2.new(0.5, -200, 0.5, -200)
    wheelFrame.BackgroundTransparency = 1
    
    -- Center circle (info display)
    local centerCircle = Instance.new("Frame", wheelFrame)
    centerCircle.Size = UDim2.new(0, 180, 0, 180)
    centerCircle.Position = UDim2.new(0.5, -90, 0.5, -90)
    centerCircle.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    centerCircle.BorderSizePixel = 0
    
    local centerCorner = Instance.new("UICorner", centerCircle)
    centerCorner.CornerRadius = UDim.new(1, 0)
    
    local centerStroke = Instance.new("UIStroke", centerCircle)
    centerStroke.Color = Color3.fromRGB(200, 200, 200)
    centerStroke.Thickness = 2
    
    local centerLabel = Instance.new("TextLabel", centerCircle)
    centerLabel.Size = UDim2.new(1, 0, 1, 0)
    centerLabel.BackgroundTransparency = 1
    centerLabel.Text = "Select Command"
    centerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    centerLabel.TextSize = 18
    centerLabel.Font = Enum.Font.GothamBold
    centerLabel.TextWrapped = true
    
    -- Create segments
    local numSegments = #COMMANDS
    local anglePerSegment = 360 / numSegments
    
    for i, cmd in ipairs(COMMANDS) do
        local angle = math.rad((i - 1) * anglePerSegment - 90) -- Start from top
        local radius = 150
        
        -- Segment button
        local segment = Instance.new("TextButton", wheelFrame)
        segment.Size = UDim2.new(0, 80, 0, 80)
        segment.Position = UDim2.new(0.5, math.cos(angle) * radius - 40, 0.5, math.sin(angle) * radius - 40)
        segment.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
        segment.BorderSizePixel = 0
        segment.Text = ""
        segment.AutoButtonColor = false
        
        local segCorner = Instance.new("UICorner", segment)
        segCorner.CornerRadius = UDim.new(0.2, 0)
        
        local segStroke = Instance.new("UIStroke", segment)
        segStroke.Color = Color3.fromRGB(150, 150, 150)
        segStroke.Thickness = 2
        
        -- Icon/Label
        local label = Instance.new("TextLabel", segment)
        label.Size = UDim2.new(1, 0, 0.6, 0)
        label.Position = UDim2.new(0, 0, 0, 0)
        label.BackgroundTransparency = 1
        label.Text = cmd.Icon
        label.TextSize = 32
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        
        local nameLabel = Instance.new("TextLabel", segment)
        nameLabel.Size = UDim2.new(1, 0, 0.4, 0)
        nameLabel.Position = UDim2.new(0, 0, 0.6, 0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = cmd.Name
        nameLabel.TextSize = 12
        nameLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
        nameLabel.Font = Enum.Font.Gotham
        
        -- Hover effect
        segment.MouseEnter:Connect(function()
            segment.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
            centerLabel.Text = cmd.Name
            TweenService:Create(segment, TweenInfo.new(0.1), {Size = UDim2.new(0, 90, 0, 90)}):Play()
        end)
        
        segment.MouseLeave:Connect(function()
            segment.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            TweenService:Create(segment, TweenInfo.new(0.1), {Size = UDim2.new(0, 80, 0, 80)}):Play()
        end)
        
        -- Click handler
        segment.MouseButton1Click:Connect(function()
            if cmd.Action == "move" then
                -- Special case: use mouse position
                local pos = Mouse.Hit.Position
                local moveCmd = string.format("walk %.2f,%.2f,%.2f", pos.X, pos.Y, pos.Z)
                sendCommand(moveCmd)
                sendNotify("Command", "Move order sent")
            else
                sendCommand(cmd.Action)
                sendNotify("Command", cmd.Name .. " executed")
            end
            
            -- Close wheel
            isWheelOpen = false
            screenGui:Destroy()
        end)
    end
    
    screenGui.Parent = LocalPlayer.PlayerGui
    return screenGui
end

-- Wheel toggle
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    if input.KeyCode == Enum.KeyCode.G then
        if not isWheelOpen then
            isWheelOpen = true
            wheelGui = createWheel()
        end
    elseif input.KeyCode == Enum.KeyCode.F3 then
        isRunning = false
        sendNotify("Army Script", "Script Terminated")
        for _, conn in ipairs(connections) do
            if conn then conn:Disconnect() end
        end
        if wheelGui then wheelGui:Destroy() end
    end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.G then
        if isWheelOpen and wheelGui then
            isWheelOpen = false
            wheelGui:Destroy()
            wheelGui = nil
        end
    end
end))

-- Polling loop
task.spawn(function()
    while isRunning do
        task.wait(POLL_RATE)
        
        local success, response = pcall(function()
            return game:HttpGet(SERVER_URL, true)
        end)
        
        if success and isRunning then
            local jsonSuccess, data = pcall(function()
                return HttpService:JSONDecode(response)
            end)
            
            if jsonSuccess and data and data.id and data.id ~= lastCommandId then
                lastCommandId = data.id 
                local action = data.action
                
                if action ~= "wait" then
                    sendNotify("New Order", action)
                    
                    -- Execute commands
                    if string.sub(action, 1, 4) == "walk" then
                        local coords = string.split(string.sub(action, 6), ",")
                        if #coords == 3 then
                            local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                LocalPlayer.Character.Humanoid:MoveTo(targetPos)
                            end
                        end
                    elseif action == "jump" then
                        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                            LocalPlayer.Character.Humanoid.Jump = true
                        end
                    elseif action == "dance" then
                        game:GetService("ReplicatedStorage"):WaitForChild("DefaultChatSystemChatEvents")
                            :WaitForChild("SayMessageRequest"):FireServer("/e dance", "All")
                    elseif action == "sit" then
                        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                            LocalPlayer.Character.Humanoid.Sit = true
                        end
                    elseif action == "wave" then
                        game:GetService("ReplicatedStorage"):WaitForChild("DefaultChatSystemChatEvents")
                            :WaitForChild("SayMessageRequest"):FireServer("/e wave", "All")
                    elseif action == "rejoin" then
                        game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                    end
                end
            end
        end
    end
end)

sendNotify("Army Script", "Hold G for Command Wheel | F3 to Exit")
print("Army Soldier loaded - Hold G for wheel")
