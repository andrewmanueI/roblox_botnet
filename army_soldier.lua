local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local SERVER_URL = "http://157.20.32.201:5555"
local RELOAD_URL = "https://raw.githubusercontent.com/andrewmanueI/roblox_botnet/master/army_soldier.lua"
local POLL_RATE = 0.5
local lastCommandId = 0
local isRunning = true
local isCommander = false
local connections = {}

local followConnection = nil
local followTargetUserId = nil

-- Load WindUI
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

-- Follow helper functions
local function highlightPlayers()
    local highlights = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
            local highlight = Instance.new("Highlight")
            highlight.FillColor = Color3.fromRGB(255, 255, 0)
            highlight.OutlineColor = Color3.fromRGB(255, 200, 0)
            highlight.FillTransparency = 0.5
            highlight.OutlineTransparency = 0
            highlight.Parent = player.Character
            table.insert(highlights, highlight)
        end
    end
    return highlights
end

local function clearHighlights(highlights)
    for _, h in ipairs(highlights) do
        if h then h:Destroy() end
    end
end

local function startFollowing(userId)
    if followConnection then
        followConnection:Disconnect()
    end
    
    followTargetUserId = userId
    
    followConnection = RunService.Heartbeat:Connect(function()
        local targetPlayer = Players:GetPlayerByUserId(userId)
        if targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                local targetPos = targetPlayer.Character.HumanoidRootPart.Position
                LocalPlayer.Character.Humanoid:MoveTo(targetPos)
            end
        end
    end)
end

local function stopFollowing()
    if followConnection then
        followConnection:Disconnect()
        followConnection = nil
    end
    followTargetUserId = nil
end

local function sendNotify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 3
    })
end

local function terminateScript()
    isRunning = false
    sendNotify("Army Script", "Script Terminated")
    for _, conn in ipairs(connections) do
        if conn then conn:Disconnect() end
    end
    stopFollowing()
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

-- Create WindUI Window
local Window = WindUI:CreateWindow({
    Title = "Army Commander",
    Icon = "users",
    Folder = "ArmyScript",
    Size = UDim2.fromOffset(550, 450),
    
    OpenButton = {
        Title = "Army Control",
        Enabled = true,
        Draggable = true,
    },
    
    Topbar = {
        Height = 44,
        ButtonsType = "Default",
    },
})

-- Mark as commander when window is opened
isCommander = true

-- Commands Tab
local CommandsTab = Window:Tab({
    Title = "Commands",
    Icon = "command",
})

-- Movement Section
local MovementSection = CommandsTab:Section({
    Title = "Movement",
})

MovementSection:Button({
    Title = "Jump",
    Icon = "arrow-up",
    Callback = function()
        sendCommand("jump")
        sendNotify("Command", "Jump executed")
    end
})

MovementSection:Button({
    Title = "Bring to Me",
    Icon = "move",
    Callback = function()
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local pos = LocalPlayer.Character.HumanoidRootPart.Position
            local bringCmd = string.format("bring %.2f,%.2f,%.2f", pos.X, pos.Y, pos.Z)
            sendCommand(bringCmd)
            sendNotify("Command", "Bringing soldiers to you...")
        end
    end
})

-- Follow Section
local FollowSection = CommandsTab:Section({
    Title = "Follow",
})

FollowSection:Button({
    Title = followTargetUserId and "Stop Following" or "Follow Player",
    Icon = "user-plus",
    Callback = function()
        if followTargetUserId then
            sendCommand("stop_follow")
            stopFollowing()
            sendNotify("Command", "Stopped following")
        else
            sendNotify("Follow Mode", "Click on a player to follow")
            local highlights = highlightPlayers()
            
            local clickConnection
            clickConnection = Mouse.Button1Down:Connect(function()
                local target = Mouse.Target
                if target then
                    local character = target:FindFirstAncestorOfClass("Model")
                    if character then
                        local player = Players:GetPlayerFromCharacter(character)
                        if player and player ~= LocalPlayer then
                            local followCmd = string.format("follow %d", player.UserId)
                            sendCommand(followCmd)
                            sendNotify("Following", player.Name)
                            
                            clearHighlights(highlights)
                            clickConnection:Disconnect()
                        end
                    end
                end
            end)
            
            task.delay(10, function()
                if clickConnection then
                    clickConnection:Disconnect()
                    clearHighlights(highlights)
                    sendNotify("Follow Mode", "Cancelled")
                end
            end)
        end
    end
})

-- Server Section
local ServerSection = CommandsTab:Section({
    Title = "Server",
})

ServerSection:Button({
    Title = "Join My Server",
    Icon = "server",
    Callback = function()
        local joinCmd = string.format("join_server %s %s", tostring(game.PlaceId), game.JobId)
        sendCommand(joinCmd)
        sendNotify("Command", "Broadcasting Server Info...")
    end
})

ServerSection:Button({
    Title = "Rejoin",
    Icon = "refresh-cw",
    Callback = function()
        sendCommand("rejoin")
        sendNotify("Command", "Rejoin executed")
    end
})

-- System Section
local SystemSection = CommandsTab:Section({
    Title = "System",
})

SystemSection:Button({
    Title = "Reset Character",
    Icon = "rotate-ccw",
    Callback = function()
        sendCommand("reset")
        sendNotify("Command", "Reset executed")
    end
})

SystemSection:Button({
    Title = "Reload Script",
    Icon = "download",
    Callback = function()
        sendCommand("reload")
        sendNotify("System", "Reloading all soldiers...")
    end
})

-- Info Tab
local InfoTab = Window:Tab({
    Title = "Info",
    Icon = "info",
})

InfoTab:Section({
    Title = "Controls",
}):Paragraph({
    Title = "How to Use",
    Content = [[
• Press G to toggle the UI
• Click buttons to send commands
• All soldiers will execute commands
• You (commander) are immune to commands
• Reload works for everyone
    ]]
})

InfoTab:Section({
    Title = "Status",
}):Paragraph({
    Title = "Server",
    Content = "Connected to: " .. SERVER_URL
})

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
                    
                    -- Execute commands (check commander status for each, except reload)
                    if string.sub(action, 1, 5) == "bring" then
                        if not isCommander then
                            local coords = string.split(string.sub(action, 7), ",")
                            if #coords == 3 then
                                local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                                    local hrp = LocalPlayer.Character.HumanoidRootPart
                                    local humanoid = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                                    
                                    if humanoid and humanoid.SeatPart then
                                        humanoid.Sit = false
                                        task.wait(0.1)
                                    end
                                    
                                    local distance = (hrp.Position - targetPos).Magnitude
                                    local tweenSpeed = math.max(distance / 50, 1)
                                    
                                    TweenService:Create(
                                        hrp, 
                                        TweenInfo.new(tweenSpeed, Enum.EasingStyle.Linear), 
                                        {CFrame = CFrame.new(targetPos + Vector3.new(math.random(-3, 3), 1, math.random(-3, 3)))}
                                    ):Play()
                                    
                                    sendNotify("Moving", "Traveling to Commander...")
                                end
                            end
                        end
                        
                    elseif action == "jump" then
                        if not isCommander then
                            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                LocalPlayer.Character.Humanoid.Jump = true
                            end
                        end
                        
                    elseif string.sub(action, 1, 11) == "join_server" then
                        if not isCommander then
                            local args = string.split(string.sub(action, 13), " ")
                            if #args == 2 then
                                local targetPlaceId = tonumber(args[1])
                                local targetJobId = args[2]
                                
                                if game.JobId == targetJobId then
                                    sendNotify("Status", "Already in Commander's Server")
                                else
                                    sendNotify("Traveling", "Joining Commander...")
                                    game:GetService("TeleportService"):TeleportToPlaceInstance(targetPlaceId, targetJobId, LocalPlayer)
                                end
                            end
                        end
                        
                    elseif action == "reset" then
                        if not isCommander then
                            if LocalPlayer.Character then
                                LocalPlayer.Character:BreakJoints()
                            end
                        end
                        
                    elseif string.sub(action, 1, 6) == "follow" then
                        if not isCommander then
                            local userId = tonumber(string.sub(action, 8))
                            if userId then
                                startFollowing(userId)
                                local targetPlayer = Players:GetPlayerByUserId(userId)
                                if targetPlayer then
                                    sendNotify("Following", targetPlayer.Name)
                                end
                            end
                        end
                        
                    elseif action == "stop_follow" then
                        if not isCommander then
                            stopFollowing()
                            sendNotify("Status", "Stopped following")
                        end
                        
                    elseif action == "reload" then
                        sendNotify("System", "Reloading Script...")
                        terminateScript()
                        task.spawn(function()
                            local reloadUrl = RELOAD_URL .. "?t=" .. os.time()
                            loadstring(game:HttpGet(reloadUrl))()
                        end)
                        
                    elseif action == "rejoin" then
                        if not isCommander then
                            game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                        end
                    end
                end
            end
        end
    end
end)

sendNotify("Army Script", "Press G to open UI")
print("Army Soldier loaded - Press G for UI")
