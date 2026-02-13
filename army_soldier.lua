local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Forward declarations
local highlightPlayers, clearHighlights, startFollowing, stopFollowing, startFollowingPosition, stopFollowingPosition, sendCommand, stopGotoWalk
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local SERVER_URL = "http://157.15.40.37:5555"
local RELOAD_URL = "https://raw.githubusercontent.com/andrewmanueI/roblox_botnet/master/army_soldier.lua"
local POLL_RATE = 0.3
local lastCommandId = 0
local isRunning = true
local isCommander = false
local connections = {}
local clientId = nil
local executedCommands = {} -- Map of commandId -> executed (boolean)
local lastHeartbeat = 0
local HEARTBEAT_INTERVAL = 5 -- seconds
local lastETag = nil
local MIN_POLL_RATE = 0.2
local MAX_POLL_RATE = 2.0
local currentPollRate = POLL_RATE
local consecutiveNoChange = 0

local panelGui = nil
local isPanelOpen = false
local followConnection = nil
local followTargetUserId = nil
local isClicking = false
local followMode = "Normal" -- Normal, Line, Circle, Force
local gotoConnection = nil
local moveTarget = nil
local VirtualUser = game:GetService("VirtualUser")
local gotoDummy = nil
local gotoDummyConnection = nil
local autoJumpEnabled = false
local autoJumpForceCount = 0 -- temporary override while slide/walk movement is active

local function isAutoJumpActive()
    return autoJumpEnabled or (autoJumpForceCount > 0)
end

local function beginForceAutoJump()
    autoJumpForceCount = autoJumpForceCount + 1
end

local function endForceAutoJump()
    autoJumpForceCount = math.max(0, autoJumpForceCount - 1)
end
local gotoWalkToken = 0 -- increments to cancel any active goto walk loop
local debugFollowCommands = false -- When true, commander will also execute server commands.
local pendingMouseClickConnection = nil -- used for click-to-target modes; cancel should close it
local pendingMouseClickCleanup = nil -- optional cleanup for pending click mode (e.g. clear highlights)
local CANCEL_COOLDOWN = 0.35 -- seconds; prevents spamming cancel key
local lastCancelTime = 0

-- Goto/tp-walk tuning
local GOTO_STOP_DISTANCE = 0.5 -- studs; stop when we're closer than this
local GOTO_TPWALK_SPEED = 2 -- base speed scalar for TranslateBy loop
local GOTO_TPWALK_SCALE = 10 -- multiplies (speed * delta) for TranslateBy loop
local GOTO_STUCK_TIME = 0.35 -- seconds before enabling MoveTo fallback
local GOTO_STUCK_EPS = 0.01 -- studs; if we move less than this, consider "stuck"
local WALKTO_REFRESH = 0.2 -- seconds; refresh MoveTo periodically

-- Formation state
local formationMode = "Follow" -- "Follow" or "Goto"
local formationShape = "Line" -- "Line", "Row", or "Circle"
local formationHoloCubes = {} -- Array of holographic cube parts
local formationIndex = nil -- This client's assigned index in formation
local formationActive = false
local formationLeaderId = nil
local formationCenter = nil
local formationOffsets = nil -- Map of userId -> {x, y, z} relative offsets


-- Background autojump loop: runs continuously and checks `autoJumpEnabled`.
-- Mimics IY's `autojump`: cast two short rays forward; if either hits, trigger a jump.
task.spawn(function()
    local rs = RunService.RenderStepped
    while isRunning do
        rs:Wait()

        if isAutoJumpActive() then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and hum.Parent and not hum.SeatPart then
                local root = hum.RootPart or (char and char:FindFirstChild("HumanoidRootPart"))
                if root then
                    local dir = root.CFrame.LookVector * 3
                    local origin1 = root.Position - Vector3.new(0, 1.5, 0)
                    local origin2 = root.Position + Vector3.new(0, 1.5, 0)

                    -- Ignore your own character (hum.Parent) so we don't "hit our leg".
                    local check1 = workspace:FindPartOnRay(Ray.new(origin1, dir), hum.Parent)
                    local check2 = workspace:FindPartOnRay(Ray.new(origin2, dir), hum.Parent)
                    if check1 or check2 then
                        hum.Jump = true
                    end
                end
            end
        end
    end
end)

local function toggleClicking(state)
    isClicking = state
    if isClicking then
        task.spawn(function()
            while isClicking do
                pcall(function()
                    VirtualUser:Button1Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                    task.wait(0.05)
                    VirtualUser:Button1Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                end)
                task.wait(0.05)
            end
        end)
    end
end

local function cancelPendingClick()
    -- Cancels only the "click a spot" pending selection mode.
    local hadPending = (pendingMouseClickConnection ~= nil)

    if pendingMouseClickConnection then
        pendingMouseClickConnection:Disconnect()
        pendingMouseClickConnection = nil
    end

    -- Optional cleanup hook (eg. clear highlights) for the current pending click mode.
    local cleanup = pendingMouseClickCleanup
    pendingMouseClickCleanup = nil
    if cleanup then
        hadPending = true
        pcall(cleanup)
    end

    return hadPending
end

local function setPendingClick(conn, cleanupFn)
    cancelPendingClick()
    pendingMouseClickConnection = conn
    pendingMouseClickCleanup = cleanupFn
end

local function hasActiveOrder()
    -- If true, pressing C should do something meaningful.
    return (pendingMouseClickConnection ~= nil) or (pendingMouseClickCleanup ~= nil) or (followConnection ~= nil) or isClicking or (moveTarget ~= nil)
end

local function cancelCurrentOrder(isFromCommander)
    -- Stop any active movement/follow loops and close any pending click-to-target mode.
    stopGotoWalk()
    stopFollowing()
    toggleClicking(false)

    cancelPendingClick()

    -- Also cancel any in-progress Humanoid MoveTo that might keep walking even after our loops stop.
    local myChar = LocalPlayer.Character
    local myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if myHumanoid and myRoot then
        pcall(function()
            myHumanoid:Move(Vector3.new(0, 0, 0), false)
            myHumanoid:MoveTo(myRoot.Position)
        end)
    end

    -- If commander presses C, broadcast cancel to all soldiers via server command.
    if isFromCommander then
        sendCommand("cancel")
    end
end

-- Helper functions must be defined before createPanel
local function sendNotify(title, text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 3
        })
    end)
end

sendCommand = function(cmd)
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

local function registerClient()
    local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
    if not request then return false end

    local success, response = pcall(function()
        return request({
            Url = SERVER_URL .. "/register",
            Method = "GET"
        })
    end)

    if success and response and response.Body then
        local jsonSuccess, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if jsonSuccess and data.clientId then
            clientId = data.clientId
            sendNotify("System", "Registered as " .. string.sub(clientId, 1, 12) .. "...")
            print("[ARMY] Registered as " .. clientId)
            return true
        end
    end

    return false
end

local function sendHeartbeat()
    if not clientId then return false end

    local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
    if not request then return false end

    local success = pcall(function()
        request({
            Url = SERVER_URL .. "/heartbeat",
            Method = "POST",
            Body = HttpService:JSONEncode({ clientId = clientId }),
            Headers = { ["Content-Type"] = "application/json" }
        })
    end)

    return success
end

local function acknowledgeCommand(commandId, success, errorMsg)
    if not clientId then return false end

    local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
    if not request then return false end

    local payload = HttpService:JSONEncode({
        clientId = clientId,
        commandId = commandId,
        success = success or true,
        error = errorMsg or nil
    })

    local ackSuccess = pcall(function()
        request({
            Url = SERVER_URL .. "/acknowledge",
            Method = "POST",
            Body = payload,
            Headers = { ["Content-Type"] = "application/json" }
        })
    end)

    if ackSuccess then
        executedCommands[commandId] = true
    end

    return ackSuccess
end

highlightPlayers = function()
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

clearHighlights = function(highlights)
    for _, h in ipairs(highlights) do
        if h then h:Destroy() end
    end
end

stopGotoWalk = function()
    gotoWalkToken = gotoWalkToken + 1
    if gotoConnection then
        gotoConnection:Disconnect()
        gotoConnection = nil
    end
    moveTarget = nil
end

-- Centralized movement helpers so actions (tween/slide/walk/formation) reuse the same codepaths.
local activeMoveTween = nil
local activeFollowTween = nil

local function stopMoveTween()
    local t = activeMoveTween
    activeMoveTween = nil
    if t then
        pcall(function() t:Cancel() end)
    end
end

local function stopFollowTween()
    local t = activeFollowTween
    activeFollowTween = nil
    if t then
        pcall(function() t:Cancel() end)
    end
end

local function getMyRig()
    local char = LocalPlayer.Character
    if not char then return nil end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not (humanoid and root) then return nil end
    return char, humanoid, root
end

local function ensureUnseated(humanoid)
    if humanoid and humanoid.SeatPart then
        humanoid.Sit = false
    end
end

local function shouldStopGoto(dist)
    return dist < GOTO_STOP_DISTANCE
end

-- Forward declarations so Movement methods can call these without accidental global lookups.
local startGotoWalk, startGotoWalkMoveTo

local Movement = {}

function Movement.cancelAll(isFromCommander)
    -- Reuse the existing cancel behavior, but also stop any active tween we started.
    stopMoveTween()
    stopFollowTween()
    cancelCurrentOrder(isFromCommander)
end

function Movement.slideTo(targetPos)
    -- "Slide" in this script is the tp-walk TranslateBy loop.
    startGotoWalk(targetPos)
end

function Movement.walkTo(targetPos)
    startGotoWalkMoveTo(targetPos)
end

function Movement.tweenTo(targetPos, opts)
    -- Tween the HRP to a target position; used by "bring/force goto" style commands.
    local _, humanoid, root = getMyRig()
    if not (humanoid and root) then return end

    ensureUnseated(humanoid)

    local distance = (root.Position - targetPos).Magnitude
    local speedDiv = (opts and opts.speedDiv) or 50
    local minTime = (opts and opts.minTime) or 1
    local rand = (opts and opts.randomRadius) or 0
    local yOff = (opts and opts.yOffset) or 0

    local goalPos = targetPos
    if rand and rand > 0 then
        goalPos = goalPos + Vector3.new(math.random(-rand, rand), yOff, math.random(-rand, rand))
    elseif yOff ~= 0 then
        goalPos = goalPos + Vector3.new(0, yOff, 0)
    end

    local tweenTime = math.max(distance / speedDiv, minTime)
    stopMoveTween()
    activeMoveTween = TweenService:Create(root, TweenInfo.new(tweenTime, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(goalPos)
    })
    activeMoveTween:Play()
end

function Movement.moveTo(targetPos)
    local _, humanoid = getMyRig()
    if not humanoid then return end
    ensureUnseated(humanoid)
    pcall(function()
        humanoid:MoveTo(targetPos)
    end)
end

function Movement.followForceStepTo(targetPos, opts)
    local _, humanoid, root = getMyRig()
    if not (humanoid and root) then return end

    ensureUnseated(humanoid)

    local t = (opts and opts.time) or 0.1
    stopFollowTween()
    activeFollowTween = TweenService:Create(root, TweenInfo.new(t, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(targetPos)
    })
    activeFollowTween:Play()

    -- Match previous behavior: kill velocity so we don't drift.
    root.Velocity = Vector3.new(0, 0, 0)
end

startGotoWalk = function(targetPos)
    stopGotoWalk()
    stopFollowing()
    
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid")

    if humanoid.SeatPart then
        humanoid.Sit = false
        task.wait(0.1)
    end

    moveTarget = targetPos

    -- Mirror the proven working logic in `test_walk.lua`: Heartbeat:Wait() + TranslateBy.
    -- This is also more robust than relying on the Heartbeat Connect(dt) arg existing.
    local myToken = gotoWalkToken
    beginForceAutoJump()
    task.spawn(function()
        local didCleanup = false
        local function cleanup()
            if didCleanup then return end
            didCleanup = true
            endForceAutoJump()
        end

        local ok, err = pcall(function()
            local lastPos = nil
            local stuckTime = 0
            while isRunning and myToken == gotoWalkToken do
                local delta = RunService.Heartbeat:Wait()

                local myChar = LocalPlayer.Character
                local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
                local myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")

                if not (myChar and myRoot and myHumanoid) then
                    lastPos = nil
                    stuckTime = 0
                else
                    -- If something seats us mid-walk, unseat so movement can resume.
                    if myHumanoid.SeatPart then
                        myHumanoid.Sit = false
                    end

                    local offset = (targetPos - myRoot.Position)
                    local dist = offset.Magnitude
                    if shouldStopGoto(dist) then
                        stopGotoWalk()
                        break
                    end

                    if dist > 1e-6 then
                        local direction = offset.Unit

                        -- Face the target position while sliding (helps the movement look natural).
                        pcall(function()
                            local lookAt = Vector3.new(targetPos.X, myRoot.Position.Y, targetPos.Z)
                            if (lookAt - myRoot.Position).Magnitude > 1e-3 then
                                myRoot.CFrame = CFrame.new(myRoot.Position, lookAt)
                            end
                        end)

                        -- Primary: tp-walk style TranslateBy
                        local ok2, err2 = pcall(function()
                            myChar:TranslateBy(direction * GOTO_TPWALK_SPEED * delta * GOTO_TPWALK_SCALE + Vector3.new(0, 0.1, 0))
                        end)
                        if not ok2 then
                            warn("[GOTO] TranslateBy error:", err2)
                        end

                        -- Detect "stuck" (position not changing) and fall back to Humanoid MoveTo.
                        if lastPos then
                            local moved = (myRoot.Position - lastPos).Magnitude
                            if moved < GOTO_STUCK_EPS then
                                stuckTime = stuckTime + delta
                            else
                                stuckTime = 0
                            end
                        end
                        lastPos = myRoot.Position

                        if stuckTime > GOTO_STUCK_TIME then
                            -- Fallback movement that works in more games/executors.
                            pcall(function()
                                myHumanoid:MoveTo(targetPos)
                                myHumanoid:Move(direction, false)
                            end)
                        end
                    end
                end
            end
        end)

        cleanup()
        if not ok then
            warn("[GOTO] Slide loop error:", err)
        end
    end)
end

startGotoWalkMoveTo = function(targetPos)
    stopGotoWalk()
    stopFollowing()

    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid")

    if humanoid.SeatPart then
        humanoid.Sit = false
        task.wait(0.1)
    end

    moveTarget = targetPos

    -- Classic Roblox walking: keep calling MoveTo until we're close enough.
    local myToken = gotoWalkToken
    beginForceAutoJump()
    task.spawn(function()
        local didCleanup = false
        local function cleanup()
            if didCleanup then return end
            didCleanup = true
            endForceAutoJump()
        end

        local ok, err = pcall(function()
            local lastMoveTo = 0
            while isRunning and myToken == gotoWalkToken do
                RunService.Heartbeat:Wait()

                local myChar = LocalPlayer.Character
                local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
                local myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")
                if myRoot and myHumanoid then
                    local dist = (targetPos - myRoot.Position).Magnitude
                    if shouldStopGoto(dist) then
                        stopGotoWalk()
                        break
                    end

                    -- Some games need MoveTo refreshed periodically.
                    if os.clock() - lastMoveTo > WALKTO_REFRESH then
                        lastMoveTo = os.clock()
                        pcall(function()
                            myHumanoid:MoveTo(targetPos)
                        end)
                    end
                end
            end
        end)

        cleanup()
        if not ok then
            warn("[WALKTO] Walk loop error:", err)
        end
    end)
end

startFollowing = function(userId, mode)
    if followConnection then
        followConnection:Disconnect()
    end
    stopFollowTween()
    
    followTargetUserId = userId
    local followStyle = mode or "Normal"
    
    followConnection = RunService.Heartbeat:Connect(function()
        local targetPlayer = Players:GetPlayerByUserId(userId)
        if targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                local targetHRP = targetPlayer.Character.HumanoidRootPart
                local targetPos = targetHRP.Position
                
                -- Use commander-calculated relative offsets if available
                local myId = clientId or tostring(LocalPlayer.UserId)
                if formationActive and formationMode == "Follow" and formationOffsets and formationOffsets[myId] then
                    local offset = formationOffsets[myId]
                    -- Transform relative offset by leader's CFrame
                    local relPos = targetHRP.CFrame * Vector3.new(offset.x, offset.y, offset.z)
                    targetPos = relPos
                else
                    -- Fallback to old logic if no offsets provided
                    if followStyle == "Line" then
                        local index = (LocalPlayer.UserId % 10) + 1
                        local spacing = 4
                        local offset = targetHRP.CFrame.LookVector * -1 * (index * spacing + 5)
                        targetPos = targetPos + offset
                    elseif followStyle == "Circle" then
                        local angle = math.rad((os.time() * 50 + LocalPlayer.UserId) % 360)
                        local radius = 15
                        local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
                        targetPos = targetPos + offset
                    else
                        targetPos = targetPos + Vector3.new(math.random(-2,2), 0, math.random(-2,2))
                    end
                end
                
                if followStyle == "Force" then
                    Movement.followForceStepTo(targetPos, { time = 0.1 })
                else
                    Movement.moveTo(targetPos)
                end
            end
        end
    end)
end

stopFollowing = function()
    if followConnection then
        followConnection:Disconnect()
        followConnection = nil
    end
    stopFollowTween()
    followTargetUserId = nil
end

local function calculateFormationOffsets(shape, count)
    local offsets = {}
    
    if shape == "Line" then
        -- Column behind leader (3, 6, 9... studs)
        for i = 0, count - 1 do
            table.insert(offsets, Vector3.new(0, 0, (i + 1) * 3))
        end
    elseif shape == "Row" then
        -- Rows of 3 behind leader (Row 1 is 3 studs back)
        local rowSize = 3
        for i = 0, count - 1 do
            local row = math.floor(i / rowSize)
            local col = i % rowSize
            table.insert(offsets, Vector3.new((col - 1) * 3, 0, (row + 1) * 3))
        end
    elseif shape == "Circle" then
        -- Static ring around leader (size dynamic based on count)
        local radius = math.max(10, count * 1.5)
        for i = 0, count - 1 do
            local angle = (i / count) * math.pi * 2
            table.insert(offsets, Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
        end
    end
    
    return offsets
end

local function createHolographicCubes(position, shape, clientCount, baseCFrame)
    -- Clear existing cubes
    for _, cube in ipairs(formationHoloCubes) do
        if cube then cube:Destroy() end
    end
    formationHoloCubes = {}
    
    -- Calculate positions for each client based on shape
    local positions = {}
    
    if baseCFrame then
        -- Follow mode relative offsets
        local offsets = calculateFormationOffsets(shape, clientCount)
        for _, offset in ipairs(offsets) do
            table.insert(positions, (baseCFrame * offset).Position + Vector3.new(0, 3, 0))
        end
    else
        -- Goto mode absolute positions
        if shape == "Line" then
            -- Horizontal line
            for i = 0, clientCount - 1 do
                local offset = (i - math.floor(clientCount / 2)) * 4
                table.insert(positions, position + Vector3.new(offset, 3, 0))
            end
        elseif shape == "Row" then
            -- Rows of 3
            local rowSize = 3
            for i = 0, clientCount - 1 do
                local row = math.floor(i / rowSize)
                local col = i % rowSize
                table.insert(positions, position + Vector3.new((col - 1) * 4, 3, row * 4))
            end
        elseif shape == "Circle" then
            -- Circle formation
            local radius = 15
            for i = 0, clientCount - 1 do
                local angle = (i / clientCount) * math.pi * 2
                table.insert(positions, position + Vector3.new(
                    math.cos(angle) * radius,
                    3,
                    math.sin(angle) * radius
                ))
            end
        end
    end
    
    -- Create a cube for each position
    for _, pos in ipairs(positions) do
        local cube = Instance.new("Part")
        cube.Size = Vector3.new(2, 3, 2)
        cube.Position = pos
        cube.Anchored = true
        cube.CanCollide = false
        cube.CanQuery = false
        cube.Transparency = 0.7
        cube.Color = Color3.fromRGB(0, 255, 255) -- Cyan
        cube.Material = Enum.Material.Neon
        cube.Parent = workspace
        
        table.insert(formationHoloCubes, cube)
    end
    
    return formationHoloCubes
end

local function clearHolographicCubes()
    for _, cube in ipairs(formationHoloCubes) do
        if cube then cube:Destroy() end
    end
    formationHoloCubes = {}
end

local function updateHolographicCubes(position, shape, clientCount, baseCFrame)
    createHolographicCubes(position, shape, clientCount, baseCFrame)
end

local function fireVoodoo(targetPos)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    for i = 1, 3 do
        -- Create 14-byte buffer: [0][10][f32][f32][f32]
        local b = buffer.create(14)
        buffer.writeu8(b, 0, 0)   -- Namespace 0
        buffer.writeu8(b, 1, 10)  -- Packet ID 10
        buffer.writef32(b, 2, targetPos.X)
        buffer.writef32(b, 6, targetPos.Y)
        buffer.writef32(b, 10, targetPos.Z)
        
        -- Fire the buffer object DIRECTLY
        ByteNetRemote:FireServer(b)
        task.wait(0.05) -- Small delay between fires for maximum impact
    end
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
    stopGotoWalk()
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

    -- Top-right gear: switches the panel between "Commands" and "Settings" views.
    local gearBtn = Instance.new("TextButton", header)
    gearBtn.Name = "SettingsGear"
    gearBtn.Size = UDim2.new(0, 28, 0, 28)
    gearBtn.Position = UDim2.new(1, -38, 0, 16)
    gearBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    gearBtn.BorderSizePixel = 0
    gearBtn.AutoButtonColor = false
    gearBtn.Text = "⚙"
    gearBtn.TextColor3 = Color3.fromRGB(210, 210, 220)
    gearBtn.TextSize = 16
    gearBtn.Font = Enum.Font.GothamBold

    local gearCorner = Instance.new("UICorner", gearBtn)
    gearCorner.CornerRadius = UDim.new(0, 8)

    local gearStroke = Instance.new("UIStroke", gearBtn)
    gearStroke.Color = Color3.fromRGB(60, 60, 70)
    gearStroke.Thickness = 1
    gearStroke.Transparency = 0.6
    
    -- Fade transition containers (CanvasGroup fades all descendants cleanly).
    local commandsGroup = Instance.new("CanvasGroup", panel)
    commandsGroup.Name = "CommandsGroup"
    commandsGroup.Size = UDim2.new(1, -20, 1, -80)
    commandsGroup.Position = UDim2.new(0, 10, 0, 70)
    commandsGroup.BackgroundTransparency = 1
    commandsGroup.Visible = true
    commandsGroup.GroupTransparency = 0

    local settingsGroup = Instance.new("CanvasGroup", panel)
    settingsGroup.Name = "SettingsGroup"
    settingsGroup.Size = UDim2.new(1, -20, 1, -80)
    settingsGroup.Position = UDim2.new(0, 10, 0, 70)
    settingsGroup.BackgroundTransparency = 1
    settingsGroup.Visible = false
    settingsGroup.GroupTransparency = 1

    -- Commands Container
    local commandsContainer = Instance.new("ScrollingFrame", commandsGroup)
    commandsContainer.Size = UDim2.new(1, 0, 1, 0)
    commandsContainer.Position = UDim2.new(0, 0, 0, 0)
    commandsContainer.BackgroundTransparency = 1
    commandsContainer.BorderSizePixel = 0
    commandsContainer.ScrollBarThickness = 4
    commandsContainer.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 110)
    commandsContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
    commandsContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    
    local commandsList = Instance.new("UIListLayout", commandsContainer)
    commandsList.SortOrder = Enum.SortOrder.LayoutOrder
    commandsList.Padding = UDim.new(0, 8)

    -- Settings view (fades in/out; contains modern toggle switches).
    local settingsScroll = Instance.new("ScrollingFrame", settingsGroup)
    settingsScroll.Size = UDim2.new(1, 0, 1, 0)
    settingsScroll.Position = UDim2.new(0, 0, 0, 0)
    settingsScroll.BackgroundTransparency = 1
    settingsScroll.BorderSizePixel = 0
    settingsScroll.ScrollBarThickness = 4
    settingsScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 110)
    settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

    local settingsList = Instance.new("UIListLayout", settingsScroll)
    settingsList.SortOrder = Enum.SortOrder.LayoutOrder
    settingsList.Padding = UDim.new(0, 10)

    local function createToggleCard(titleText, descText, getValue, setValue)
        local card = Instance.new("Frame", settingsScroll)
        card.Size = UDim2.new(1, 0, 0, 72)
        card.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
        card.BorderSizePixel = 0

        local cardCorner = Instance.new("UICorner", card)
        cardCorner.CornerRadius = UDim.new(0, 10)

        local cardStroke = Instance.new("UIStroke", card)
        cardStroke.Color = Color3.fromRGB(55, 55, 65)
        cardStroke.Thickness = 1
        cardStroke.Transparency = 0.7

        local title = Instance.new("TextLabel", card)
        title.Size = UDim2.new(1, -90, 0, 20)
        title.Position = UDim2.new(0, 14, 0, 12)
        title.BackgroundTransparency = 1
        title.Text = titleText
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextSize = 14
        title.Font = Enum.Font.GothamBold
        title.TextXAlignment = Enum.TextXAlignment.Left

        local desc = Instance.new("TextLabel", card)
        desc.Size = UDim2.new(1, -90, 0, 16)
        desc.Position = UDim2.new(0, 14, 0, 34)
        desc.BackgroundTransparency = 1
        desc.Text = descText
        desc.TextColor3 = Color3.fromRGB(150, 150, 160)
        desc.TextSize = 11
        desc.Font = Enum.Font.Gotham
        desc.TextXAlignment = Enum.TextXAlignment.Left

        local switch = Instance.new("TextButton", card)
        switch.Name = "Switch"
        switch.Size = UDim2.new(0, 56, 0, 28)
        switch.Position = UDim2.new(1, -70, 0.5, -14)
        switch.BorderSizePixel = 0
        switch.AutoButtonColor = false
        switch.Text = ""

        local switchCorner = Instance.new("UICorner", switch)
        switchCorner.CornerRadius = UDim.new(0, 14)

        local knob = Instance.new("Frame", switch)
        knob.Name = "Knob"
        knob.Size = UDim2.new(0, 22, 0, 22)
        knob.Position = UDim2.new(0, 3, 0, 3)
        knob.BackgroundColor3 = Color3.fromRGB(245, 245, 250)
        knob.BorderSizePixel = 0

        local knobCorner = Instance.new("UICorner", knob)
        knobCorner.CornerRadius = UDim.new(0, 11)

        local function apply(v, instant)
            local onColor = Color3.fromRGB(100, 255, 150)
            local offColor = Color3.fromRGB(65, 65, 75)
            local knobOnPos = UDim2.new(0, 31, 0, 3)
            local knobOffPos = UDim2.new(0, 3, 0, 3)

            if instant then
                switch.BackgroundColor3 = v and onColor or offColor
                knob.Position = v and knobOnPos or knobOffPos
            else
                TweenService:Create(switch, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                    BackgroundColor3 = v and onColor or offColor
                }):Play()
                TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                    Position = v and knobOnPos or knobOffPos
                }):Play()
            end
        end

        apply(getValue(), true)

        switch.MouseButton1Click:Connect(function()
            local newVal = not getValue()
            setValue(newVal)
            apply(newVal, false)
        end)

        local clickLayer = Instance.new("TextButton", card)
        clickLayer.Name = "ClickLayer"
        clickLayer.Size = UDim2.new(1, 0, 1, 0)
        clickLayer.BackgroundTransparency = 1
        clickLayer.Text = ""
        clickLayer.AutoButtonColor = false
        clickLayer.ZIndex = 1
        clickLayer.MouseButton1Click:Connect(function()
            local newVal = not getValue()
            setValue(newVal)
            apply(newVal, false)
        end)

        -- Ensure the switch stays clickable above the click layer.
        switch.ZIndex = 5
        knob.ZIndex = 6
        title.ZIndex = 2
        desc.ZIndex = 2

        return {
            Set = function(v) apply(v, false) end
        }
    end

    local autoJumpToggle = createToggleCard(
        "Auto Jump",
        "Automatically jump over low obstacles while moving.",
        function() return autoJumpEnabled end,
        function(v)
            autoJumpEnabled = v
            sendCommand("set_autojump " .. tostring(autoJumpEnabled))
        end
    )

    local debugToggle = createToggleCard(
        "Debug Follow",
        "Commander also executes server commands (for testing).",
        function() return debugFollowCommands end,
        function(v)
            debugFollowCommands = v
        end
    )

    local isSettingsOpen = false
    local function setSettingsOpen(open)
        if open == isSettingsOpen then return end
        isSettingsOpen = open

        if isSettingsOpen then
            settingsGroup.Visible = true
            headerTitle.Text = "SETTINGS"
            headerSubtitle.Text = "Preferences"

            autoJumpToggle.Set(autoJumpEnabled)
            debugToggle.Set(debugFollowCommands)

            -- Instant transition (no animation).
            settingsGroup.GroupTransparency = 0
            commandsGroup.GroupTransparency = 1
            commandsGroup.Visible = false
        else
            headerTitle.Text = "ARMY CONTROL"
            headerSubtitle.Text = "Commander Mode"

            commandsGroup.Visible = true
            -- Instant transition (no animation).
            commandsGroup.GroupTransparency = 0
            settingsGroup.GroupTransparency = 1
            settingsGroup.Visible = false
        end
    end

    gearBtn.MouseEnter:Connect(function()
        TweenService:Create(gearBtn, TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(45, 45, 55) }):Play()
        TweenService:Create(gearStroke, TweenInfo.new(0.15), { Transparency = 0.3 }):Play()
    end)
    gearBtn.MouseLeave:Connect(function()
        TweenService:Create(gearBtn, TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35, 35, 42) }):Play()
        TweenService:Create(gearStroke, TweenInfo.new(0.15), { Transparency = 0.6 }):Play()
    end)
    gearBtn.MouseButton1Click:Connect(function()
        setSettingsOpen(not isSettingsOpen)
    end)
    
    -- Helper function to create command buttons
    local function createButton(config)
        local button = Instance.new("TextButton", commandsContainer)
        button.Size = UDim2.new(1, 0, 0, 50)
        
        -- Set initial colors and attributes
        local initialColor = config.InitialColor or Color3.fromRGB(35, 35, 42)
        button.BackgroundColor3 = initialColor
        button:SetAttribute("BaseColor", initialColor)
        
        -- Default hover color is slightly lighter grey, can be overridden by attribute later
        button:SetAttribute("HoverColor", Color3.fromRGB(45, 45, 55))
        
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
        title.Size = UDim2.new(1, -70, 0, 20)
        title.Position = UDim2.new(0, 60, 0, 10)
        title.BackgroundTransparency = 1
        title.Text = config.Title
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextSize = 14
        title.Font = Enum.Font.GothamBold
        title.TextXAlignment = Enum.TextXAlignment.Left
        
        -- Description
        local desc = Instance.new("TextLabel", button)
        desc.Size = UDim2.new(1, -70, 0, 16)
        desc.Position = UDim2.new(0, 60, 0, 28)
        desc.BackgroundTransparency = 1
        desc.Text = config.Description
        desc.TextColor3 = Color3.fromRGB(150, 150, 160)
        desc.TextSize = 11
        desc.Font = Enum.Font.Gotham
        desc.TextXAlignment = Enum.TextXAlignment.Left
        
        -- Hover effect with dynamic colors
        button.MouseEnter:Connect(function()
            local hoverColor = button:GetAttribute("HoverColor") or Color3.fromRGB(45, 45, 55)
            TweenService:Create(button, TweenInfo.new(0.2), {
                BackgroundColor3 = hoverColor
            }):Play()
            TweenService:Create(buttonStroke, TweenInfo.new(0.2), {
                Transparency = 0.3
            }):Play()
        end)
        
        button.MouseLeave:Connect(function()
            local baseColor = button:GetAttribute("BaseColor") or Color3.fromRGB(35, 35, 42)
            TweenService:Create(button, TweenInfo.new(0.2), {
                BackgroundColor3 = baseColor
            }):Play()
            TweenService:Create(buttonStroke, TweenInfo.new(0.2), {
                Transparency = 0.7
            }):Play()
        end)
        
        -- Click handler
        button.MouseButton1Click:Connect(config.Callback)
        
        return button
    end
    
    -- Helper function to create drawer with sub-buttons
    local function createDrawer(config)
        -- Container for the whole drawer (The unified "Card")
        local drawerContainer = Instance.new("Frame", commandsContainer)
        drawerContainer.Size = UDim2.new(1, 0, 0, 50) -- Start collapsed
        drawerContainer.BackgroundColor3 = Color3.fromRGB(35, 35, 42) -- Main card color
        drawerContainer.BorderSizePixel = 0
        drawerContainer.ClipsDescendants = true
        
        local drawerCorner = Instance.new("UICorner", drawerContainer)
        drawerCorner.CornerRadius = UDim.new(0, 8)
        
        local drawerStroke = Instance.new("UIStroke", drawerContainer)
        drawerStroke.Color = Color3.fromRGB(55, 55, 65)
        drawerStroke.Thickness = 1
        drawerStroke.Transparency = 0.7
        
        -- Header Button (Transparent interactive layer)
        local headerBtn = Instance.new("TextButton", drawerContainer)
        headerBtn.Size = UDim2.new(1, 0, 0, 50)
        headerBtn.BackgroundTransparency = 1
        headerBtn.Text = ""
        headerBtn.ZIndex = 5
        
        -- Header Icon
        local icon = Instance.new("TextLabel", drawerContainer)
        icon.Size = UDim2.new(0, 40, 0, 50)
        icon.Position = UDim2.new(0, 10, 0, 0)
        icon.BackgroundTransparency = 1
        icon.Text = config.Icon
        icon.TextColor3 = config.Color or Color3.fromRGB(120, 180, 255)
        icon.TextSize = 20
        icon.Font = Enum.Font.GothamBold
        icon.ZIndex = 2
        
        -- Header Title
        local title = Instance.new("TextLabel", drawerContainer)
        title.Size = UDim2.new(1, -70, 0, 20)
        title.Position = UDim2.new(0, 60, 0, 10)
        title.BackgroundTransparency = 1
        title.Text = config.Title
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextSize = 14
        title.Font = Enum.Font.GothamBold
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 2
        
        -- Header Description
        local desc = Instance.new("TextLabel", drawerContainer)
        desc.Size = UDim2.new(1, -70, 0, 16)
        desc.Position = UDim2.new(0, 60, 0, 28)
        desc.BackgroundTransparency = 1
        desc.Text = config.Description
        desc.TextColor3 = Color3.fromRGB(150, 150, 160)
        desc.TextSize = 11
        desc.Font = Enum.Font.Gotham
        desc.TextXAlignment = Enum.TextXAlignment.Left
        desc.ZIndex = 2
        
        -- Chevron Icon
        local chevron = Instance.new("TextLabel", drawerContainer)
        chevron.Size = UDim2.new(0, 20, 0, 20)
        chevron.Position = UDim2.new(1, -30, 0, 15)
        chevron.BackgroundTransparency = 1
        chevron.Text = "▼"
        chevron.TextColor3 = Color3.fromRGB(150, 150, 160)
        chevron.TextSize = 14
        chevron.ZIndex = 2
        
        -- Content Background (Inner dark area)
        local contentBackground = Instance.new("Frame", drawerContainer)
        contentBackground.Size = UDim2.new(1, 0, 1, -50)
        contentBackground.Position = UDim2.new(0, 0, 0, 50)
        contentBackground.BackgroundColor3 = Color3.fromRGB(25, 25, 30) -- Darker inner drawer
        contentBackground.BorderSizePixel = 0
        contentBackground.ZIndex = 1
        
        -- Content Container (Sub-buttons)
        local contentContainer = Instance.new("Frame", drawerContainer)
        contentContainer.Name = "Content"
        contentContainer.Size = UDim2.new(1, 0, 0, 0)
        contentContainer.Position = UDim2.new(0, 0, 0, 50)
        contentContainer.BackgroundTransparency = 1
        contentContainer.AutomaticSize = Enum.AutomaticSize.Y
        contentContainer.ZIndex = 2
        
        local contentList = Instance.new("UIListLayout", contentContainer)
        contentList.SortOrder = Enum.SortOrder.LayoutOrder
        contentList.Padding = UDim.new(0, 4)
        contentList.VerticalAlignment = Enum.VerticalAlignment.Top
        
        -- Spacer for top padding inside drawer
        local topSpacer = Instance.new("Frame", contentContainer)
        topSpacer.Size = UDim2.new(1, 0, 0, 4)
        topSpacer.BackgroundTransparency = 1
        topSpacer.LayoutOrder = -1
        
        -- Sub-button creator
        local function createSubButton(subConfig)
            -- Wrapper for formatting
            local wrapper = Instance.new("Frame", contentContainer)
            wrapper.Size = UDim2.new(1, 0, 0, 42)
            wrapper.BackgroundTransparency = 1
            
            local actualBtn = Instance.new("TextButton", wrapper)
            actualBtn.Size = UDim2.new(1, -20, 1, 0)
            actualBtn.Position = UDim2.new(0, 10, 0, 0) -- Centered with 10px margin
            actualBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 50) -- Slightly lighter than drawer bg
            actualBtn.BorderSizePixel = 0
            actualBtn.Text = subConfig.Text
            actualBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
            actualBtn.Font = Enum.Font.GothamSemibold
            actualBtn.TextSize = 13
            actualBtn.AutoButtonColor = true
            actualBtn.ZIndex = 3
            
            local subCorner = Instance.new("UICorner", actualBtn)
            subCorner.CornerRadius = UDim.new(0, 6)
            
            if subConfig.Color then
                actualBtn.TextColor3 = subConfig.Color
            end
            
            actualBtn.MouseButton1Click:Connect(function()
                subConfig.Callback(actualBtn)
            end)
            return actualBtn
        end
        
        -- Toggle Logic
        local isOpen = false
        headerBtn.MouseButton1Click:Connect(function()
            isOpen = not isOpen
            if isOpen then
                -- Expand
                chevron.Text = "▲"
                drawerContainer:TweenSize(UDim2.new(1, 0, 0, 50 + contentList.AbsoluteContentSize.Y + 10), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, 0.3, true)
            else
                -- Collapse
                chevron.Text = "▼"
                drawerContainer:TweenSize(UDim2.new(1, 0, 0, 50), Enum.EasingDirection.In, Enum.EasingStyle.Quart, 0.3, true)
            end
        end)
        
        -- Create sub-buttons from config
        if config.Buttons then
            for _, btnConfig in ipairs(config.Buttons) do
                createSubButton(btnConfig)
            end
        end
        
        return {
            Container = drawerContainer,
            ContentList = contentList,
            SetOpen = function(open)
                isOpen = open
                 if isOpen then
                    chevron.Text = "▲"
                    drawerContainer.Size = UDim2.new(1, 0, 0, 50 + contentList.AbsoluteContentSize.Y + 10)
                else
                    chevron.Text = "▼"
                    drawerContainer.Size = UDim2.new(1, 0, 0, 50)
                end
            end
        }
    end
    
    -- Create command buttons
    -- Movement Drawer
    local movementDrawer = createDrawer({
        Title = "Movement",
        Description = "Control army movement",
        Icon = "🏃",
        Color = Color3.fromRGB(100, 200, 255),
        Buttons = {
            {
                Text = "Jump",
                Color = Color3.fromRGB(100, 220, 255),
                Callback = function()
                    sendCommand("jump")
                    sendNotify("Command", "Jump executed")
                end
            },
            {
                Text = "Goto Mouse (Slide)",
                Color = Color3.fromRGB(100, 200, 255),
                Callback = function()
                    sendNotify("Slide Mode", "Click where you want soldiers to slide")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local targetPos = Mouse.Hit.Position + Vector3.new(0, 3, 0)
                            local gotoCmd = string.format("goto %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                            sendCommand(gotoCmd)
                            sendNotify("Slide", "Soldiers sliding to location")
                            cancelPendingClick()
                        end
                    end), nil)

                    -- Timeout removed per user request
                end
            },
            {
                Text = "Goto Mouse (Walk)",
                Color = Color3.fromRGB(150, 255, 150),
                Callback = function()
                    sendNotify("Walk Mode", "Click where you want soldiers to walk (MoveTo)")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local targetPos = Mouse.Hit.Position + Vector3.new(0, 3, 0)
                            local walkCmd = string.format("walkto %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                            sendCommand(walkCmd)
                            sendNotify("WalkTo", "Soldiers walking to location")
                            cancelPendingClick()
                        end
                    end), nil)
                end
            },
            {
                Text = "Force Goto (Teleport)",
                Color = Color3.fromRGB(255, 120, 200),
                Callback = function()
                    sendNotify("Force Goto", "Click where to teleport soldiers")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local targetPos = Mouse.Hit.Position
                            local forceGotoCmd = string.format("bring %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                            sendCommand(forceGotoCmd)
                            sendNotify("Force Goto", "Teleporting soldiers")
                            cancelPendingClick()
                        end
                    end), nil)
                    
                    -- Timeout removed per user request
                end
            }
        }
    })
    

    
    -- Follow Drawer
    local followDrawer = createDrawer({
        Title = "Follow",
        Description = "Manage following behavior",
        Icon = "👤",
        Color = Color3.fromRGB(255, 200, 100),
        Buttons = {
             {
                Text = "Mode: Normal",
                Color = Color3.fromRGB(100, 200, 255),
                Callback = function(btn)
                    if followMode == "Normal" then
                        followMode = "Line"
                    elseif followMode == "Line" then
                        followMode = "Circle"
                    elseif followMode == "Circle" then
                        followMode = "Force"
                    else
                        followMode = "Normal"
                    end
                    btn.Text = "Mode: " .. followMode
                    sendNotify("Follow Mode", "Switched to " .. followMode)
                end
            },
            {
                Text = "Follow Player",
                Color = Color3.fromRGB(150, 255, 150),
                Callback = function()
                    sendNotify("Follow Mode", "Click on a player to follow")
                    local highlights = highlightPlayers()

                    setPendingClick(Mouse.Button1Down:Connect(function()
                        local target = Mouse.Target
                        if target then
                            local character = target:FindFirstAncestorOfClass("Model")
                            if character then
                                local player = Players:GetPlayerFromCharacter(character)
                                if player and player ~= LocalPlayer then
                                    local modeCmd = followMode or "Normal"
                                    local fullCmd = string.format("follow %d %s", player.UserId, modeCmd)
                                    sendCommand(fullCmd)

                                    sendNotify("Following", player.Name .. " (" .. modeCmd .. ")")
                                    followTargetUserId = player.UserId
                                    cancelPendingClick()
                                end
                            end
                        end
                    end), function()
                        clearHighlights(highlights)
                    end)

                    -- Timeout removed per user request
                end
            },
            {
                Text = "Stop Following",
                Color = Color3.fromRGB(255, 100, 100),
                Callback = function()
                    if followTargetUserId then
                        sendCommand("stop_follow")
                        stopFollowing()
                        sendNotify("Command", "Stopped following")
                    else
                         sendNotify("Info", "Not currently following anyone")
                    end
                end
            }
        }
    })
    
    -- Accounts Drawer (Server Actions + System)
    local serverDrawer = createDrawer({
        Title = "Accounts",
        Description = "Server and script controls",
        Icon = "🌐",
        Color = Color3.fromRGB(150, 120, 255),
        Buttons = {
            {
                Text = "Join My Server",
                Color = Color3.fromRGB(150, 120, 255),
                Callback = function()
                    local joinCmd = string.format("join_server %s %s", tostring(game.PlaceId), game.JobId)
                    sendCommand(joinCmd)
                    sendNotify("Command", "Broadcasting Server Info...")
                end
            },
            {
                Text = "Rejoin Server",
                Color = Color3.fromRGB(255, 100, 150),
                Callback = function()
                    sendCommand("rejoin")
                    sendNotify("Command", "Rejoin executed")
                end
            },
            {
                Text = "Reset Character",
                Color = Color3.fromRGB(255, 150, 100),
                Callback = function()
                    sendCommand("reset")
                    sendNotify("Command", "Reset executed")
                end
            },
            {
                Text = "Reload Script",
                Color = Color3.fromRGB(100, 255, 200),
                Callback = function()
                    sendCommand("reload")
                    sendNotify("System", "Reloading all soldiers...")
                end
            }
        }
    })
    
    -- System Drawer
    local systemDrawer = createDrawer({
        Title = "System",
        Description = "Script and character management",
        Icon = "⚙️",
        Color = Color3.fromRGB(200, 200, 210),
        Buttons = {
            {
                Text = "Reset Character",
                Color = Color3.fromRGB(255, 150, 100),
                Callback = function()
                    sendCommand("reset")
                    sendNotify("Command", "Reset executed")
                end
            },
            {
                Text = "Reload Script",
                Color = Color3.fromRGB(100, 255, 200),
                Callback = function()
                    sendCommand("reload")
                    sendNotify("System", "Reloading all soldiers...")
                end
            }
        }
    })

    -- Settings moved to top-right gear menu.

    -- Formation Drawer
    local formationDrawer = createDrawer({
        Title = "Formation",
        Description = "Organize soldiers in formations",
        Icon = "📐",
        Color = Color3.fromRGB(255, 150, 255),
        Buttons = {
            {
                Text = "Shape: " .. formationShape,
                Color = Color3.fromRGB(100, 200, 255),
                Callback = function(btn)
                    if formationShape == "Line" then
                        formationShape = "Row"
                    elseif formationShape == "Row" then
                        formationShape = "Circle"
                    else
                        formationShape = "Line"
                    end
                    btn.Text = "Shape: " .. formationShape
                    sendNotify("Formation", "Shape: " .. formationShape)
                end
            },
            {
                Text = "Follow Formation",
                Color = Color3.fromRGB(100, 255, 150),
                Callback = function()
                    formationMode = "Follow" -- Auto-switch to Follow mode
                    if true then
                        sendNotify("Follow Formation", "Hover over a player to preview, click to form around them")
                        local highlights = highlightPlayers()
                        
                        -- Declare variables in outer scope for shared access
                        local clientCount = 1
                        local clientIds = {}
                        local mouseMoveConn = nil
                        
                        -- Fetch client list for counting
                        task.spawn(function()
                            local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
                            if request then
                                local success, response = pcall(function()
                                    return request({
                                        Url = SERVER_URL .. "/clients",
                                        Method = "GET"
                                    })
                                end)
                                
                                if success and response and response.Body then
                                    local jsonSuccess, data = pcall(function()
                                        return HttpService:JSONDecode(response.Body)
                                    end)
                                    if jsonSuccess and data then
                                        clientCount = #data
                                        for _, client in ipairs(data) do
                                            table.insert(clientIds, client.id)
                                        end
                                    end
                                end
                            end
                        end)
                        
                        -- Hover preview logic
                        mouseMoveConn = RunService.RenderStepped:Connect(function()
                            local target = Mouse.Target
                            if target then
                                local character = target:FindFirstAncestorOfClass("Model")
                                if character then
                                    local player = Players:GetPlayerFromCharacter(character)
                                    if player and player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                                        updateHolographicCubes(nil, formationShape, clientCount, player.Character.HumanoidRootPart.CFrame)
                                        return
                                    end
                                end
                            end
                            clearHolographicCubes()
                        end)
                        
                        setPendingClick(Mouse.Button1Down:Connect(function()
                            local target = Mouse.Target
                            if target then
                                local character = target:FindFirstAncestorOfClass("Model")
                                if character then
                                    local player = Players:GetPlayerFromCharacter(character)
                                    if player and player ~= LocalPlayer then
                                        -- Calculate relative offsets for all clients
                                        local offsets = calculateFormationOffsets(formationShape, clientCount)
                                        local offsetsData = {}
                                        for i, clientId in ipairs(clientIds) do
                                            if offsets[i] then
                                                offsetsData[clientId] = {
                                                    x = offsets[i].X,
                                                    y = offsets[i].Y,
                                                    z = offsets[i].Z
                                                }
                                            end
                                        end
                                        
                                        local offsetsJson = HttpService:JSONEncode(offsetsData)
                                        local formationCmd = string.format("formation_follow %d %s %s", player.UserId, formationShape, offsetsJson)
                                        sendCommand(formationCmd)
                                        
                                        sendNotify("Formation", "Following " .. player.Name .. " with commander-calculated offsets")
                                        
                                        if mouseMoveConn then mouseMoveConn:Disconnect() end
                                        clearHolographicCubes()
                                        cancelPendingClick()
                                    end
                                end
                            end
                        end), function()
                            if mouseMoveConn then mouseMoveConn:Disconnect() end
                            clearHolographicCubes()
                            clearHighlights(highlights)
                        end)
                    end
                end
            },
            {
                Text = "Goto Formation",
                Color = Color3.fromRGB(255, 200, 100),
                Callback = function()
                    formationMode = "Goto" -- Auto-switch to Goto mode
                    if true then
                        sendNotify("Goto Formation", "Fetching client count...")
                        
                        -- Declare variables in outer scope
                        local clientCount = 1
                        local clientIds = {}
                        local mouseMoveConn = nil
                        
                        -- Fetch client count from server
                        task.spawn(function()
                            local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
                            if not request then
                                sendNotify("Error", "HTTP request not available")
                                return
                            end
                            
                            local success, response = pcall(function()
                                return request({
                                    Url = SERVER_URL .. "/clients",
                                    Method = "GET"
                                })
                            end)
                            
                            if success and response and response.Body then
                                local jsonSuccess, data = pcall(function()
                                    return HttpService:JSONDecode(response.Body)
                                end)
                                
                                if jsonSuccess and data then
                                    clientCount = #data
                                    -- Extract client IDs
                                    for _, client in ipairs(data) do
                                        table.insert(clientIds, client.id)
                                    end
                                    sendNotify("Formation", "Showing formation for " .. clientCount .. " clients")
                                end
                            end
                            
                            -- Show holographic formation preview at mouse position
                            mouseMoveConn = RunService.RenderStepped:Connect(function()
                                if Mouse.Hit then
                                    local targetPos = Mouse.Hit.Position
                                    updateHolographicCubes(targetPos, formationShape, clientCount)
                                end
                            end)
                            
                            setPendingClick(Mouse.Button1Down:Connect(function()
                                if Mouse.Hit then
                                    local targetPos = Mouse.Hit.Position + Vector3.new(0, 3, 0)
                                    
                                    -- Calculate all positions on commander side
                                    local positions = {}
                                    
                                    if formationShape == "Line" then
                                        for i = 0, clientCount - 1 do
                                            local offset = (i - math.floor(clientCount / 2)) * 4
                                            table.insert(positions, {
                                                x = targetPos.X + offset,
                                                y = targetPos.Y,
                                                z = targetPos.Z
                                            })
                                        end
                                    elseif formationShape == "Row" then
                                        local rowSize = 3
                                        for i = 0, clientCount - 1 do
                                            local row = math.floor(i / rowSize)
                                            local col = i % rowSize
                                            table.insert(positions, {
                                                x = targetPos.X + (col - 1) * 4,
                                                y = targetPos.Y,
                                                z = targetPos.Z + row * 4
                                            })
                                        end
                                    elseif formationShape == "Circle" then
                                        local radius = 15
                                        for i = 0, clientCount - 1 do
                                            local angle = (i / clientCount) * math.pi * 2
                                            table.insert(positions, {
                                                x = targetPos.X + math.cos(angle) * radius,
                                                y = targetPos.Y,
                                                z = targetPos.Z + math.sin(angle) * radius
                                            })
                                        end
                                    end
                                    
                                    -- Create position mapping for each client
                                    local positionsData = {}
                                    for i, clientId in ipairs(clientIds) do
                                        if positions[i] then
                                            positionsData[clientId] = positions[i]
                                        end
                                    end
                                    
                                    -- Send formation command with pre-calculated positions
                                    local positionsJson = HttpService:JSONEncode(positionsData)
                                    local formationCmd = string.format("formation_goto %.2f,%.2f,%.2f %s %s", 
                                        targetPos.X, targetPos.Y, targetPos.Z, formationShape, positionsJson)
                                    sendCommand(formationCmd)
                                    sendNotify("Formation", "Goto " .. formationShape .. " formation placed")
                                    
                                    if mouseMoveConn then
                                        mouseMoveConn:Disconnect()
                                    end
                                    clearHolographicCubes()
                                    cancelPendingClick()
                                end
                            end), function()
                                -- Cleanup: disconnect mouse move and clear cubes
                                if mouseMoveConn then
                                    mouseMoveConn:Disconnect()
                                end
                                clearHolographicCubes()
                            end)
                        end)
                    end
                end
            },
            {
                Text = "Clear Formation",
                Color = Color3.fromRGB(255, 100, 100),
                Callback = function()
                    sendCommand("formation_clear")
                    clearHolographicCubes()
                    sendNotify("Formation", "Formation cleared")
                end
            }
        }
    })

    -- Booga Booga Drawer
    local boogaDrawer = createDrawer({
        Title = "Booga Booga",
        Description = "Booga Booga special actions",
        Icon = "👺",
        Color = Color3.fromRGB(255, 100, 50),
        Buttons = {
            {
                Text = "Auto Voodoo",
                Color = Color3.fromRGB(200, 100, 255),
                Callback = function()
                    sendNotify("Auto Voodoo", "Click where you want soldiers to fire voodoo")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local targetPos = Mouse.Hit.Position
                            local voodooCmd = string.format("voodoo %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                            sendCommand(voodooCmd)
                            sendNotify("Voodoo", "Soldiers firing voodoo at target")
                            cancelPendingClick()
                        end
                    end), nil)
                end
            }
        }
    })

    -- Re-order drawers to match the desired tab order:
    -- Movement, Follow, Formation, Booga Booga, Accounts
    movementDrawer.Container.LayoutOrder = 1
    followDrawer.Container.LayoutOrder = 2
    formationDrawer.Container.LayoutOrder = 3
    boogaDrawer.Container.LayoutOrder = 4
    serverDrawer.Container.LayoutOrder = 5

    -- "System" is merged into "Accounts" now.
    systemDrawer.Container.Visible = false

    -- Initial State: Hidden
    panel.Position = UDim2.new(1, 0, 0.5, -240)
    screenGui.Parent = LocalPlayer.PlayerGui
    
    return screenGui
end

-- Panel toggle with slide animation
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    if input.KeyCode == Enum.KeyCode.G then
        isCommander = true
        
        if not panelGui then
            panelGui = createPanel()
        end
        
        local panel = panelGui:FindFirstChild("MainPanel")
        if not panel then return end

        if not isPanelOpen then
            -- Open
            isPanelOpen = true
            panelGui.Enabled = true
            TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                Position = UDim2.new(1, -340, 0.5, -240)
            }):Play()
        else
            -- Close
            isPanelOpen = false
            TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
                Position = UDim2.new(1, 0, 0.5, -240)
            }):Play()
            
            task.delay(0.3, function()
                if not isPanelOpen and panelGui then
                    panelGui.Enabled = false
                end
            end)
    end
    elseif input.KeyCode == Enum.KeyCode.C then
        local now = os.clock()
        if now - lastCancelTime < CANCEL_COOLDOWN then
            return
        end

        -- Don't let C be used to spam notifications when nothing is happening.
        if not hasActiveOrder() then
            return
        end

        lastCancelTime = now

        if cancelPendingClick() then
            sendNotify("Command", "Cancelled pending target selection")
        else
            Movement.cancelAll(isCommander)
            sendNotify("Command", "Cancelled current order")
        end
    elseif input.KeyCode == Enum.KeyCode.F3 then
        terminateScript()
    end
end))


-- Register client before polling starts
task.wait(1)
local registered = false
for i = 1, 5 do
    if registerClient() then
        registered = true
        break
    end
    task.wait(1)
end

if not registered then
    sendNotify("Warning", "Failed to register - running without ID")
end

sendNotify("Army Script", "Press G to toggle Panel | F3 to Exit")
print("Army Soldier loaded - Press G for panel")

-- Polling loop (Main Thread)
print("[ARMY] Starting command loop...")
while isRunning do
    -- Send periodic heartbeat
    if clientId and os.time() - lastHeartbeat >= HEARTBEAT_INTERVAL then
        sendHeartbeat()
        lastHeartbeat = os.time()
    end

    -- Enhanced polling with ETag support
    local request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
    local success, response

    if request then
        local headers = {}
        if lastETag then
            headers["If-None-Match"] = lastETag
        end
        success, response = pcall(function()
            return request({
                Url = SERVER_URL .. "/",
                Method = "GET",
                Headers = headers
            })
        end)
    else
        -- Fallback to game:HttpGet
        success, response = pcall(function()
            return { StatusCode = 200, Body = game:HttpGet(SERVER_URL, true) }
        end)
    end

    if success and isRunning and response then
        -- Handle 304 Not Modified
        if response.StatusCode == 304 then
            consecutiveNoChange = consecutiveNoChange + 1
            if consecutiveNoChange > 10 then
                currentPollRate = math.min(MAX_POLL_RATE, currentPollRate + 0.1)
            end
        elseif response.StatusCode == 200 then
            if response.Headers and response.Headers["ETag"] then
                lastETag = response.Headers["ETag"]
            end

            local jsonSuccess, data = pcall(function()
                return HttpService:JSONDecode(response.Body)
            end)

            if jsonSuccess and data and data.id and data.id ~= lastCommandId then
                local commandId = data.id

                if not executedCommands[commandId] then
                    lastCommandId = commandId
                    local action = data.action
                    
                    consecutiveNoChange = 0
                    currentPollRate = MIN_POLL_RATE

                    task.spawn(function()
                        -- By default, the commander does NOT obey server-issued commands.
                        -- Enable `debugFollowCommands` if you want the commander to follow commands too.
                        local shouldExecute = (action ~= "wait") and (not isCommander or debugFollowCommands)
                        if shouldExecute then
                            sendNotify("New Order", action)

                            local execResult, execError = pcall(function()
                                -- If a tp-walk goto loop is running, it will continuously TranslateBy and can
                                -- effectively "override" other movement commands. Cancel it for non-goto actions.
                                if string.sub(action, 1, 4) ~= "goto" then
                                    stopGotoWalk()
                                end
                                if string.sub(action, 1, 5) == "bring" then
                                    stopFollowing()
                                    local coords = string.split(string.sub(action, 7), ",") -- Fixed index
                                    if #coords == 3 then
                                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                        Movement.tweenTo(targetPos, { speedDiv = 50, minTime = 1, randomRadius = 3, yOffset = 1 })
                                    end
                                elseif string.sub(action, 1, 4) == "goto" then
                                    print("[GOTO] Received command:", action)
                                    stopFollowing()
                                    local coords = string.split(string.sub(action, 6), ",") -- Fixed index
                                    print("[GOTO] Coords:", coords[1], coords[2], coords[3])
                                    if #coords == 3 then
                                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                        print("[GOTO] Target pos:", targetPos)
                                        Movement.slideTo(targetPos)
                                    end
                                elseif string.sub(action, 1, 6) == "walkto" then
                                    print("[WALKTO] Received command:", action)
                                    stopFollowing()
                                    local coords = string.split(string.sub(action, 8), ",") -- after "walkto "
                                    print("[WALKTO] Coords:", coords[1], coords[2], coords[3])
                                    if #coords == 3 then
                                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                        print("[WALKTO] Target pos:", targetPos)
                                        Movement.walkTo(targetPos)
                                    end
                                elseif action == "cancel" then
                                    Movement.cancelAll(false)
                                elseif action == "jump" then
                                    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                        LocalPlayer.Character.Humanoid.Jump = true
                                    end
                                elseif string.sub(action, 1, 11) == "join_server" then
                                    local args = string.split(string.sub(action, 13), " ")
                                    if #args == 2 then
                                        game:GetService("TeleportService"):TeleportToPlaceInstance(tonumber(args[1]), args[2], LocalPlayer)
                                    end
                                elseif action == "reset" then
                                    if LocalPlayer.Character then LocalPlayer.Character:BreakJoints() end
                                elseif string.sub(action, 1, 6) == "follow" then
                                    local args = string.split(string.sub(action, 8), " ")
                                    local userId = tonumber(args[1])
                                    if userId then startFollowing(userId, args[2]) end
                                elseif action == "stop_follow" then
                                    stopFollowing()
                                elseif string.sub(action, 1, 15) == "set_autojump " then
                                    local enabledStr = string.sub(action, 16)
                                    autoJumpEnabled = (enabledStr == "true")
                                elseif action == "reload" then
                                    terminateScript()
                                    loadstring(game:HttpGet(RELOAD_URL .. "?t=" .. os.time()))()
                                    return -- Stop this thread
                                elseif string.sub(action, 1, 17) == "formation_follow " then
                                    -- Format: formation_follow <userId> <shape> <offsets_json>
                                    local payload = string.sub(action, 18)
                                    local userIdStr, shapeStr, offsetsJson = string.match(payload, "^(%S+)%s+(%S+)%s+(.+)$")
                                    
                                    if userIdStr and shapeStr and offsetsJson then
                                        formationLeaderId = tonumber(userIdStr)
                                        formationShape = shapeStr
                                        formationMode = "Follow"
                                        formationActive = true
                                        
                                        -- Parse offsets JSON
                                        local success, offsetsData = pcall(function()
                                            return HttpService:JSONDecode(offsetsJson)
                                        end)
                                        
                                        if success and offsetsData then
                                            formationOffsets = offsetsData
                                            print("[FORMATION] Received " .. shapeStr .. " offsets for " .. userIdStr)
                                        else
                                            formationOffsets = nil
                                            warn("[FORMATION] Failed to parse follow offsets")
                                        end
                                        
                                        -- Start following in formation
                                        if formationLeaderId then
                                            startFollowing(formationLeaderId, formationShape)
                                        end
                                        
                                        sendNotify("Formation", "Following " .. (userIdStr or "leader") .. " in " .. formationShape)
                                    end
                                elseif string.sub(action, 1, 7) == "voodoo " then
                                    local coords = string.split(string.sub(action, 8), ",")
                                    if #coords == 3 then
                                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                        fireVoodoo(targetPos)
                                        print("[VOODOO] Fired at " .. tostring(targetPos))
                                    end
                                elseif string.sub(action, 1, 15) == "formation_goto " then
                                    -- Format: formation_goto <x,y,z> <shape> <positions_json>
                                    -- Positions calculated by commander
                                    -- NOTE: This payload is "<coords> <shape> <json>" (3 tokens).
                                    -- Using string.split + a wrong length check would drop the command.
                                    -- Also, JSON may contain spaces, so capture the "rest of string" as JSON.
                                    local payload = string.sub(action, 16)
                                    local coordsStr, shapeStr, positionsJson = string.match(payload, "^(%S+)%s+(%S+)%s+(.+)$")
                                    if coordsStr and shapeStr and positionsJson then
                                        local coords = string.split(coordsStr, ",")
                                        formationShape = shapeStr
                                        formationMode = "Goto"
                                        formationActive = true
                                        
                                        if #coords == 3 then
                                            formationCenter = Vector3.new(
                                                tonumber(coords[1]),
                                                tonumber(coords[2]),
                                                tonumber(coords[3])
                                            )
                                            
                                            -- Parse positions JSON from commander (via server)
                                            if positionsJson then
                                                local success, positionsData = pcall(function()
                                                    return HttpService:JSONDecode(positionsJson)
                                                end)
                                                
                                                if success and positionsData and positionsData[clientId] then
                                                    -- Commander assigned us a specific position
                                                    local myPos = positionsData[clientId]
                                                    local targetPos = Vector3.new(myPos.x, myPos.y, myPos.z)
                                                    
                                                    -- Move to assigned position
                                                    stopFollowing()
                                                    Movement.walkTo(targetPos)
                                                    
                                                    sendNotify("Formation", "Walking to assigned " .. formationShape .. " position")
                                                else
                                                    sendNotify("Formation", "No position assigned by commander")
                                                end
                                            end
                                        end
                                    end
                                elseif action == "formation_clear" then
                                    formationActive = false
                                    formationMode = "Follow"
                                    formationShape = "Line"
                                    formationLeaderId = nil
                                    formationCenter = nil
                                    stopFollowing()
                                    stopGotoWalk()
                                    stopMoveTween()
                                    clearHolographicCubes()
                                    sendNotify("Formation", "Formation cleared")
                                elseif action == "rejoin" then
                                    game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                                end
                            end)
                            if not execResult then
                                warn("[ARMY] Command failed:", action, execError)
                            end
                            acknowledgeCommand(commandId, execResult, execError)
                        else
                            -- Commander is ignoring server orders (or it's a wait/no-op).
                            -- Still ACK so the server doesn't keep replaying the same command forever.
                            acknowledgeCommand(commandId, true, nil)
                        end
                    end)
                end
            end
        end
    end
    task.wait(currentPollRate)
end

sendNotify("Army Script", "Script Terminated")
