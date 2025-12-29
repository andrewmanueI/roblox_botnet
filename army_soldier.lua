local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
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

local panelGui = nil
local isPanelOpen = false
local followConnection = nil
local followTargetUserId = nil

-- Helper functions must be defined before createPanel
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

local function terminateScript()
    isRunning = false
    sendNotify("Army Script", "Script Terminated")
    for _, conn in ipairs(connections) do
        if conn then conn:Disconnect() end
    end
    if panelGui then 
        panelGui:Destroy()
        panelGui = nil
    end
    isPanelOpen = false
    isCommander = false
    stopFollowing()
end


-- Create Modern Sidebar Panel
local function createPanel()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "ArmyPanel"
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.ResetOnSpawn = false
    
    -- Main Panel Container
    local panel = Instance.new("Frame", screenGui)
    panel.Name = "MainPanel"
    panel.Size = UDim2.new(0, 320, 0, 480)
    panel.Position = UDim2.new(1, 0, 0.5, -240) -- Start off-screen
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    
    local panelCorner = Instance.new("UICorner", panel)
    panelCorner.CornerRadius = UDim.new(0, 12)
    
    local panelStroke = Instance.new("UIStroke", panel)
    panelStroke.Color = Color3.fromRGB(60, 60, 70)
    panelStroke.Thickness = 1
    panelStroke.Transparency = 0.5
    
    -- Header
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 60)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    
    local headerCorner = Instance.new("UICorner", header)
    headerCorner.CornerRadius = UDim.new(0, 12)
    
    local headerTitle = Instance.new("TextLabel", header)
    headerTitle.Size = UDim2.new(1, -20, 0, 24)
    headerTitle.Position = UDim2.new(0, 20, 0, 12)
    headerTitle.BackgroundTransparency = 1
    headerTitle.Text = "ARMY CONTROL"
    headerTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    headerTitle.TextSize = 18
    headerTitle.Font = Enum.Font.GothamBold
    headerTitle.TextXAlignment = Enum.TextXAlignment.Left
    
    local headerSubtitle = Instance.new("TextLabel", header)
    headerSubtitle.Size = UDim2.new(1, -20, 0, 14)
    headerSubtitle.Position = UDim2.new(0, 20, 0, 38)
    headerSubtitle.BackgroundTransparency = 1
    headerSubtitle.Text = "Commander Mode"
    headerSubtitle.TextColor3 = Color3.fromRGB(150, 150, 160)
    headerSubtitle.TextSize = 12
    headerSubtitle.Font = Enum.Font.Gotham
    headerSubtitle.TextXAlignment = Enum.TextXAlignment.Left
    
    -- Commands Container
    local commandsContainer = Instance.new("ScrollingFrame", panel)
    commandsContainer.Size = UDim2.new(1, -20, 1, -80)
    commandsContainer.Position = UDim2.new(0, 10, 0, 70)
    commandsContainer.BackgroundTransparency = 1
    commandsContainer.BorderSizePixel = 0
    commandsContainer.ScrollBarThickness = 4
    commandsContainer.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 110)
    commandsContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
    commandsContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    
    local commandsList = Instance.new("UIListLayout", commandsContainer)
    commandsList.SortOrder = Enum.SortOrder.LayoutOrder
    commandsList.Padding = UDim.new(0, 8)
    
    -- Helper function to create command buttons
    local function createButton(config)
        local button = Instance.new("TextButton", commandsContainer)
        button.Size = UDim2.new(1, 0, 0, 50)
        button.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
        button.BorderSizePixel = 0
        button.AutoButtonColor = false
        button.Text = ""
        
        local buttonCorner = Instance.new("UICorner", button)
        buttonCorner.CornerRadius = UDim.new(0, 8)
        
        local buttonStroke = Instance.new("UIStroke", button)
        buttonStroke.Color = Color3.fromRGB(55, 55, 65)
        buttonStroke.Thickness = 1
        buttonStroke.Transparency = 0.7
        
        -- Icon
        local icon = Instance.new("TextLabel", button)
        icon.Size = UDim2.new(0, 40, 1, 0)
        icon.Position = UDim2.new(0, 10, 0, 0)
        icon.BackgroundTransparency = 1
        icon.Text = config.Icon
        icon.TextColor3 = config.Color or Color3.fromRGB(120, 180, 255)
        icon.TextSize = 20
        icon.Font = Enum.Font.GothamBold
        
        -- Title
        local title = Instance.new("TextLabel", button)
        title.Size = UDim2.new(1, -60, 0, 20)
        title.Position = UDim2.new(0, 50, 0, 10)
        title.BackgroundTransparency = 1
        title.Text = config.Title
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextSize = 14
        title.Font = Enum.Font.GothamBold
        title.TextXAlignment = Enum.TextXAlignment.Left
        
        -- Description
        local desc = Instance.new("TextLabel", button)
        desc.Size = UDim2.new(1, -60, 0, 16)
        desc.Position = UDim2.new(0, 50, 0, 28)
        desc.BackgroundTransparency = 1
        desc.Text = config.Description
        desc.TextColor3 = Color3.fromRGB(150, 150, 160)
        desc.TextSize = 11
        desc.Font = Enum.Font.Gotham
        desc.TextXAlignment = Enum.TextXAlignment.Left
        
        -- Hover effect
        button.MouseEnter:Connect(function()
            TweenService:Create(button, TweenInfo.new(0.2), {
                BackgroundColor3 = Color3.fromRGB(45, 45, 55)
            }):Play()
            TweenService:Create(buttonStroke, TweenInfo.new(0.2), {
                Transparency = 0.3
            }):Play()
        end)
        
        button.MouseLeave:Connect(function()
            TweenService:Create(button, TweenInfo.new(0.2), {
                BackgroundColor3 = Color3.fromRGB(35, 35, 42)
            }):Play()
            TweenService:Create(buttonStroke, TweenInfo.new(0.2), {
                Transparency = 0.7
            }):Play()
        end)
        
        -- Click handler
        button.MouseButton1Click:Connect(config.Callback)
        
        return button
    end
    
    -- Create command buttons
    createButton({
        Title = "Jump",
        Description = "Make all soldiers jump",
        Icon = "↑",
        Color = Color3.fromRGB(100, 200, 255),
        Callback = function()
            sendCommand("jump")
            sendNotify("Command", "Jump executed")
        end
    })
    
    createButton({
        Title = "Goto Mouse",
        Description = "Soldiers walk to clicked location",
        Icon = "🚶",
        Color = Color3.fromRGB(100, 200, 255),
        Callback = function()
            sendNotify("Goto Mode", "Click where you want soldiers to walk")
            
            local clickConnection
            clickConnection = Mouse.Button1Down:Connect(function()
                if Mouse.Hit then
                    local targetPos = Mouse.Hit.Position
                    local gotoCmd = string.format("goto %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                    sendCommand(gotoCmd)
                    sendNotify("Goto", "Soldiers walking to location")
                    clickConnection:Disconnect()
                end
            end)
            
            -- Auto-cancel after 10 seconds
            task.delay(10, function()
                if clickConnection then
                    clickConnection:Disconnect()
                    sendNotify("Goto Mode", "Cancelled")
                end
            end)
        end
    })
    
    createButton({
        Title = "Force Goto",
        Description = "Teleport soldiers to clicked location",
        Icon = "⚡",
        Color = Color3.fromRGB(255, 120, 200),
        Callback = function()
            sendNotify("Force Goto", "Click where to teleport soldiers")
            
            local clickConnection
            clickConnection = Mouse.Button1Down:Connect(function()
                if Mouse.Hit then
                    local targetPos = Mouse.Hit.Position
                    local forceGotoCmd = string.format("bring %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                    sendCommand(forceGotoCmd)
                    sendNotify("Force Goto", "Teleporting soldiers")
                    clickConnection:Disconnect()
                end
            end)
            
            -- Auto-cancel after 10 seconds
            task.delay(10, function()
                if clickConnection then
                    clickConnection:Disconnect()
                    sendNotify("Force Goto", "Cancelled")
                end
            end)
        end
    })
    
    -- Follow button (with toggle state)
    local followButton = createButton({
        Title = "Follow Player",
        Description = "Click a player to follow them",
        Icon = "👤",
        Color = Color3.fromRGB(255, 200, 100),
        Callback = function() end -- Will be set below
    })
    
    -- Store references to button elements for updating
    local followButtonFrame = followButton
    local followButtonTitle = followButton:FindFirstChild("TextLabel", true)
    local followButtonIcon = followButton:FindFirstChildWhichIsA("TextLabel")
    
    -- Function to update follow button appearance
    local function updateFollowButton()
        if followTargetUserId then
            -- Active state - green
            followButtonFrame.BackgroundColor3 = Color3.fromRGB(40, 120, 60)
            if followButtonTitle then
                followButtonTitle.Text = "Stop Following"
            end
            if followButtonIcon then
                followButtonIcon.TextColor3 = Color3.fromRGB(100, 255, 150)
            end
        else
            -- Inactive state - default
            followButtonFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
            if followButtonTitle then
                followButtonTitle.Text = "Follow Player"
            end
            if followButtonIcon then
                followButtonIcon.TextColor3 = Color3.fromRGB(255, 200, 100)
            end
        end
    end
    
    -- Initialize button state based on current followTargetUserId
    updateFollowButton()
    
    -- Set the actual callback
    followButton.MouseButton1Click:Connect(function()
        if followTargetUserId then
            -- Stop following
            sendCommand("stop_follow")
            stopFollowing()
            sendNotify("Command", "Stopped following")
            updateFollowButton()
        else
            -- Start following
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
                            
                            -- Update local state
                            followTargetUserId = player.UserId
                            updateFollowButton()
                            
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
    end)
    
    createButton({
        Title = "Join My Server",
        Description = "Bring soldiers to your server",
        Icon = "🌐",
        Color = Color3.fromRGB(150, 120, 255),
        Callback = function()
            local joinCmd = string.format("join_server %s %s", tostring(game.PlaceId), game.JobId)
            sendCommand(joinCmd)
            sendNotify("Command", "Broadcasting Server Info...")
        end
    })
    
    createButton({
        Title = "Reset Character",
        Description = "Reset all soldier characters",
        Icon = "⟲",
        Color = Color3.fromRGB(255, 150, 100),
        Callback = function()
            sendCommand("reset")
            sendNotify("Command", "Reset executed")
        end
    })
    
    createButton({
        Title = "Reload Script",
        Description = "Reload script for all soldiers",
        Icon = "↻",
        Color = Color3.fromRGB(100, 255, 200),
        Callback = function()
            sendCommand("reload")
            sendNotify("System", "Reloading all soldiers...")
        end
    })
    
    createButton({
        Title = "Rejoin",
        Description = "Rejoin current server",
        Icon = "⇄",
        Color = Color3.fromRGB(255, 100, 150),
        Callback = function()
            sendCommand("rejoin")
            sendNotify("Command", "Rejoin executed")
        end
    })
    
    screenGui.Parent = LocalPlayer.PlayerGui
    
    -- Slide in animation
    TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Position = UDim2.new(1, -340, 0.5, -240)
    }):Play()
    
    return screenGui
end

local followConnection = nil
local followTargetUserId = nil

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
    if wheelGui then wheelGui:Destroy() end
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
        -- Dynamic text for Follow button
        if cmd.Action == "follow" then
            nameLabel.Text = followTargetUserId and "Stop Follow" or "Follow"
        else
            nameLabel.Text = cmd.Name
        end
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
            if cmd.Action == "bring" then
                -- Send commander's position
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                    local pos = LocalPlayer.Character.HumanoidRootPart.Position
                    local bringCmd = string.format("bring %.2f,%.2f,%.2f", pos.X, pos.Y, pos.Z)
                    sendCommand(bringCmd)
                    sendNotify("Command", "Bringing soldiers to you...")
                end
                
            elseif cmd.Action == "follow" then
                -- Toggle follow mode
                if followTargetUserId then
                    -- Stop following
                    sendCommand("stop_follow")
                    stopFollowing()
                    sendNotify("Command", "Stopped following")
                else
                    -- Enter targeting mode
                    sendNotify("Follow Mode", "Click on a player to follow")
                    local highlights = highlightPlayers()
                    
                    -- Wait for click on a player
                    local clickConnection
                    clickConnection = Mouse.Button1Down:Connect(function()
                        local target = Mouse.Target
                        if target then
                            local character = target:FindFirstAncestorOfClass("Model")
                            if character then
                                local player = Players:GetPlayerFromCharacter(character)
                                if player and player ~= LocalPlayer then
                                    -- Found valid target
                                    local followCmd = string.format("follow %d", player.UserId)
                                    sendCommand(followCmd)
                                    sendNotify("Following", player.Name)
                                    
                                    -- Start following locally too
                                    startFollowing(player.UserId)
                                    
                                    clearHighlights(highlights)
                                    clickConnection:Disconnect()
                                    
                                    -- Close wheel on success
                                    isWheelOpen = false
                                    if wheelGui then wheelGui:Destroy() end
                                end
                            end
                        end
                    end)
                    
                    -- Auto-cancel after 10 seconds
                    task.delay(10, function()
                        if clickConnection then
                            clickConnection:Disconnect()
                            clearHighlights(highlights)
                            sendNotify("Follow Mode", "Cancelled")
                        end
                    end)
                end
                
            elseif cmd.Action == "join_commander" then
                local joinCmd = string.format("join_server %s %s", tostring(game.PlaceId), game.JobId)
                sendCommand(joinCmd)
                sendNotify("Command", "Broadcasting Server Info...")
            else
                sendCommand(cmd.Action)
                sendNotify("Command", cmd.Name .. " executed")
            end
            
            -- Close wheel (unless in follow targeting mode)
            if cmd.Action ~= "follow" or followTargetUserId then
                isWheelOpen = false
                screenGui:Destroy()
            end
        end)
    end
    
    screenGui.Parent = LocalPlayer.PlayerGui
    return screenGui
end


-- Panel toggle with slide animation
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    if input.KeyCode == Enum.KeyCode.G then
        if not isPanelOpen then
            isPanelOpen = true
            isCommander = true
            panelGui = createPanel()
        else
            isPanelOpen = false
            if panelGui then
                local panel = panelGui:FindFirstChild("MainPanel")
                if panel then
                    TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
                        Position = UDim2.new(1, 0, 0.5, -240)
                    }):Play()
                    task.wait(0.3)
                end
                panelGui:Destroy()
                panelGui = nil
            end
        end
    elseif input.KeyCode == Enum.KeyCode.F3 then
        terminateScript()
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
                    -- If we are commander, don't execute commands (unless we want to test)
                    if isCommander then
                        -- Optional: Print only
                        -- print("Commander ignored order: " .. action)
                    else
                        sendNotify("New Order", action)
                        
                        -- Execute commands
                        if string.sub(action, 1, 5) == "bring" then
                            local coords = string.split(string.sub(action, 7), ",")
                            if #coords == 3 then
                                local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                                    local hrp = LocalPlayer.Character.HumanoidRootPart
                                    local humanoid = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                                    
                                    -- Unsit if seated
                                    if humanoid and humanoid.SeatPart then
                                        humanoid.Sit = false
                                        task.wait(0.1)
                                    end
                                    
                                    -- Calculate distance for tween speed
                                    local distance = (hrp.Position - targetPos).Magnitude
                                    local tweenSpeed = math.max(distance / 50, 1) -- Adjust speed based on distance
                                    
                                    -- Tween to position
                                    TweenService:Create(
                                        hrp, 
                                        TweenInfo.new(tweenSpeed, Enum.EasingStyle.Linear), 
                                        {CFrame = CFrame.new(targetPos + Vector3.new(math.random(-3, 3), 1, math.random(-3, 3)))}
                                    ):Play()
                                    
                                    sendNotify("Moving", "Traveling to Commander...")
                                end
                            end
                            
                        elseif string.sub(action, 1, 4) == "goto" then
                            if not isCommander then
                                local coords = string.split(string.sub(action, 6), ",")
                                if #coords == 3 then
                                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                        local humanoid = LocalPlayer.Character.Humanoid
                                        
                                        -- Unsit if seated
                                        if humanoid.SeatPart then
                                            humanoid.Sit = false
                                            task.wait(0.1)
                                        end
                                        
                                        -- Walk to position
                                        humanoid:MoveTo(targetPos)
                                        sendNotify("Walking", "Moving to location...")
                                    end
                                end
                            end
                            
                        elseif action == "jump" then
                            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                LocalPlayer.Character.Humanoid.Jump = true
                            end
                            
                        elseif string.sub(action, 1, 11) == "join_server" then
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
                            
                        elseif action == "reset" then
                            if LocalPlayer.Character then
                                LocalPlayer.Character:BreakJoints()
                            end
                            
                        elseif string.sub(action, 1, 6) == "follow" then
                            local userId = tonumber(string.sub(action, 8))
                            if userId then
                                startFollowing(userId)
                                local targetPlayer = Players:GetPlayerByUserId(userId)
                                if targetPlayer then
                                    sendNotify("Following", targetPlayer.Name)
                                end
                            end
                            
                        elseif action == "stop_follow" then
                            stopFollowing()
                            sendNotify("Status", "Stopped following")
                            
                        elseif action == "reload" then
                            sendNotify("System", "Reloading Script...")
                            terminateScript()
                            task.spawn(function()
                                -- Add timestamp to bypass GitHub CDN cache
                                local reloadUrl = RELOAD_URL .. "?t=" .. os.time()
                                loadstring(game:HttpGet(reloadUrl))()
                            end)
                            
                        elseif action == "rejoin" then
                            game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                        end
                end
            end
            end
        end
    end
end)

sendNotify("Army Script", "Press G to toggle Panel | F3 to Exit")
print("Army Soldier loaded - Press G for panel")
