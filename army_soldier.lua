local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")

-- Forward declarations
-- Forward declarations
local highlightPlayers, clearHighlights, startFollowing, stopFollowing, startFollowingPosition, stopFollowingPosition, sendCommand, stopGotoWalk, stopFarming, stopRoute, showRouteManager, startRouteExecution, fetchRoutes, syncSaveRoute, syncDeleteRoute, walkToUntilWithin, startFarmingTarget, startPrepareTool, stopPrepare, getInventoryReport, dropItemByName, Movement, startFarmingList, terminateScript, fireVoodoo, scanAndEquip, fireInventoryStore, robustRequest, fireAction, firePickup, fireInventoryDrop, fireEquip, fireInventoryUse, findEdgePointRaycast
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local SERVER_URL = "http://157.15.40.37:5555"
local WS_URL = "ws://157.15.40.37:5555"
local RELOAD_URL = "https://raw.githubusercontent.com/andrewmanueI/roblox_botnet/master/army_soldier.lua"
local lastCommandId = 0
local isRunning = true
local isCommander = false
local connections = {}
local clientId = nil
local executedCommands = {} -- Map of commandId -> executed (boolean)
local activeWS = nil
local isConnecting = false

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

-- Packet IDs - Populated dynamically at runtime from ByteNet
local PacketIds = {}

-- Initialize all packet IDs dynamically
local function initPacketIds()
    local success, boogaData = pcall(function()
        local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
        local Replicated = ByteNetModule:WaitForChild("replicated")
        local Values = require(Replicated.values)
        return Values.access("booga"):read()
    end)

    if success and boogaData then
        print("[PACKET IDS] Successfully read ByteNet data")
        
        -- Check packets table
        if boogaData.packets then
            print("[PACKET IDS] Found 'packets' table")
            -- Populate table from packets: capture EVERYTHING like list_all_packets.lua does
            for name, id in pairs(boogaData.packets) do
                PacketIds[name] = id
            end
            
            print("[PACKET IDS] Initialized " .. indexCount(PacketIds) .. " packets.")
            
            -- Sort and print all packet IDs
            local sortedPackets = {}
            for name, id in pairs(PacketIds) do
                table.insert(sortedPackets, {Name = name, ID = id})
            end
            table.sort(sortedPackets, function(a, b) return a.Name < b.Name end)
            
            for _, p in ipairs(sortedPackets) do
                 print("  " .. p.Name .. " = " .. p.ID)
            end
        else
            warn("[PACKET IDS] No 'packets' table found in ByteNet data!")
        end
    else
        warn("[PACKET IDS] Failed to read dynamic packet IDs. ByteNet not accessible.")
    end
end

-- Helper to count keys in a dictionary (for debug print above)
function indexCount(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

-- Call initialization immediately
initPacketIds()

-- Projectile Constants (Ported from aim_assist.lua)
local PROJECTILE_VELOCITIES = {
    ["Bow"] = 570,
    ["Crossbow"] = 640,
    ["Cannon"] = 1280,
    ["Ballista"] = 1550
}
local PROJECTILE_OFFSETS = {
    ["Bow"] = 1,
    ["Crossbow"] = 1,
    ["Cannon"] = 0,
    ["Ballista"] = 0
}
local TOF_MULTIPLIERS = {
    ["Bow"] = 1.30, -- Based on 3.86s / 2.71s
    ["Crossbow"] = 1.20, -- Based on 1.95s / 1.49s
    ["Cannon"] = 1.20, -- Based on 1.00s / 0.735s
    ["Ballista"] = 1.30 -- Based on 0.82s / 0.61s
}
local PREDICT_GRAVITY = 196.2

-- Trajectory solver
local function solveTrajectory(origin, target, v, g)
    local vec = target - origin
    local dx = math.sqrt(vec.X^2 + vec.Z^2)
    local dy = vec.Y
    
    local v2 = v * v
    -- Quadratic term: v^4 - g(g*x^2 + 2*y*v^2)
    local term = v2^2 - g * (g * dx^2 + 2 * dy * v2)
    
    if term < 0 then
        return nil -- Out of range
    end
    
    local root = math.sqrt(term)
    -- Calculate lower angle (direct shot)
    local angle = math.atan((v2 - root) / (g * dx))
    
    return angle
end

local function isAutoJumpActive()
    return autoJumpEnabled or (autoJumpForceCount > 0) or (followConnection ~= nil)
end


-- JSON / server data sometimes turns booleans into strings ("false"/"true").
-- In Luau, any non-nil string is truthy, so we must coerce explicitly.
local function coerceBool(v, defaultValue)
    if v == nil then
        return defaultValue == true
    end
    if v == true or v == false then
        return v
    end
    local tv = type(v)
    if tv == "number" then
        return v ~= 0
    end
    if tv == "string" then
        local s = string.lower(v)
        if s == "true" or s == "1" or s == "yes" or s == "on" then
            return true
        end
        if s == "false" or s == "0" or s == "no" or s == "off" or s == "" then
            return false
        end
    end
    return defaultValue == true
end

local function beginForceAutoJump()
    autoJumpForceCount = autoJumpForceCount + 1
end

local function endForceAutoJump()
    autoJumpForceCount = math.max(0, autoJumpForceCount - 1)
end
local gotoWalkToken = 0 -- increments to cancel any active goto walk loop
local debugFollowCommands = false -- When true, commander will also execute server commands.
local observeServerCommands = true -- When true, commander shows a notification when an order is received.
local autoResendIfNotObserved = true -- If true, commander will re-send commands that don't come back from server.
local AUTO_RESEND_TIMEOUT = 1.5 -- seconds to wait for the command to show up via polling before re-sending
local AUTO_RESEND_MAX = 1 -- number of re-sends (in addition to the first send)
local receivedActionAt = {} -- [actionString] = os.clock() timestamp when last observed from server
local pendingMouseClickConnection = nil -- used for click-to-target modes; cancel should close it
local pendingMouseClickCleanup = nil -- optional cleanup for pending click mode (e.g. clear highlights)

-- Server Configuration Sync
local serverConfigs = {
    auto_pickup = false,
    pickup_whitelist = {}
}
local PICKUP_RANGE = 30
local lastConfigSync = 0
local CONFIG_SYNC_INTERVAL = 5 -- seconds
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
local formationOffsets = nil -- Map of userId -> {x, y, z} relative offsets
local projectileActive = false
local projectileWeapon = nil
local projectileTarget = nil -- Player object to track (like aim_assist.lua)
local projectileLaunchOffset = 1.5 -- Vertical offset (studs) to launch from below camera. Adjustable at runtime.
local farmToken = 0
local routeToken = 0
local routePrevAutoJump = nil -- restore user's setting after route ends/cancels
local prepareToken = 0
local isPreparing = false
local isFarming = false
local isRouteRunning = false
local savedRoutes = {} -- Map of name -> {waypoints = {{pos={x,y,z}, autoJump=bool}, ...}}
local infJumpEnabled = true
local infJumpConnection = nil
local infJumpDebounce = false

-- Shortcuts Configuration
local shortcutBindings = {} -- [actionId] = { id, label, callback, bind = {key, ctrl, alt, shift} }
local shortcutOrder = {} -- stable render + match order
local shortcutRows = {} -- [actionId] = { bindLabel, recordBtn }
local isRecordingShortcut = false
local recordingActionId = nil
local recordingConnection = nil


-- Centralized Network Request Helper
local networkRequest = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request

robustRequest = function(options)
    if not networkRequest then return false, nil end
    -- Retries intentionally disabled: one request attempt per call.
    local success, response = pcall(function()
        return networkRequest(options)
    end)

    -- Different executors / request libs return slightly different shapes.
    -- Normalize enough to detect success reliably.
    local statusCode = nil
    if success and response then
        statusCode = tonumber(response.StatusCode)
            or tonumber(response.Status)
            or tonumber(response.statusCode)
            or tonumber(response.status)
    end

    local responseSaysSuccess = (success and response and (response.Success == true or response.success == true))

    if responseSaysSuccess or (success and response and statusCode and statusCode >= 200 and statusCode < 400) then
        return true, response
    end

    return false, response
end


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
                    
                    local function isValidHit(hit)
                        if not hit or not hit.CanCollide then return false end
                        -- Ignore players by name (direct name check, not display name)
                        local model = hit:FindFirstAncestorOfClass("Model")
                        if model and Players:FindFirstChild(model.Name) then
                            return false
                        end
                        return true
                    end
                    
                    if isValidHit(check1) or isValidHit(check2) then
                        hum.Jump = true
                    end
                end
            end
        end
    end
end)

-- Projectile Aiming Loop
task.spawn(function()
    local rs = RunService.RenderStepped
    while isRunning do
        rs:Wait()
        if projectileActive and projectileTarget and projectileWeapon then
            -- EXACT copy of aim_assist.lua aiming logic (lines 145-211)
            -- Track the player's head dynamically
            if projectileTarget.Character and projectileTarget.Character:FindFirstChild("Head") and projectileTarget.Character:FindFirstChild("HumanoidRootPart") then
                local targetHead = projectileTarget.Character.Head
                local targetPos = targetHead.Position
                local currentPos = workspace.CurrentCamera.CFrame.Position
                
                local v = PROJECTILE_VELOCITIES[projectileWeapon] or 580
                
                -- Target Prediction
                -- Calculate Time of Flight (ToF) approx: t = dist / v
                local dist = (targetPos - currentPos).Magnitude
                
                -- Apply Drag Multiplier to ToF
                local tofMult = TOF_MULTIPLIERS[projectileWeapon] or 1
                local tof = (dist / v) * tofMult
                
                -- Refine ToF with one iteration (since moving target changes distance)
                local targetVel = projectileTarget.Character.HumanoidRootPart.AssemblyLinearVelocity
                local futurePosApprox = targetPos + (targetVel * tof)
                local dist2 = (futurePosApprox - currentPos).Magnitude
                local tof2 = (dist2 / v) * tofMult
                
                local predictedPos = targetPos + (targetVel * tof2)
                
                -- Calculate yaw (horizontal look-at)
                -- Apply dynamic offset relative to camera view looking at PREDICTED position
                local rawLookCFrame = CFrame.lookAt(currentPos, predictedPos)
                local offsetAmount = PROJECTILE_OFFSETS[projectileWeapon] or 0
                local offsetVec = -rawLookCFrame.RightVector * offsetAmount
                
                local adjustedTargetPos = predictedPos + offsetVec
                local lookAtPos = Vector3.new(adjustedTargetPos.X, currentPos.Y, adjustedTargetPos.Z)
                
                local baseCFrame = CFrame.lookAt(currentPos, lookAtPos)
                
                -- Calculate pitch (vertical angle) using original distance? 
                -- No, use adjusted distance so the projectile lands at the offset point.
                
                -- Launch Offset: Projectile starts lower than camera (approx 1.5 studs)
                local launchOrigin = currentPos - Vector3.new(0, projectileLaunchOffset, 0)
                
                local v = PROJECTILE_VELOCITIES[projectileWeapon] or 580
                local theta = solveTrajectory(launchOrigin, adjustedTargetPos, v, PREDICT_GRAVITY)
                
                if theta then
                    -- Apply pitch
                    workspace.CurrentCamera.CFrame = baseCFrame * CFrame.Angles(theta, 0, 0)
                else
                    -- If out of range, just look at them directly (0 pitch relative to base)
                    workspace.CurrentCamera.CFrame = CFrame.lookAt(currentPos, targetPos)
                end
            end
        end
    end
end)

-- Auto-Rejoin logic: Rejoin on error or disconnect
GuiService.ErrorMessageChanged:Connect(function()
    print("[ARMY] Error detected, rejoining...")
    TeleportService:Teleport(game.PlaceId, LocalPlayer)
end)


-- Robust WalkSpeed enforcement (16)
local wsConnections = {}
local function setupWalkSpeedEnforcement(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    
    local function enforce()
        if hum.WalkSpeed ~= 16 then
            hum.WalkSpeed = 16
        end
    end
    
    enforce()
    if wsConnections.wsLoop then wsConnections.wsLoop:Disconnect() end
    wsConnections.wsLoop = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(enforce)
end

if LocalPlayer.Character then
    setupWalkSpeedEnforcement(LocalPlayer.Character)
end
table.insert(connections, LocalPlayer.CharacterAdded:Connect(setupWalkSpeedEnforcement))



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
    -- "C" should NOT cancel preparing once it's running (per user request)
    return (pendingMouseClickConnection ~= nil) or (pendingMouseClickCleanup ~= nil) or (followConnection ~= nil) or isClicking or (moveTarget ~= nil) or isFarming or isRouteRunning
end

local function cancelCurrentOrder(isFromCommander)
    -- Stop any active movement/follow loops and close any pending click-to-target mode.
    stopGotoWalk()
    stopFollowing()
    toggleClicking(false)

    cancelPendingClick()
    stopFarming()
    stopRoute()
    -- stopPrepare() is now handled by the "Finish Preparing" button or F3, not "C" while running.

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

local function isModifierKey(keyCode)
    return keyCode == Enum.KeyCode.LeftControl
        or keyCode == Enum.KeyCode.RightControl
        or keyCode == Enum.KeyCode.LeftAlt
        or keyCode == Enum.KeyCode.RightAlt
        or keyCode == Enum.KeyCode.LeftShift
        or keyCode == Enum.KeyCode.RightShift
end

local function getShortcutBindText(bind)
    if not bind or not bind.key then
        return "Unbound"
    end

    local parts = {}
    if bind.ctrl then table.insert(parts, "Ctrl") end
    if bind.alt then table.insert(parts, "Alt") end
    if bind.shift then table.insert(parts, "Shift") end
    table.insert(parts, bind.key.Name)
    return table.concat(parts, " + ")
end

local function makeShortcutActionId(groupName, actionName)
    local raw = string.lower(tostring(groupName or "") .. "_" .. tostring(actionName or ""))
    raw = raw:gsub("[^%w]+", "_")
    raw = raw:gsub("_+", "_")
    raw = raw:gsub("^_", "")
    raw = raw:gsub("_$", "")
    return raw
end

local function parseShortcutLabel(label)
    local normalized = tostring(label or "")
    local groupName, actionName = string.match(normalized, "^(.-)%s*/%s*(.+)$")
    if not groupName or not actionName then
        return "Other", normalized
    end
    return groupName, actionName
end

local function isBindPressed(bind, inputKeyCode)
    if not bind or not bind.key or inputKeyCode ~= bind.key then
        return false
    end

    local ctrlDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
    local altDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
    local shiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

    if (bind.ctrl == true) ~= ctrlDown then return false end
    if (bind.alt == true) ~= altDown then return false end
    if (bind.shift == true) ~= shiftDown then return false end

    return true
end

local function updateShortcutRow(actionId)
    local row = shortcutRows[actionId]
    local entry = shortcutBindings[actionId]
    if not row or not entry then return end

    if row.titleLabel then
        row.titleLabel.Text = entry.actionName or entry.label
    end

    if row.groupLabel then
        row.groupLabel.Text = entry.group or "Other"
    end

    if row.bindLabel then
        row.bindLabel.Text = getShortcutBindText(entry.bind)
    end

    if row.recordBtn then
        if isRecordingShortcut and recordingActionId == actionId then
            row.recordBtn.Text = "Press Combo..."
            row.recordBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
        else
            row.recordBtn.Text = "Bind"
            row.recordBtn.BackgroundColor3 = Color3.fromRGB(60, 95, 170)
        end
    end
end

local function updateAllShortcutRows()
    for actionId, _ in pairs(shortcutRows) do
        updateShortcutRow(actionId)
    end
end

local function applyShortcutBind(actionId, bind)
    local entry = shortcutBindings[actionId]
    if not entry then return end
    entry.bind = bind
    updateShortcutRow(actionId)
end

local function stopShortcutRecording()
    if recordingConnection then
        recordingConnection:Disconnect()
        recordingConnection = nil
    end
    isRecordingShortcut = false
    recordingActionId = nil
    updateAllShortcutRows()
end

local function startShortcutRecording(actionId)
    local entry = shortcutBindings[actionId]
    if not entry then return end

    stopShortcutRecording()
    isRecordingShortcut = true
    recordingActionId = actionId
    updateAllShortcutRows()

    sendNotify("Shortcuts", "Press a combo for " .. entry.label .. " (Esc cancel, Backspace clear)")

    recordingConnection = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

        local keyCode = input.KeyCode
        if keyCode == Enum.KeyCode.Unknown then return end

        if keyCode == Enum.KeyCode.Escape then
            stopShortcutRecording()
            sendNotify("Shortcuts", "Bind cancelled")
            return
        end

        if keyCode == Enum.KeyCode.Backspace then
            applyShortcutBind(actionId, nil)
            stopShortcutRecording()
            sendNotify("Shortcuts", "Bind cleared for " .. entry.label)
            return
        end

        if isModifierKey(keyCode) then
            return
        end

        local bind = {
            key = keyCode,
            ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl),
            alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt),
            shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        }

        applyShortcutBind(actionId, bind)
        stopShortcutRecording()
        sendNotify("Shortcuts", entry.label .. " -> " .. getShortcutBindText(bind))
    end)
end

local function registerShortcutAction(actionId, label, callback)
    local groupName, actionName = parseShortcutLabel(label)
    local existing = shortcutBindings[actionId]
    if existing then
        existing.label = label
        existing.group = groupName
        existing.actionName = actionName
        existing.callback = callback
        return
    end

    shortcutBindings[actionId] = {
        id = actionId,
        label = label,
        group = groupName,
        actionName = actionName,
        callback = callback,
        bind = nil
    }
    table.insert(shortcutOrder, actionId)
end

local function setDefaultShortcutBind(actionId, bind)
    local entry = shortcutBindings[actionId]
    if not entry then return end
    if entry.bind == nil then
        entry.bind = bind
    end
end

local function executeShortcutFromInput(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return false
    end

    if isRecordingShortcut then
        return true
    end

    if UserInputService:GetFocusedTextBox() then
        return false
    end

    for _, actionId in ipairs(shortcutOrder) do
        local entry = shortcutBindings[actionId]
        if entry and entry.callback and entry.bind and isBindPressed(entry.bind, input.KeyCode) then
            local ok, err = pcall(entry.callback)
            if not ok then
                warn("[SHORTCUT] Failed to run action '" .. tostring(entry.label) .. "': " .. tostring(err))
                sendNotify("Shortcuts", "Failed: " .. tostring(entry.label))
            end
            return true
        end
    end

    return false
end

local function recordObservedAction(action)
    if type(action) ~= "string" then return end
    receivedActionAt[action] = os.clock()
end

local function wasActionObservedSince(action, sinceTime)
    local t = receivedActionAt[action]
    return (t ~= nil) and (t >= sinceTime)
end

local function sendCommandOnce(cmd)
    -- One request attempt per call. No retries.
    if networkRequest then
        robustRequest({
            Url = SERVER_URL,
            Method = "POST",
            Body = cmd,
            Headers = { ["Content-Type"] = "text/plain" }
        })
        return
    end

    pcall(function()
        game:HttpPost(SERVER_URL, cmd)
    end)
end

sendCommand = function(cmd)
    local sentAt = os.clock()

    task.spawn(function()
        sendCommandOnce(cmd)
    end)

    -- Optional commander-side resend: only re-send if we never see the same action come back from the server.
    -- Best-effort: relies on the server broadcasting the action string unchanged.
    if isCommander and observeServerCommands and autoResendIfNotObserved then
        task.spawn(function()
            for _ = 1, AUTO_RESEND_MAX do
                task.wait(AUTO_RESEND_TIMEOUT)
                if wasActionObservedSince(cmd, sentAt) then
                    return
                end
                sentAt = os.clock()
                sendCommandOnce(cmd)
            end
        end)
    end
end

local function fetchServerConfigs()
    if not networkRequest then return false end
    
    local success, response = robustRequest({
        Url = SERVER_URL .. "/config",
        Method = "GET"
    })
    
    if success and response and response.Body then
        local jsonSuccess, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)
        
        if jsonSuccess and data then
            serverConfigs.auto_pickup = data.auto_pickup or false
            serverConfigs.pickup_whitelist = data.pickup_whitelist or {}
            return true
        end
    end
    return false
end

local function updateServerConfig(newConfig)
    if not networkRequest then return false end
    
    local success = robustRequest({
        Url = SERVER_URL .. "/config",
        Method = "POST",
        Body = HttpService:JSONEncode(newConfig),
        Headers = { ["Content-Type"] = "application/json" }
    })
    
    if success then
        -- Update local cache immediately
        if newConfig.auto_pickup ~= nil then serverConfigs.auto_pickup = newConfig.auto_pickup end
        if newConfig.pickup_whitelist ~= nil then serverConfigs.pickup_whitelist = newConfig.pickup_whitelist end
    end
    
    return success
end

-- PICKUP LOGIC --

firePickup = function(item)
    if not item then return end
    -- Items can be BaseParts or Models depending on the game.
    local entityID = item:GetAttribute("EntityID")
    if not entityID and item:IsA("Model") then
        local pp = item.PrimaryPart
        entityID = (pp and pp:GetAttribute("EntityID")) or nil
        if not entityID then
            local anyPart = item:FindFirstChildWhichIsA("BasePart", true)
            entityID = anyPart and anyPart:GetAttribute("EntityID") or nil
        end
    end
    if not entityID then return end

    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end

    -- Create 6-byte buffer: [0][packetID][u32(entityID)]
    local b = buffer.create(6)
    buffer.writeu8(b, 0, 0)
    buffer.writeu8(b, 1, PacketIds.Pickup)
    buffer.writeu32(b, 2, entityID)
    
    ByteNetRemote:FireServer(b)
end

local function isItemWhitelisted(name)
    if not serverConfigs.pickup_whitelist or #serverConfigs.pickup_whitelist == 0 then
        return true
    end
    local lowerName = name:lower()
    for _, allowed in ipairs(serverConfigs.pickup_whitelist) do
        if lowerName:find(allowed:lower(), 1, true) then
            return true
        end
    end
    return false
end

task.spawn(function()
    while isRunning do
        if serverConfigs.auto_pickup then
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local itemsFolder = workspace:FindFirstChild("Items")
            
            if root and itemsFolder then
                for _, item in ipairs(itemsFolder:GetChildren()) do
                    if item:GetAttribute("EntityID") then
                        local pos = item:IsA("BasePart") and item.Position or (item:IsA("Model") and item.PrimaryPart and item.PrimaryPart.Position)
                        if pos and (root.Position - pos).Magnitude <= PICKUP_RANGE then
                            if isItemWhitelisted(item.Name) then
                                firePickup(item)
                            end
                        end
                    end
                end
            end
        end
        task.wait(0.5)
    end
end)

-- Periodically sync config from server
task.spawn(function()
    while isRunning do
        if os.clock() - lastConfigSync >= CONFIG_SYNC_INTERVAL then
            fetchServerConfigs()
            lastConfigSync = os.clock()
        end
        task.wait(1)
    end
end)

local function registerClient()
    if not networkRequest then return false end

    local body = HttpService:JSONEncode({
        name = LocalPlayer.Name,
        isCommander = isCommander
    })

    local success, response = robustRequest({
        Url = SERVER_URL .. "/register",
        Method = "POST",
        Body = body,
        Headers = { ["Content-Type"] = "application/json" }
    })

    if success and response and response.Body then
        local jsonSuccess, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if jsonSuccess and data.clientId then
            clientId = data.clientId
            sendNotify("System", "Registered as " .. clientId .. "...")
            print("[ARMY] Registered as " .. clientId)
            return true
        end
    end

    return false
end

local function sendHeartbeat()
    if not clientId then return false end

    local success, response = robustRequest({
        Url = SERVER_URL .. "/heartbeat",
        Method = "POST",
        Body = HttpService:JSONEncode({ clientId = clientId }),
        Headers = { ["Content-Type"] = "application/json" }
    })

    return success, response
end

local function acknowledgeCommand(commandId, success, errorMsg)
    if not clientId then return false end

    -- Normalize success
    local normalizedSuccess = (success == nil) and true or success

    local data = {
        type = "acknowledge",
        clientId = clientId,
        commandId = commandId,
        success = normalizedSuccess,
        error = (normalizedSuccess == false) and (errorMsg or nil) or nil,
        result = (normalizedSuccess ~= false) and (errorMsg or nil) or nil
    }

    if activeWS then
        pcall(function()
            activeWS:Send(HttpService:JSONEncode(data))
        end)
        executedCommands[commandId] = true
        return true
    end

    -- Fallback to HTTP if WS is down
    local payload = HttpService:JSONEncode({
        clientId = clientId,
        commandId = commandId,
        success = normalizedSuccess,
        error = data.error,
        result = data.result
    })

    local ackSuccess = robustRequest({
        Url = SERVER_URL .. "/acknowledge",
        Method = "POST",
        Body = payload,
        Headers = { ["Content-Type"] = "application/json" }
    })

    if ackSuccess then
        executedCommands[commandId] = true
    end

    return ackSuccess
end

local function handleActionData(data)
    if not isRunning or not data or not data.id then return end
    
    local commandId = data.id
    if executedCommands[commandId] then return end
    
    lastCommandId = commandId
    local action = data.action
    recordObservedAction(action)
    
    -- By default, the commander does NOT obey server-issued commands.
    local shouldExecute = (action ~= "wait") and (not isCommander or debugFollowCommands)

    if shouldExecute then
        if not isCommander then sendNotify("New Order", action) end

        local execResult, execError = pcall(function()
            -- If a tp-walk goto loop is running, it will continuously TranslateBy and can
            -- effectively "override" other movement commands. Cancel it for non-goto actions.
            if string.sub(action, 1, 4) ~= "goto" then
                stopGotoWalk()
            end
            
            -- BOOGA BOOGA ACTIONS --
            if string.sub(action, 1, 21) == "inventory_report_all " then
                local query = string.sub(action, 22)
                local reportJson = getInventoryReport(query)
                local reportPayload = reportJson

                pcall(function()
                    reportPayload = HttpService:JSONDecode(reportJson)
                end)

                acknowledgeCommand(commandId, true, reportPayload)
                return true
            elseif string.sub(action, 1, 12) == "farm_target " then
                local coordsStr = string.sub(action, 13)
                local coords = string.split(coordsStr, ",")
                if #coords >= 3 then
                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                    local targetId = tonumber(coords[4]) -- Optional 4th arg
                    startFarmingTarget(targetPos, targetId)
                end
                return true
            elseif string.sub(action, 1, 14) == "execute_route " then
                local json = string.sub(action, 15)
                local success, data = pcall(function()
                    return HttpService:JSONDecode(json)
                end)
                if success and data and data.waypoints then
                    startRouteExecution(data.waypoints)
                end
                return true
            elseif string.sub(action, 1, 18) == "farm_targets_list " then
                local listStr = string.sub(action, 19)
                local ids = {}
                for idStr in string.gmatch(listStr, "([^,]+)") do
                    local id = tonumber(idStr)
                    if id then table.insert(ids, id) end
                end
                if #ids > 0 then
                    print("[FARM] Received list of " .. #ids .. " targets")
                    startFarmingList(ids)
                end
                return true
            elseif string.sub(action, 1, 15) == "target_drop_at " then
                local parts = string.split(action, " ")
                local targetId = parts[2]
                if targetId == clientId or targetId == "all" then
                    local coordsStr = parts[3]
                    local qty = parts[#parts]
                    local name = table.concat(parts, " ", 4, math.max(4, #parts - 1))

                    local coords = string.split(coordsStr or "", ",")
                    if #coords == 3 then
                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                        sendNotify("Inventory", "Moving to remote drop point...")
                        local reached = walkToUntilWithin(targetPos, 6)
                        if reached then
                            dropItemByName(name, qty)
                        else
                            sendNotify("Error", "Drop cancelled (obstructed/timed out)")
                            warn("[DROP] Cancelled/aborted before reaching drop point; not dropping.")
                        end
                    end
                end
                return true
            elseif string.sub(action, 1, 13) == "prepare_tool " then
                local params = string.sub(action, 14)
                local parts = string.split(params, " ")
                if #parts >= 3 then
                    local itemName = table.concat(parts, " ", 1, #parts - 2)
                    local pos1Str = parts[#parts - 1]
                    local pos2Str = parts[#parts]
                    
                    local p1Parts = string.split(pos1Str, ",")
                    local p2Parts = string.split(pos2Str, ",")
                    
                    if #p1Parts == 3 and #p2Parts == 3 then
                        local p1 = Vector3.new(tonumber(p1Parts[1]), tonumber(p1Parts[2]), tonumber(p1Parts[3]))
                        local p2 = Vector3.new(tonumber(p2Parts[1]), tonumber(p2Parts[2]), tonumber(p2Parts[3]))
                        startPrepareTool(itemName, p1, p2)
                    end
                end
                return true
            elseif string.sub(action, 1, 12) == "target_drop " then
                local parts = string.split(action, " ")
                if parts[2] == clientId then
                    local qty = parts[#parts]
                    local name = table.concat(parts, " ", 3, math.max(3, #parts - 1))
                    dropItemByName(name, qty)
                end
                return true
            end
            
            if string.sub(action, 1, 5) == "bring" then
                stopFollowing()
                local coords = string.split(string.sub(action, 7), ",")
                if #coords == 3 then
                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                    Movement.tweenTo(targetPos, { speedDiv = 50, minTime = 1, randomRadius = 3, yOffset = 1 })
                end
            elseif string.sub(action, 1, 4) == "goto" then
                stopFollowing()
                local coords = string.split(string.sub(action, 6), ",")
                if #coords == 3 then
                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                    Movement.slideTo(targetPos)
                end
            elseif string.sub(action, 1, 6) == "walkto" then
                stopFollowing()
                local coords = string.split(string.sub(action, 8), ",")
                if #coords == 3 then
                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                    Movement.walkTo(targetPos)
                end
            elseif string.sub(action, 1, 8) == "pathfind" then
                stopFollowing()
                local coords = string.split(string.sub(action, 10), ",")
                if #coords == 3 then
                    local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                    Movement.pathfindTo(targetPos)
                end
            elseif action == "cancel" then
                stopPrepare()
                Movement.cancelAll(false)
            elseif action == "jump" then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    LocalPlayer.Character.Humanoid.Jump = true
                end
            elseif string.sub(action, 1, 11) == "join_server" then
                local args = string.split(string.sub(action, 13), " ")
                if #args == 2 then
                    TeleportService:TeleportToPlaceInstance(tonumber(args[1]), args[2], LocalPlayer)
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
            elseif action == "refresh_configs" then
                fetchServerConfigs()
            elseif action == "reload" then
                terminateScript()
                loadstring(game:HttpGet(RELOAD_URL .. "?t=" .. os.time()))()
                return
            elseif string.sub(action, 1, 17) == "formation_follow " then
                local payload = string.sub(action, 18)
                local userIdStr, shapeStr, offsetsJson = string.match(payload, "^(%S+)%s+(%S+)%s+(.+)$")
                if userIdStr and shapeStr and offsetsJson then
                    formationLeaderId = tonumber(userIdStr)
                    formationShape = shapeStr
                    formationMode = "Follow"
                    formationActive = true
                    local success, offsetsData = pcall(function()
                        return HttpService:JSONDecode(offsetsJson)
                    end)
                    if success and offsetsData then
                        formationOffsets = offsetsData
                    else
                        formationOffsets = nil
                    end
                    if formationLeaderId then
                        startFollowing(formationLeaderId, formationShape)
                    end
                    sendNotify("Formation", "Following " .. (userIdStr or "leader") .. " in " .. formationShape)
                end
            elseif string.sub(action, 1, 7) == "voodoo " then
                local payload = string.sub(action, 8)
                local mode, coordsStr = string.match(payload, "^(%S+)%s+(.+)$")
                if mode and coordsStr then
                    local coords = string.split(coordsStr, ",")
                    if #coords == 3 then
                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                        local count = (mode == "burst") and 3 or 1
                        fireVoodoo(targetPos, count)
                    end
                end
            elseif string.sub(action, 1, 16) == "projectile_init " then
                local weapon = string.sub(action, 17)
                projectileWeapon = weapon
                projectileActive = false
                projectileTarget = nil
                
                if weapon == "Bow" or weapon == "Crossbow" then
                    task.spawn(scanAndEquip, weapon)
                end
                sendNotify("Projectile", "Prepared " .. weapon)

            elseif string.sub(action, 1, 16) == "projectile_set_y" then
                local yStr = string.sub(action, 18)
                local yVal = tonumber(yStr)
                if yVal then
                    projectileLaunchOffset = yVal
                    sendNotify("Projectile", "Set Launch Offset Y: " .. yVal)
                end

            elseif string.sub(action, 1, 15) == "projectile_aim " then
                local userIdStr = string.sub(action, 16)
                local userId = tonumber(userIdStr)
                if userId then
                    -- Find the player by UserId
                    local targetPlayer = nil
                    for _, player in ipairs(Players:GetPlayers()) do
                        if player.UserId == userId then
                            targetPlayer = player
                            break
                        end
                    end
                    
                    if targetPlayer then
                        projectileTarget = targetPlayer
                        projectileActive = true
                        
                        -- Set first-person zoom when aiming starts (like aim_assist.lua)
                        LocalPlayer.CameraMaxZoomDistance = 0.5
                        LocalPlayer.CameraMinZoomDistance = 0.5
                        
                        -- Press and hold mouse1 using VirtualInputManager (works on mobile!)
                        local VIM = game:GetService("VirtualInputManager")
                        VIM:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                    end
                end

            elseif action == "projectile_fire" then
                 if projectileActive and projectileTarget then
                    task.spawn(function()
                        -- Release mouse1 using VirtualInputManager (works on mobile!)
                        local VIM = game:GetService("VirtualInputManager")
                        VIM:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                        
                        -- Restore zoom
                        task.wait(0.1) -- Small delay to ensure shot fires
                        local preMaxZoom = 400 -- Default Roblox value
                        local preMinZoom = 0.5
                        LocalPlayer.CameraMaxZoomDistance = preMaxZoom
                        LocalPlayer.CameraMinZoomDistance = preMinZoom
                        
                        projectileActive = false
                        projectileTarget = nil
                    end)
                end
            elseif string.sub(action, 1, 6) == "equip " then
                local slot = tonumber(string.sub(action, 7))
                if slot then fireEquip(slot) end
            elseif action == "unequip_all" then
                for slot = 1, 6 do
                    fireInventoryStore(slot)
                    task.wait(0.05)
                end
            elseif string.sub(action, 1, 11) == "sync_equip " then
                local toolName = string.sub(action, 12)
                if toolName then task.spawn(scanAndEquip, toolName) end
            elseif string.sub(action, 1, 15) == "formation_goto " then
                local payload = string.sub(action, 16)
                local coordsStr, shapeStr, positionsJson = string.match(payload, "^(%S+)%s+(%S+)%s+(.+)$")
                if coordsStr and shapeStr and positionsJson then
                    local coords = string.split(coordsStr, ",")
                    formationShape = shapeStr
                    formationMode = "Goto"
                    formationActive = true
                    if #coords == 3 then
                        formationCenter = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                        if positionsJson then
                            local success, positionsData = pcall(function()
                                return HttpService:JSONDecode(positionsJson)
                            end)
                            if success and positionsData and positionsData[clientId] then
                                local myPos = positionsData[clientId]
                                local targetPos = Vector3.new(myPos.x, myPos.y, myPos.z)
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
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            elseif action == "spawn" then
                task.spawn(function()
                    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                    local playButton = playerGui and playerGui:FindFirstChild("SpawnGui", true) 
                        and playerGui.SpawnGui:FindFirstChild("Customization", true)
                        and playerGui.SpawnGui.Customization:FindFirstChild("PlayButton", true)
                    
                    if playButton and playButton:IsA("TextButton") then
                        if firesignal then
                            firesignal(playButton.MouseButton1Click)
                            firesignal(playButton.Activated)
                        end
                        pcall(function() playButton:Activate() end)
                        sendNotify("Army", "Spawn button clicked")
                    else
                        sendNotify("Army", "Spawn button not found")
                    end
                end)
            end
        end)
        
        if not execResult then
            warn("[ARMY] Command failed:", action, execError)
        end
        acknowledgeCommand(commandId, execResult, execError)
    else
        -- Commander is ignoring server orders (or it's a wait/no-op).
        acknowledgeCommand(commandId, true, nil)
    end
end

local function connectWebSocket()
    if not isRunning or isConnecting then return end
    isConnecting = true
    
    print("[ARMY] Connecting to WebSocket: " .. WS_URL)
    local success, ws = pcall(function()
        return WebSocket.connect(WS_URL)
    end)
    
    if not success or not ws then
        warn("[ARMY] WebSocket connection failed. Retrying in 5s...")
        isConnecting = false
        task.delay(5, connectWebSocket)
        return
    end
    
    activeWS = ws
    isConnecting = false
    
    ws.OnMessage:Connect(function(message)
        local success, data = pcall(function()
            return HttpService:JSONDecode(message)
        end)
        
        if success and data then
            if data.type == "registered" then
                clientId = data.clientId
                sendNotify("System", "Registered via WS: " .. clientId)
                print("[ARMY] Registered via WS as " .. clientId)
            elseif data.type == "heartbeat_ack" then
                -- Registration confirmed by server
                -- print("[ARMY] Heartbeat ACK")
            elseif data.type == "error" and data.code == "not_registered" then
                warn("[ARMY] Server says not registered. Re-registering...")
                activeWS:Send(HttpService:JSONEncode({
                    type = "register",
                    name = LocalPlayer.Name,
                    isCommander = isCommander,
                    clientId = clientId
                }))
            elseif data.id then
                handleActionData(data)
            end
        end
    end)
    
    ws.OnClose:Connect(function()
        print("[ARMY] WebSocket disconnected. Reconnecting in 5s...")
        activeWS = nil
        task.delay(5, connectWebSocket)
    end)
    
    -- Register
    local regData = {
        type = "register",
        name = LocalPlayer.Name,
        isCommander = isCommander,
        clientId = clientId -- Reuse if we have one
    }
    ws:Send(HttpService:JSONEncode(regData))
end

highlightPlayers = function()
    local highlights = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
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

stopFarming = function()
    farmToken = farmToken + 1
    isFarming = false
    stopGotoWalk()
end

stopRoute = function()
    routeToken = routeToken + 1
    isRouteRunning = false
    stopGotoWalk()
    if routePrevAutoJump ~= nil then
        autoJumpEnabled = routePrevAutoJump
        routePrevAutoJump = nil
    end
end

startRouteExecution = function(waypoints)
    stopRoute()
    local myToken = routeToken
    isRouteRunning = true
    routePrevAutoJump = autoJumpEnabled
    
    task.spawn(function()
        sendNotify("Route", "Starting route execution (" .. #waypoints .. " points)")
        local aborted = false
        for i, wp in ipairs(waypoints) do
            if not isRunning or myToken ~= routeToken then 
                isRouteRunning = false
                break 
            end
            
            -- Apply AutoJump setting for this leg of the journey
            autoJumpEnabled = coerceBool(wp.autoJump, true)
            
            local px = wp.pos and tonumber(wp.pos.x) or nil
            local py = wp.pos and tonumber(wp.pos.y) or nil
            local pz = wp.pos and tonumber(wp.pos.z) or nil
            if not (px and py and pz) then
                sendNotify("Route", "Route aborted - invalid waypoint data at point " .. i)
                isRouteRunning = false
                aborted = true
                break
            end

            local targetPos = Vector3.new(px, py, pz)
            print("[ROUTE] Moving to point " .. i .. "/" .. #waypoints .. " @ " .. tostring(targetPos) .. " (AutoJump: " .. tostring(autoJumpEnabled) .. ")")
            
            -- Route waypoints can disable jump. Don't force auto-jump during route legs;
            -- rely on `autoJumpEnabled = wp.autoJump` above.
            local reached = walkToUntilWithin(targetPos, 6, { forceAutoJump = false })
            if not reached then
                sendNotify("Route", "Route aborted - blocked at point " .. i)
                isRouteRunning = false
                aborted = true
                break
            end
        end
        
        if myToken == routeToken then
            isRouteRunning = false
            if routePrevAutoJump ~= nil then
                autoJumpEnabled = routePrevAutoJump
                routePrevAutoJump = nil
            end
            if not aborted then
                sendNotify("Route", "Route completed")
            end
        end
    end)
end

fetchRoutes = function()
    if not networkRequest then return end
    local success, response = robustRequest({
        Url = SERVER_URL .. "/routes",
        Method = "GET"
    })
    if success and response and response.Body then
        local jsonSuccess, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)
        if jsonSuccess and data then
            savedRoutes = data
            return true
        end
    end
    return false
end

syncSaveRoute = function(name, waypoints)
    if not networkRequest then return end
    robustRequest({
        Url = SERVER_URL .. "/routes",
        Method = "POST",
        Body = HttpService:JSONEncode({ name = name, waypoints = waypoints })
    })
end

syncDeleteRoute = function(name)
    if not networkRequest then return end
    robustRequest({
        Url = SERVER_URL .. "/routes/" .. HttpService:UrlEncode(name),
        Method = "DELETE"
    })
end

local function hasToolInInventory(targetName)
    targetName = targetName:lower()

    -- Prefer real instances if they exist (works even when UI panels are closed).
    local char = LocalPlayer.Character
    if char then
        for _, inst in ipairs(char:GetChildren()) do
            if inst:IsA("Tool") and inst.Name:lower():find(targetName, 1, true) then
                return true
            end
        end
    end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or (LocalPlayer:FindFirstChild("Backpack"))
    if backpack then
        for _, inst in ipairs(backpack:GetChildren()) do
            if inst:IsA("Tool") and inst.Name:lower():find(targetName, 1, true) then
                return true
            end
        end
    end
    
    -- Check toolbar
    local toolbarContainer = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("Panels", true)
        and LocalPlayer.PlayerGui.MainGui.Panels:FindFirstChild("Toolbar", true)
        and LocalPlayer.PlayerGui.MainGui.Panels.Toolbar:FindFirstChild("Container", true)
    
    if toolbarContainer then
        for i = 1, 6 do -- Standard 1-6 slots
            local n = tostring(i)
            local slot = toolbarContainer:FindFirstChild(n) or toolbarContainer:FindFirstChild("Slot" .. n)
            
            local title = slot and slot:FindFirstChild("Title", true)
            if title and title.Text:lower():find(targetName, 1, true) then
                return true
            end
        end
    end
    
    -- Check inventory
    local inventoryList = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("RightPanel", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel:FindFirstChild("Inventory", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel.Inventory:FindFirstChild("List", true)

    if inventoryList then
        for _, item in ipairs(inventoryList:GetChildren()) do
            if item:IsA("GuiObject") and item.Name:lower():find(targetName, 1, true) then
                return true
            end
        end
    end
    
    return false
end

stopPrepare = function()
    prepareToken = prepareToken + 1
    isPreparing = false
    stopGotoWalk()
end

startPrepareTool = function(itemName, pos1, pos2)
    stopPrepare()
    local myToken = prepareToken
    isPreparing = true
    
    task.spawn(function()
        sendNotify("Prepare", "Starting prep for: " .. itemName)

        local targetLower = (itemName or ""):lower()
        local STOP_PREP_WHEN_FOUND = true -- user request: stop once the tool is found

        -- Active scan state
        local lastSlotStep = 0
        local SLOT_STEP_INTERVAL = 0.35 -- seconds; one slot step each interval (cycles 1-6)
        local slotCursor = 1

        local lastInvUse = 0
        local INV_USE_COOLDOWN = 1.5 -- seconds; avoid spamming UseBagItem

        local function getToolbarTitleTextLower()
            local toolbarContainer = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
                and LocalPlayer.PlayerGui.MainGui:FindFirstChild("Panels", true)
                and LocalPlayer.PlayerGui.MainGui.Panels:FindFirstChild("Toolbar", true)
                and LocalPlayer.PlayerGui.MainGui.Panels.Toolbar:FindFirstChild("Container", true)
            local toolbarTitle = toolbarContainer and toolbarContainer:FindFirstChild("Title", true)
            local txt = toolbarTitle and toolbarTitle.Text or ""
            if type(txt) ~= "string" then
                return ""
            end
            return txt:lower()
        end

        local function findInventoryOrderByNameLower(nameLower)
            local inventoryList = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
                and LocalPlayer.PlayerGui.MainGui:FindFirstChild("RightPanel", true)
                and LocalPlayer.PlayerGui.MainGui.RightPanel:FindFirstChild("Inventory", true)
                and LocalPlayer.PlayerGui.MainGui.RightPanel.Inventory:FindFirstChild("List", true)

            if not inventoryList then
                return nil
            end

            for _, item in ipairs(inventoryList:GetChildren()) do
                if item:IsA("GuiObject") then
                    local n = item.Name
                    if type(n) == "string" and n:lower():find(nameLower, 1, true) then
                        return item.LayoutOrder
                    end
                end
            end

            return nil
        end

        local function stepSlotScan(nameLower)
            -- Equip one slot, then check the (currently-equipped) toolbar title.
            local slot = slotCursor
            slotCursor = (slotCursor % 6) + 1

            fireEquip(slot)

            -- Small yield so UI/replication has a chance to update.
            task.wait(0.2)

            local titleLower = getToolbarTitleTextLower()
            if titleLower ~= "" and titleLower:find(nameLower, 1, true) then
                return true
            end
            return false
        end

        while isRunning and myToken == prepareToken do
            local hasIt = hasToolInInventory(itemName)
            local targetPos = hasIt and pos1 or pos2
            local now = os.clock()

            -- Always actively scan slots 1-6 (round-robin), so we don't miss tools
            -- that only appear when a slot is equipped.
            if (now - lastSlotStep) >= SLOT_STEP_INTERVAL then
                lastSlotStep = now
                local foundInSlots = stepSlotScan(targetLower)
                if foundInSlots then
                    hasIt = true
                    targetPos = pos1
                end
            end

            -- Always check inventory UI list; if present there, try using it to move to toolbar.
            -- This helps when the tool exists but isn't currently in any of the 1-6 toolbar slots.
            local invOrder = findInventoryOrderByNameLower(targetLower)
            if invOrder and (now - lastInvUse) >= INV_USE_COOLDOWN then
                lastInvUse = now
                fireInventoryUse(invOrder)
            end
            
            if not hasIt then
                -- Targeted auto-pickup while searching
                local items = workspace:FindFirstChild("Items")
                if items then
                    for _, item in ipairs(items:GetChildren()) do
                        if item.Name:lower():find(itemName:lower(), 1, true) then
                            local char, hum, root = getMyRig()
                            if root then
                                local partPos = nil
                                if item:IsA("BasePart") then
                                    partPos = item.Position
                                elseif item:IsA("Model") then
                                    local pp = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart", true)
                                    partPos = pp and pp.Position or nil
                                end

                                local dist = (partPos and (partPos - root.Position).Magnitude) or math.huge
                                if dist < PICKUP_RANGE then
                                    firePickup(item)
                                end
                            end
                        end
                    end
                end
            end
            
            -- Move towards current destination
            -- NOTE: walkToUntilWithin() is blocking; give it a short timeout so we keep
            -- scanning/picking while traveling.
            local reached = walkToUntilWithin(targetPos, 6, { timeoutSeconds = 1.0 })

            -- If we have the tool and we managed to reach the "have tool" position,
            -- stop the preparing loop entirely.
            if STOP_PREP_WHEN_FOUND and hasIt and reached and targetPos == pos1 then
                stopPrepare()
                break
            end
            task.wait(0.25)
        end
    end)
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

getMyRig = function()
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

-- Shared "humanoid MoveTo until X" helper used by both:
-- - startGotoWalkMoveTo(): async walking until close enough (goto-style)
-- - walkToUntilWithin(): blocking walk until within distance (route/drop-style)
--
-- opts:
--   token (number)            : cancel token to respect (usually `gotoWalkToken` snapshot)
--   stopDistance (number)     : distance at/below which we consider "reached"
--   stopTolerance (number)    : extra tolerance (only applied in wrappers if needed)
--   distanceMode (string)     : "3d" or "2d_xz"
--   forceAutoJump (boolean)   : default true; increments/decrements force counter
--   refresh (number)          : MoveTo refresh period (seconds)
--   timeoutSeconds (number?)  : optional overall timeout
--   stuckTime (number?)       : optional seconds of "not moving" before considered stuck
--   stuckEps (number?)        : studs moved per tick below which we count as "not moving"
--   abortOnStuck (boolean?)   : if true and stuck triggers, abort instead of nudging
--   stopMovementOnReach (bool): if true, zero humanoid movement on reach
-- returns: reached (bool), lastDist (number), stoppedBy (string)
local function runMoveToUntil(targetPos, opts)
    opts = opts or {}

    local token = opts.token
    local stopDistance = tonumber(opts.stopDistance) or GOTO_STOP_DISTANCE
    local distanceMode = opts.distanceMode or "3d" -- "3d" | "2d_xz"
    local refresh = tonumber(opts.refresh) or WALKTO_REFRESH

    local timeoutSeconds = tonumber(opts.timeoutSeconds)
    local stuckTimeLimit = tonumber(opts.stuckTime)
    local stuckEps = tonumber(opts.stuckEps) or GOTO_STUCK_EPS
    local abortOnStuck = (opts.abortOnStuck == true)
    local stopMovementOnReach = (opts.stopMovementOnReach == true)

    local forceAutoJump = true
    if opts.forceAutoJump ~= nil then
        forceAutoJump = (opts.forceAutoJump == true)
    end

    local didForceAutoJump = false
    if forceAutoJump then
        beginForceAutoJump()
        didForceAutoJump = true
    end

    local reached = false
    local stoppedBy = "canceled"
    local lastDist = math.huge

    local startT = os.clock()
    local lastMoveTo = 0
    local lastPos = nil
    local stuckTime = 0

    local function cleanup()
        if didForceAutoJump then
            endForceAutoJump()
        end
    end

    local ok, err = pcall(function()
        while isRunning and (token == nil or token == gotoWalkToken) do
            local delta = RunService.Heartbeat:Wait()

            if timeoutSeconds and (os.clock() - startT) >= timeoutSeconds then
                stoppedBy = "timeout"
                break
            end

            local myChar = LocalPlayer.Character
            local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
            local myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")

            if myHumanoid and myHumanoid.SeatPart then
                myHumanoid.Sit = false
            end

            if not (myRoot and myHumanoid) then
                lastPos = nil
                stuckTime = 0
            else
                local dist
                if distanceMode == "2d_xz" then
                    dist = (Vector2.new(targetPos.X, targetPos.Z) - Vector2.new(myRoot.Position.X, myRoot.Position.Z)).Magnitude
                else
                    dist = (targetPos - myRoot.Position).Magnitude
                end
                lastDist = dist

                if dist <= stopDistance then
                    reached = true
                    stoppedBy = "reached"

                    if stopMovementOnReach then
                        pcall(function()
                            myHumanoid:Move(Vector3.new(0, 0, 0), false)
                            myHumanoid:MoveTo(myRoot.Position)
                        end)
                    end
                    break
                end

                -- Refresh MoveTo periodically.
                if os.clock() - lastMoveTo > refresh then
                    lastMoveTo = os.clock()
                    pcall(function()
                        myHumanoid:MoveTo(targetPos)
                    end)
                end

                -- Optional stuck detection for MoveTo loops.
                if stuckTimeLimit then
                    if lastPos then
                        local moved = (myRoot.Position - lastPos).Magnitude
                        if moved < stuckEps then
                            stuckTime = stuckTime + (delta or 0)
                        else
                            stuckTime = 0
                        end
                    end
                    lastPos = myRoot.Position

                    if stuckTime >= stuckTimeLimit then
                        if abortOnStuck then
                            stoppedBy = "stuck"
                            break
                        end

                        -- Nudge: refresh MoveTo and apply a short Move vector toward the target.
                        stuckTime = 0
                        pcall(function()
                            local offset = targetPos - myRoot.Position
                            local dir = Vector3.new(offset.X, 0, offset.Z)
                            if dir.Magnitude > 1e-6 then
                                dir = dir.Unit
                                myHumanoid:MoveTo(targetPos)
                                myHumanoid:Move(dir, false)
                            else
                                myHumanoid:MoveTo(targetPos)
                            end
                        end)
                    end
                end
            end
        end
    end)

    cleanup()
    if not ok then
        stoppedBy = "error"
        warn("[MOVE] MoveTo loop error:", err)
    end

    return reached, lastDist, stoppedBy
end

local function getClosestPointOnPart(part, point)
    local partCFrame = part.CFrame
    local size = part.Size
    local localPoint = partCFrame:PointToObjectSpace(point)
    local halfSize = size / 2
    local clampedLocal = Vector3.new(
        math.clamp(localPoint.X, -halfSize.X, halfSize.X),
        math.clamp(localPoint.Y, -halfSize.Y, halfSize.Y),
        math.clamp(localPoint.Z, -halfSize.Z, halfSize.Z)
    )
    return partCFrame:PointToWorldSpace(clampedLocal)
end

findEdgePointRaycast = function(target, fromPos)
    local targetPart = target:IsA("BasePart") and target or (target:IsA("Model") and (target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)))
    if not targetPart then 
        return (target:IsA("Model") and target.PrimaryPart and target.PrimaryPart.Position) or (target:IsA("BasePart") and target.Position) or fromPos
    end
    
    local center = targetPart.Position
    local params = RaycastParams.new()
    
    -- Optimized ancestry: Include the whole model/resource tree to ensure we hit hitboxes
    local filterRoot = target:IsA("Model") and target or target:FindFirstAncestorOfClass("Model") or target
    params.FilterDescendantsInstances = {filterRoot}
    params.FilterType = Enum.RaycastFilterType.Include
    
    local bestPoint = center
    local minDist = math.huge
    
    -- Fire 10 rays at random angles from far away towards the center
    for i = 1, 10 do
        local angle = math.rad(math.random(0, 360))
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        -- Standard resource hitboxes are rarely larger than 20-30 studs
        local startPos = center + (direction * 50) 
        local rayResult = workspace:Raycast(startPos, -direction * 50, params)
        
        if rayResult then
            local p = rayResult.Position
            local d = (p - fromPos).Magnitude
            if d < minDist then
                minDist = d
                bestPoint = p
            end
        end
    end
    return bestPoint
end

-- Forward declarations so Movement methods can call these without accidental global lookups.
local startGotoWalk, startGotoWalkMoveTo, startGotoPathfind

Movement = {}

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

function Movement.pathfindTo(targetPos)
    startGotoPathfind(targetPos)
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

startGotoWalkMoveTo = function(targetPos, opts)
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
    opts = opts or {}
    task.spawn(function()
        local ok, err = pcall(function()
            local reached = runMoveToUntil(targetPos, {
                token = myToken,
                stopDistance = GOTO_STOP_DISTANCE,
                distanceMode = "3d",
                forceAutoJump = true,
                refresh = WALKTO_REFRESH,
                timeoutSeconds = opts.timeoutSeconds,
                stuckTime = opts.stuckTime,
                stuckEps = opts.stuckEps,
                abortOnStuck = opts.abortOnStuck,
                stopMovementOnReach = true
            })

            -- If we reached the target and we're still the active walk token, clear state.
            if reached and myToken == gotoWalkToken then
                stopGotoWalk()
            end
        end)
        if not ok then
            warn("[WALKTO] Walk loop error:", err)
        end
    end)
end

startGotoPathfind = function(targetPos, opts)
    stopGotoWalk()
    stopFollowing()

    local _, humanoid, root = getMyRig()
    if not (humanoid and root) then return end

    ensureUnseated(humanoid)
    moveTarget = targetPos

    opts = opts or {}
    local waypointStopDist = tonumber(opts.waypointStopDist) or 5

    -- Cancel token shared with other "goto" movement modes (Slide/Walk).
    -- This lets the existing Cancel ("C") behavior stop pathfinding too via stopGotoWalk().
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
            local myChar = LocalPlayer.Character
            local myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")
            local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
            if not (myHumanoid and myRoot) then
                return
            end

            local path = PathfindingService:CreatePath({
                AgentRadius = 0,
                AgentHeight = 5,
                AgentMaxSlope = 75,
            })

            local computedOk = pcall(function()
                path:ComputeAsync(myRoot.Position, targetPos)
            end)

            if not computedOk or myToken ~= gotoWalkToken then
                return
            end

            if path.Status ~= Enum.PathStatus.Success then
                -- Fallback: plain MoveTo to at least attempt movement.
                pcall(function()
                    myHumanoid:MoveTo(targetPos)
                end)
                return
            end

            local waypoints = path:GetWaypoints()
            for _, wp in ipairs(waypoints) do
                if not isRunning or myToken ~= gotoWalkToken then
                    break
                end

                myChar = LocalPlayer.Character
                myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")
                myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
                if not (myHumanoid and myRoot) then
                    break
                end

                ensureUnseated(myHumanoid)

                pcall(function()
                    myHumanoid:MoveTo(wp.Position)
                end)

                if wp.Action == Enum.PathWaypointAction.Jump then
                    pcall(function()
                        myHumanoid.Jump = true
                    end)
                end

                -- Wait until we're close enough to this waypoint (or canceled).
                while isRunning and myToken == gotoWalkToken do
                    myChar = LocalPlayer.Character
                    myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
                    myHumanoid = myChar and myChar:FindFirstChildOfClass("Humanoid")
                    if not (myRoot and myHumanoid) then
                        break
                    end

                    if myHumanoid.SeatPart then
                        myHumanoid.Sit = false
                    end

                    local dist = (wp.Position - myRoot.Position).Magnitude
                    if dist <= waypointStopDist then
                        break
                    end

                    RunService.Heartbeat:Wait()
                end
            end
        end)

        cleanup()
        if not ok then
            warn("[PATHFIND] Loop error:", err)
        end

        -- Only clear movement state if we're still the active token (don't clobber a newer move).
        if myToken == gotoWalkToken then
            moveTarget = nil
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

fireVoodoo = function(targetPos, count)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    local fireCount = tonumber(count) or 1
    for i = 1, fireCount do
        -- Create 14-byte buffer: [0][11][f32][f32][f32]
        -- VoodooSpell packet ID.
        local b = buffer.create(14)
        buffer.writeu8(b, 0, 0)   -- Namespace 0
        buffer.writeu8(b, 1, PacketIds.VoodooSpell)
        buffer.writef32(b, 2, targetPos.X)
        buffer.writef32(b, 6, targetPos.Y)
        buffer.writef32(b, 10, targetPos.Z)
        
        -- Fire the buffer object DIRECTLY
        ByteNetRemote:FireServer(b)
        if fireCount > 1 then
            task.wait(0.05) -- Small delay between burst fires
        end
    end
end

fireEquip = function(slot)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 3-byte buffer: [0][EquipTool][u8(slot)]
    local b = buffer.create(3)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, PacketIds.EquipTool)  -- EquipTool packet
    buffer.writeu8(b, 2, slot) -- Slot index
    
    -- Fire the buffer object DIRECTLY
    ByteNetRemote:FireServer(b)
end

fireInventoryStore = function(slot)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 3-byte buffer: [0][Retool][u8(slot)]
    local b = buffer.create(3)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, PacketIds.Retool)  -- Retool packet
    buffer.writeu8(b, 2, slot) -- Slot index
    
    ByteNetRemote:FireServer(b)
end

fireInventoryUse = function(order)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 4-byte buffer: [0][UseBagItem][u16(order)]
    local b = buffer.create(4)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, PacketIds.UseBagItem)  -- UseBagItem packet
    buffer.writeu16(b, 2, order) -- Index (u16 little-endian)
    
    ByteNetRemote:FireServer(b)
end

fireInventoryDrop = function(order)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 4-byte buffer: [0][DropBagItem][u16(order)]
    local b = buffer.create(4)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, PacketIds.DropBagItem)  -- DropBagItem packet
    buffer.writeu16(b, 2, order) -- Index (u16 little-endian)
    
    ByteNetRemote:FireServer(b)
end

fireAction = function(actionId, entityId)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end

    -- SwingTool uses array structure: [0][id][count_u16][entityId_u32...]
    if actionId == PacketIds.SwingTool then
        local b = buffer.create(8)
        buffer.writeu8(b, 0, 0)   -- Namespace 0
        buffer.writeu8(b, 1, PacketIds.SwingTool)  -- SwingTool packet
        buffer.writeu16(b, 2, 1)  -- Count (1 target)
        buffer.writeu32(b, 4, entityId) -- Target Entity ID
        
        -- DEBUG: Print buffer content (Decimal Escape Format)
        local debugStr = ""
        for i = 0, 7 do
            -- Read each byte and format as "\000"
            local byte = buffer.readu8(b, i)
            debugStr = debugStr .. string.format("\\%03d", byte)
        end
        print("[SWING] Sending buffer: " .. debugStr)
        
        ByteNetRemote:FireServer(b)
    else
        -- Default 6-byte structure for other simple actions
        local b = buffer.create(6)
        buffer.writeu8(b, 0, 0)
        buffer.writeu8(b, 1, actionId)
        buffer.writeu32(b, 2, entityId)
        ByteNetRemote:FireServer(b)
    end
end



getInventoryReport = function(query)
    local results = {}
    local inventoryList = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("RightPanel", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel:FindFirstChild("Inventory", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel.Inventory:FindFirstChild("List", true)

    if not inventoryList then return "{}" end

    local targetQuery = query and query:lower() or ""

    for _, item in ipairs(inventoryList:GetChildren()) do
        if item:IsA("GuiObject") and item.Name ~= "UIListLayout" then
            local itemName = item.Name
            if itemName:lower():find(targetQuery, 1, true) then
                local quantity = "1"
                local qText = item:FindFirstChild("QuantityText", true)
                if qText then
                    quantity = qText.Text:gsub("x", ""):gsub("%D", "")
                end
                
                table.insert(results, {
                    name = itemName,
                    quantity = tonumber(quantity) or 1,
                    order = item.LayoutOrder
                })
            end
        end
    end
    
    return HttpService:JSONEncode(results)
end

dropItemByName = function(itemName, quantity)
    local results = {}
    local inventoryList = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("RightPanel", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel:FindFirstChild("Inventory", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel.Inventory:FindFirstChild("List", true)

    if not inventoryList then 
        sendNotify("Drop Error", "Could not find inventory list UI")
        return 
    end
    
    local targetQty = tonumber(quantity)
    local dropped = 0
    local foundItem = nil
    
    -- Robust matching: check frame name or any inner text labels
    for _, item in ipairs(inventoryList:GetChildren()) do
        if item:IsA("GuiObject") and item.Name ~= "UIListLayout" then
            local matches = false
            if item.Name:lower() == itemName:lower() then
                matches = true
            else
                -- Check inner labels (sometimes the frame is just "Item" or a number)
                for _, sub in ipairs(item:GetDescendants()) do
                    if sub:IsA("TextLabel") and sub.Text:lower():find(itemName:lower(), 1, true) then
                        matches = true
                        break
                    end
                end
            end

            if matches then
                foundItem = item
                if not targetQty then
                    local qStr = (type(quantity) == "string") and quantity:lower() or ""
                    if qStr == "all" then
                        local qText = item:FindFirstChild("QuantityText", true)
                        if qText and typeof(qText.Text) == "string" then
                            local parsed = qText.Text:gsub("x", ""):gsub("%D", "")
                            targetQty = tonumber(parsed)
                        end
                    end
                end

                targetQty = targetQty or 1
                local order = item.LayoutOrder
                
                sendNotify("Drop", "Dropping " .. targetQty .. "x " .. (item.Name or itemName))
                
                local function getQty()
                    if not item or not item.Parent then return 0 end
                    local qText = item:FindFirstChild("QuantityText", true)
                    if qText and qText.Text ~= "" then
                        local txt = qText.Text:gsub("x", ""):gsub("%D", "")
                        return tonumber(txt) or 1
                    end
                    return 1 -- Assume 1 if it exists but no visible quantity text
                end

                for i = 1, targetQty do
                    local before = getQty()
                    fireInventoryDrop(order)
                    
                    local verified = false
                    -- Wait 0.05s baseline
                    task.wait(0.05)
                    
                    -- Check if it decreased. If not, wait a bit more for replication
                    if getQty() < before then
                        verified = true
                    else
                        for attempt = 1, 5 do
                            task.wait(0.05)
                            if getQty() < before then
                                verified = true
                                break
                            end
                        end
                    end
                    
                    if not verified then
                        warn("[DROP] Verification failed for " .. itemName .. " at " .. i)
                        sendNotify("Verify Fail", "Drop lag detected. Stopping for safety.")
                        break
                    end
                    dropped = dropped + 1
                end
                break
            end
        end
    end

    if dropped > 0 then
        sendNotify("Success", "Successfully dropped " .. dropped .. "x " .. itemName)
    elseif not foundItem then
        sendNotify("Error", "Item '" .. itemName .. "' not found in inventory")
    else
        sendNotify("Error", "Found item but failed to drop")
    end
    
    print("[DROP] Dropped " .. dropped .. "x " .. itemName)
end

walkToUntilWithin = function(targetPos, stopDistance, opts)
    -- Returns true if we actually reached the stopDistance, false if cancelled/aborted.
    stopDistance = tonumber(stopDistance) or 6
    local STOP_TOLERANCE = 0.1 -- studs; allow minor overshoot/latency before considering it "reached"
    opts = opts or {}
    local forceAutoJump = true
    if opts.forceAutoJump ~= nil then
        forceAutoJump = (opts.forceAutoJump == true)
    end

    -- Cancel any existing goto loops so this doesn't fight them.
    stopGotoWalk()
    stopFollowing()
    stopMoveTween()
    stopFollowTween()

    local myToken = gotoWalkToken
    local reached = false
    local lastDist = math.huge
    local ok, err = pcall(function()
        local stoppedBy
        reached, lastDist, stoppedBy = runMoveToUntil(targetPos, {
            token = myToken,
            stopDistance = stopDistance,
            distanceMode = "2d_xz",
            forceAutoJump = forceAutoJump,
            refresh = WALKTO_REFRESH,
            timeoutSeconds = opts.timeoutSeconds,
            stuckTime = opts.stuckTime,
            stuckEps = opts.stuckEps,
            abortOnStuck = opts.abortOnStuck,
            stopMovementOnReach = true
        })

        -- If we timed out or got stuck, log a hint (the caller decides what to do).
        if (not reached) and (stoppedBy == "timeout") then
            warn("[MOVE] walkToUntilWithin timed out.")
        elseif (not reached) and (stoppedBy == "stuck") then
            warn("[MOVE] walkToUntilWithin aborted (stuck).")
        end
    end)
    if not ok then
        warn("[DROP] WalkTo loop error:", err)
    end

    -- If we got interrupted (token changed) between Heartbeat ticks, we may have arrived but never hit the <= check.
    if not reached then
        local myChar = LocalPlayer.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        if myRoot then
            local finalDist = (Vector2.new(targetPos.X, targetPos.Z) - Vector2.new(myRoot.Position.X, myRoot.Position.Z)).Magnitude
            lastDist = math.min(lastDist, finalDist)
            if finalDist <= (stopDistance + STOP_TOLERANCE) then
                reached = true
            end
        end
    end

    if (not reached) and (lastDist < math.huge) then
        warn(string.format("[DROP] Did not reach drop point (dist=%.2f, stop=%.2f).", lastDist, stopDistance))
    end

    return ok and reached
end

local function showInventoryManager()
    local coreGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not coreGui then return end
    
    if coreGui:FindFirstChild("ArmyInventoryManager") then
        coreGui.ArmyInventoryManager:Destroy()
    end
    
    local screenGui = Instance.new("ScreenGui", coreGui)
    screenGui.Name = "ArmyInventoryManager"
    
    local mainFrame = Instance.new("Frame", screenGui)
    mainFrame.Size = UDim2.new(0, 650, 0, 450)
    mainFrame.Position = UDim2.new(0.5, -325, 0.5, -225)
    mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    mainFrame.BorderSizePixel = 0
    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 12)
    Instance.new("UIStroke", mainFrame).Color = Color3.fromRGB(60, 60, 70)
    
    -- Header
    local header = Instance.new("Frame", mainFrame)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Position = UDim2.new(0, 20, 0, 0)
    title.Text = "INVENTORY MANAGER"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 18
    title.Font = Enum.Font.GothamBold
    title.BackgroundTransparency = 1
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 50, 0, 50)
    close.Position = UDim2.new(1, -50, 0, 0)
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(255, 100, 100)
    close.TextSize = 20
    close.Font = Enum.Font.GothamBold
    close.BackgroundTransparency = 1
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local refreshBtn = Instance.new("TextButton", header)
    refreshBtn.Size = UDim2.new(0, 80, 0, 30)
    refreshBtn.Position = UDim2.new(1, -90, 0, 10)
    refreshBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
    refreshBtn.Text = "REFRESH"
    refreshBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
    refreshBtn.TextSize = 12
    refreshBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)

    local globalDropBtn = Instance.new("TextButton", header)
    globalDropBtn.Size = UDim2.new(0, 80, 0, 30)
    globalDropBtn.Position = UDim2.new(1, -180, 0, 10)
    globalDropBtn.BackgroundColor3 = Color3.fromRGB(150, 100, 60)
    globalDropBtn.Text = "DROP"
    globalDropBtn.TextColor3 = Color3.fromRGB(255, 230, 200)
    globalDropBtn.TextSize = 12
    globalDropBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", globalDropBtn).CornerRadius = UDim.new(0, 6)

    -- View 3: Global Drop Menu (Popup)
    local dropMenu = Instance.new("Frame", mainFrame)
    dropMenu.Size = UDim2.new(0, 300, 0, 220)
    dropMenu.Position = UDim2.new(0.5, -150, 0.5, -110)
    dropMenu.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    dropMenu.BorderSizePixel = 0
    dropMenu.Visible = false
    dropMenu.ZIndex = 10
    local menuCorner = Instance.new("UICorner", dropMenu)
    menuCorner.CornerRadius = UDim.new(0, 10)
    local menuStroke = Instance.new("UIStroke", dropMenu)
    menuStroke.Color = Color3.fromRGB(100, 100, 110)
    menuStroke.Thickness = 2

    local menuTitle = Instance.new("TextLabel", dropMenu)
    menuTitle.Size = UDim2.new(1, 0, 0, 40)
    menuTitle.Text = "GLOBAL DROP ORDER"
    menuTitle.TextColor3 = Color3.fromRGB(255, 200, 100)
    menuTitle.Font = Enum.Font.GothamBold
    menuTitle.TextSize = 14
    menuTitle.BackgroundTransparency = 1
    menuTitle.ZIndex = 11

    local gItemInput = Instance.new("TextBox", dropMenu)
    gItemInput.Size = UDim2.new(1, -40, 0, 35)
    gItemInput.Position = UDim2.new(0, 20, 0, 50)
    gItemInput.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
    gItemInput.PlaceholderText = "Item Name"
    gItemInput.Text = ""
    gItemInput.TextColor3 = Color3.fromRGB(255, 255, 255)
    gItemInput.Font = Enum.Font.Gotham
    gItemInput.ZIndex = 11
    Instance.new("UICorner", gItemInput)

    local gQtyInput = Instance.new("TextBox", dropMenu)
    gQtyInput.Size = UDim2.new(1, -40, 0, 35)
    gQtyInput.Position = UDim2.new(0, 20, 0, 95)
    gQtyInput.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
    gQtyInput.PlaceholderText = "Amount"
    gQtyInput.Text = "1"
    gQtyInput.TextColor3 = Color3.fromRGB(100, 255, 100)
    gQtyInput.Font = Enum.Font.GothamBold
    gQtyInput.ZIndex = 11
    Instance.new("UICorner", gQtyInput)

    local gConfirmBtn = Instance.new("TextButton", dropMenu)
    gConfirmBtn.Size = UDim2.new(1, -40, 0, 40)
    gConfirmBtn.Position = UDim2.new(0, 20, 0, 145)
    gConfirmBtn.BackgroundColor3 = Color3.fromRGB(100, 180, 100)
    gConfirmBtn.Text = "CONFIRM & PICK LOCATION"
    gConfirmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    gConfirmBtn.Font = Enum.Font.GothamBold
    gConfirmBtn.ZIndex = 11
    Instance.new("UICorner", gConfirmBtn)

    local gCancelBtn = Instance.new("TextButton", dropMenu)
    gCancelBtn.Size = UDim2.new(1, 0, 0, 20)
    gCancelBtn.Position = UDim2.new(0, 0, 1, -25)
    gCancelBtn.Text = "CANCEL"
    gCancelBtn.TextColor3 = Color3.fromRGB(200, 80, 80)
    gCancelBtn.Font = Enum.Font.Gotham
    gCancelBtn.TextSize = 10
    gCancelBtn.BackgroundTransparency = 1
    gCancelBtn.ZIndex = 11
    
    -- Main Container
    local container = Instance.new("Frame", mainFrame)
    container.Size = UDim2.new(1, -20, 1, -70)
    container.Position = UDim2.new(0, 10, 0, 60)
    container.BackgroundTransparency = 1
    
    -- Left Panel (Clients list)
    local leftPanel = Instance.new("ScrollingFrame", container)
    leftPanel.Size = UDim2.new(0.3, -5, 1, 0)
    leftPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    leftPanel.BorderSizePixel = 0
    leftPanel.ScrollBarThickness = 2
    Instance.new("UICorner", leftPanel).CornerRadius = UDim.new(0, 8)
    local leftLayout = Instance.new("UIListLayout", leftPanel)
    leftLayout.Padding = UDim.new(0, 5)
    
    -- Right Panel (Views)
    local rightPanel = Instance.new("Frame", container)
    rightPanel.Size = UDim2.new(0.7, -5, 1, 0)
    rightPanel.Position = UDim2.new(0.3, 5, 0, 0)
    rightPanel.BackgroundTransparency = 1
    
    local selectedClientId = nil
    local currentCachedInventories = {}

    -- View 1: Global Search View
    local globalView = Instance.new("Frame", rightPanel)
    globalView.Size = UDim2.new(1, 0, 1, 0)
    globalView.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    globalView.BorderSizePixel = 0
    Instance.new("UICorner", globalView).CornerRadius = UDim.new(0, 8)
    
    local searchLabel = Instance.new("TextLabel", globalView)
    searchLabel.Size = UDim2.new(1, -20, 0, 30)
    searchLabel.Position = UDim2.new(0, 10, 0, 10)
    searchLabel.Text = "Global Inventory Search (Cached or Fresh Scan)"
    searchLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
    searchLabel.TextSize = 14
    searchLabel.Font = Enum.Font.GothamBold
    searchLabel.BackgroundTransparency = 1
    searchLabel.TextXAlignment = Enum.TextXAlignment.Left
    
    local searchBox = Instance.new("TextBox", globalView)
    searchBox.Size = UDim2.new(1, -20, 0, 40)
    searchBox.Position = UDim2.new(0, 10, 0, 45)
    searchBox.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    searchBox.Text = ""
    searchBox.PlaceholderText = "Search item names..."
    searchBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    searchBox.Font = Enum.Font.Gotham
    Instance.new("UICorner", searchBox)
    
    local resultsFrame = Instance.new("ScrollingFrame", globalView)
    resultsFrame.Size = UDim2.new(1, -20, 1, -150)
    resultsFrame.Position = UDim2.new(0, 10, 0, 95)
    resultsFrame.BackgroundTransparency = 1
    resultsFrame.ScrollBarThickness = 2
    local resultsLayout = Instance.new("UIListLayout", resultsFrame)
    resultsLayout.Padding = UDim.new(0, 2)
    
    local searchBtn = Instance.new("TextButton", globalView)
    searchBtn.Size = UDim2.new(1, -20, 0, 40)
    searchBtn.Position = UDim2.new(0, 10, 1, -50)
    searchBtn.BackgroundColor3 = Color3.fromRGB(100, 150, 255)
    searchBtn.Text = "FORCE GLOBAL SCAN"
    searchBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    searchBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", searchBtn)
    
    -- View 2: Client Selective View
    local clientView = Instance.new("Frame", rightPanel)
    clientView.Size = UDim2.new(1, 0, 1, 0)
    clientView.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    clientView.BorderSizePixel = 0
    clientView.Visible = false
    Instance.new("UICorner", clientView).CornerRadius = UDim.new(0, 8)
    
    local clientTitle = Instance.new("TextLabel", clientView)
    clientTitle.Size = UDim2.new(1, -20, 0, 40)
    clientTitle.Position = UDim2.new(0, 10, 0, 10)
    clientTitle.TextColor3 = Color3.fromRGB(255, 200, 100)
    clientTitle.TextSize = 16
    clientTitle.Font = Enum.Font.GothamBold
    clientTitle.BackgroundTransparency = 1
    clientTitle.TextXAlignment = Enum.TextXAlignment.Left
    
    local dropName = Instance.new("TextBox", clientView)
    dropName.Size = UDim2.new(1, -20, 0, 40)
    dropName.Position = UDim2.new(0, 10, 0, 60)
    dropName.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    dropName.PlaceholderText = "Item Name to Drop"
    dropName.Text = ""
    dropName.TextColor3 = Color3.fromRGB(255, 255, 255)
    dropName.Font = Enum.Font.Gotham
    Instance.new("UICorner", dropName)
    
    local dropQty = Instance.new("TextBox", clientView)
    dropQty.Size = UDim2.new(1, -20, 0, 40)
    dropQty.Position = UDim2.new(0, 10, 0, 110)
    dropQty.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    dropQty.PlaceholderText = "Quantity (Default 1 or All)"
    dropQty.Text = "1"
    dropQty.TextColor3 = Color3.fromRGB(255, 255, 255)
    dropQty.Font = Enum.Font.Gotham
    Instance.new("UICorner", dropQty)
    
    local dropBtn = Instance.new("TextButton", clientView)
    dropBtn.Size = UDim2.new(1, -20, 0, 50)
    dropBtn.Position = UDim2.new(0, 10, 0, 170)
    dropBtn.BackgroundColor3 = Color3.fromRGB(255, 100, 100)
    dropBtn.Text = "DROP ITEM(S)"
    dropBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    dropBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", dropBtn)
    
    local deselectBtn = Instance.new("TextButton", clientView)
    deselectBtn.Size = UDim2.new(1, -20, 0, 40)
    deselectBtn.Position = UDim2.new(0, 10, 1, -50)
    deselectBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
    deselectBtn.Text = "BACK TO GLOBAL SEARCH"
    deselectBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
    deselectBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", deselectBtn)

    -- Logic Functions
    local function updateViewVisibility()
        if selectedClientId then
            globalView.Visible = false
            clientView.Visible = true
            clientTitle.Text = "SOLDIER: " .. selectedClientId
        else
            globalView.Visible = true
            clientView.Visible = false
        end
    end
    
    local function displayCachedInResults()
        if not resultsFrame then return end
        
        -- Safe clear rows while keeping UIListLayout
        for _, child in ipairs(resultsFrame:GetChildren()) do
            if child:IsA("GuiObject") then child:Destroy() end
        end
        
        local foundAny = false
        for cid, items in pairs(currentCachedInventories) do
            foundAny = true
            for _, item in ipairs(items) do
                local itemRow = Instance.new("Frame", resultsFrame)
                itemRow.Size = UDim2.new(1, 0, 0, 30)
                itemRow.BackgroundTransparency = 1
                
                local nameLbl = Instance.new("TextLabel", itemRow)
                nameLbl.Size = UDim2.new(0.4, 0, 1, 0)
                nameLbl.Text = item.name or "Unknown"
                nameLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
                nameLbl.TextXAlignment = Enum.TextXAlignment.Left
                nameLbl.Font = Enum.Font.Gotham
                nameLbl.TextSize = 13
                nameLbl.BackgroundTransparency = 1
                
                local clientLbl = Instance.new("TextLabel", itemRow)
                clientLbl.Size = UDim2.new(0.3, 0, 1, 0)
                clientLbl.Position = UDim2.new(0.4, 0, 0, 0)
                clientLbl.Text = cid
                clientLbl.TextColor3 = Color3.fromRGB(150, 150, 150)
                clientLbl.Font = Enum.Font.Gotham
                clientLbl.TextSize = 12
                clientLbl.BackgroundTransparency = 1
                
                local qtyLbl = Instance.new("TextLabel", itemRow)
                qtyLbl.Size = UDim2.new(0.3, -5, 1, 0)
                qtyLbl.Position = UDim2.new(0.7, 0, 0, 0)
                qtyLbl.Text = "x" .. (item.quantity or 1)
                qtyLbl.TextColor3 = Color3.fromRGB(100, 255, 100)
                qtyLbl.TextXAlignment = Enum.TextXAlignment.Right
                qtyLbl.Font = Enum.Font.GothamBold
                qtyLbl.TextSize = 13
                qtyLbl.BackgroundTransparency = 1
            end
        end
        
        if not foundAny then
            local empty = Instance.new("TextLabel", resultsFrame)
            empty.Size = UDim2.new(1, 0, 0, 30)
            empty.Text = "No cached inventories. Run a scan."
            empty.TextColor3 = Color3.fromRGB(120, 120, 120)
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 12
            empty.BackgroundTransparency = 1
        end
    end

    local function fetchAll()
        if not networkRequest then return end
        
        task.spawn(function()
            local success, cres = robustRequest({Url = SERVER_URL .. "/clients", Method = "GET"})
            if success and cres.StatusCode == 200 then
                local clientsList = HttpService:JSONDecode(cres.Body)
                for _, child in ipairs(leftPanel:GetChildren()) do
                    if child:IsA("TextButton") then child:Destroy() end
                end
                for _, c in ipairs(clientsList) do
                    local btn = Instance.new("TextButton", leftPanel)
                    btn.Size = UDim2.new(1, -10, 0, 35)
                    btn.BackgroundColor3 = (selectedClientId == c.id) and Color3.fromRGB(100, 150, 255) or Color3.fromRGB(40, 40, 45)
                    btn.Text = c.id .. (c.id == clientId and " (YOU)" or "")
                    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
                    btn.Font = Enum.Font.Gotham
                    btn.TextSize = 12
                    Instance.new("UICorner", btn)
                    btn.MouseButton1Click:Connect(function()
                        selectedClientId = c.id
                        updateViewVisibility()
                        fetchAll() -- Refresh highlght
                    end)
                end
            end
            
            local successI, ires = robustRequest({Url = SERVER_URL .. "/inventories", Method = "GET"})
            if successI and ires.StatusCode == 200 then
                currentCachedInventories = HttpService:JSONDecode(ires.Body)
                displayCachedInResults()
            end
        end)
    end

    -- Event Connections (Permanent)
    searchBtn.MouseButton1Click:Connect(function()
        local query = searchBox.Text
        sendCommand("inventory_report_all " .. query)
        sendNotify("Inventory", "Global scan requested...")
        
        for _, child in ipairs(resultsFrame:GetChildren()) do
            if child:IsA("GuiObject") then child:Destroy() end
        end
        local status = Instance.new("TextLabel", resultsFrame)
        status.Size = UDim2.new(1, 0, 0, 30)
        status.Text = "Broadcasting scan request..."
        status.TextColor3 = Color3.fromRGB(150, 150, 150)
        status.BackgroundTransparency = 1
    end)
    
    dropBtn.MouseButton1Click:Connect(function()
        local name = dropName.Text
        local qty = dropQty.Text
        if name == "" then
            sendNotify("Error", "Please enter an item name")
            return
        end

        sendNotify("Drop", "Click where the soldier should walk to drop")

        -- Clear any previous pending click mode first.
        cancelPendingClick()

        -- DESTROY the Inventory Manager immediately so it doesn't block the screen
        -- and the click doesn't accidentally trigger other UI elements.
        screenGui:Destroy()

        setPendingClick(Mouse.Button1Down:Connect(function()
            if not Mouse.Hit then return end
            cancelPendingClick() -- Stop selecting after one click

            local targetPos = Mouse.Hit.Position
            local coordsStr = string.format("%.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)

            -- If no client is selected (or you selected yourself), do it locally for instant response.
            if (not selectedClientId) or (selectedClientId == clientId) then
                task.spawn(function()
                    sendNotify("Walking", "Local: Moving to drop location...")
                    local reached = walkToUntilWithin(targetPos, 6)
                    if reached then
                        dropItemByName(name, qty)
                    else
                        sendNotify("Drop", "Movement cancelled/interrupted")
                    end
                end)
            else
                -- New command: target_drop_at <clientId> <x,y,z> <name...> <qty>
                sendCommand("target_drop_at " .. selectedClientId .. " " .. coordsStr .. " " .. name .. " " .. qty)
                sendNotify("Inventory", "Order sent to " .. selectedClientId)
            end
        end))
    end)
    
    deselectBtn.MouseButton1Click:Connect(function()
        selectedClientId = nil
        updateViewVisibility()
    end)
    
    refreshBtn.MouseButton1Click:Connect(fetchAll)

    globalDropBtn.MouseButton1Click:Connect(function()
        dropMenu.Visible = true
    end)

    gCancelBtn.MouseButton1Click:Connect(function()
        dropMenu.Visible = false
    end)

    gConfirmBtn.MouseButton1Click:Connect(function()
        local name = gItemInput.Text
        local qty = gQtyInput.Text
        if name == "" then
            sendNotify("Error", "Please enter an item name")
            return
        end

        sendNotify("Global Drop", "Click where ALL soldiers should walk to drop " .. name)
        cancelPendingClick()
        screenGui:Destroy()

        setPendingClick(Mouse.Button1Down:Connect(function()
            if not Mouse.Hit then return end
            cancelPendingClick()

            local targetPos = Mouse.Hit.Position
            local coordsStr = string.format("%.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
            local qtyValue = (qty ~= "" and qty) or "1"

            sendCommand("target_drop_at all " .. coordsStr .. " " .. name .. " " .. qtyValue)
            sendNotify("Global Inventory", "Order sent to ALL soldiers (" .. qtyValue .. "x " .. name .. ")")
        end))
    end)
    
    -- Initial Load
    fetchAll()
    updateViewVisibility()
end

local function performToolbarScan(targetName)
    local toolbarContainer = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("Panels", true)
        and LocalPlayer.PlayerGui.MainGui.Panels:FindFirstChild("Toolbar", true)
        and LocalPlayer.PlayerGui.MainGui.Panels.Toolbar:FindFirstChild("Container", true)
        
    local toolbarTitle = toolbarContainer and toolbarContainer:FindFirstChild("Title", true)

    if not toolbarTitle then
        warn("[SCAN] Toolbar Title UI not found")
        return nil
    end

    for slot = 1, 6 do
        fireEquip(slot)
        task.wait(0.6) -- Original speed for stability
        
        local currentText = toolbarTitle.Text:lower()
        if currentText:find(targetName, 1, true) then
            print("[SCAN] Successfully equipped in toolbar slot " .. slot)
            return slot
        end
    end
    return nil
end

scanAndEquip = function(toolName)
    if not toolName or toolName == "" then return end
    print("[SCAN] Starting sync for tool: " .. toolName)
    
    local targetName = toolName:lower()
    
    -- Clear current title at start of flow for fresh verification
    local toolbarContainer = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("Panels", true)
        and LocalPlayer.PlayerGui.MainGui.Panels:FindFirstChild("Toolbar", true)
        and LocalPlayer.PlayerGui.MainGui.Panels.Toolbar:FindFirstChild("Container", true)
    local toolbarTitle = toolbarContainer and toolbarContainer:FindFirstChild("Title", true)
    if toolbarTitle then toolbarTitle.Text = "" end

    -- Phase 1: Search Inventory FIRST
    print("[SCAN] Phase 1: Searching Inventory for: " .. toolName)
    local inventoryList = LocalPlayer.PlayerGui:FindFirstChild("MainGui", true)
        and LocalPlayer.PlayerGui.MainGui:FindFirstChild("RightPanel", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel:FindFirstChild("Inventory", true)
        and LocalPlayer.PlayerGui.MainGui.RightPanel.Inventory:FindFirstChild("List", true)

    if inventoryList then
        for _, item in ipairs(inventoryList:GetChildren()) do
            if item:IsA("GuiObject") and item.Name:lower():find(targetName, 1, true) then
                local order = item.LayoutOrder
                print("[SCAN] Found in Inventory! Order: " .. order .. ". Firing UseBagItem Remote (43)")
                fireInventoryUse(order)
                
                -- Wait 2 seconds and verify it's now in the toolbar
                print("[SCAN] Waiting 2s for inventory -> toolbar move...")
                task.wait(2)
                print("[SCAN] Verifying toolbar placement...")
                local verifiedSlot = performToolbarScan(targetName)
                if verifiedSlot then
                    print("[SCAN] Verification success: Tool now in slot " .. verifiedSlot)
                    return true
                else
                    print("[SCAN] Verification failed: Tool not found in toolbar after use")
                end
                -- Fallthrough to toolbar scan if inventory use didn't result in equip
            end
        end
    end

    -- Phase 2: Scan Toolbar (Slots 1-6)
    print("[SCAN] Phase 2: Scanning Toolbar slots...")
    local foundSlot = performToolbarScan(targetName)
    if foundSlot then
        return true
    end
    
    print("[SCAN] Failed to find " .. toolName .. " anywhere")
    return false
end
local function showToolSearchDialog()
    local coreGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not coreGui then return end
    
    local dialog = Instance.new("ScreenGui", coreGui)
    dialog.Name = "ArmySearchDialog"
    
    local frame = Instance.new("Frame", dialog)
    frame.Size = UDim2.new(0, 300, 0, 150)
    frame.Position = UDim2.new(0.5, -150, 0.5, -75)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    frame.BorderSizePixel = 0
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    Instance.new("UIStroke", frame).Color = Color3.fromRGB(60, 60, 70)
    
    local title = Instance.new("TextLabel", frame)
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Text = "Equip Tool for Army"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.BackgroundTransparency = 1
    
    local input = Instance.new("TextBox", frame)
    input.Size = UDim2.new(0.8, 0, 0, 35)
    input.Position = UDim2.new(0.1, 0, 0.35, 0)
    input.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    input.Text = ""
    input.PlaceholderText = "Enter tool name (e.g. WOOD HOE)"
    input.TextColor3 = Color3.fromRGB(255, 255, 255)
    input.TextSize = 14
    input.Font = Enum.Font.Gotham
    Instance.new("UICorner", input).CornerRadius = UDim.new(0, 6)
    
    local confirm = Instance.new("TextButton", frame)
    confirm.Size = UDim2.new(0.35, 0, 0, 30)
    confirm.Position = UDim2.new(0.1, 0, 0.7, 0)
    confirm.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
    confirm.Text = "Search"
    confirm.TextColor3 = Color3.fromRGB(255, 255, 255)
    confirm.Font = Enum.Font.GothamBold
    Instance.new("UICorner", confirm).CornerRadius = UDim.new(0, 6)
    
    local cancel = Instance.new("TextButton", frame)
    cancel.Size = UDim2.new(0.35, 0, 0, 30)
    cancel.Position = UDim2.new(0.55, 0, 0.7, 0)
    cancel.BackgroundColor3 = Color3.fromRGB(200, 100, 100)
    cancel.Text = "Cancel"
    cancel.TextColor3 = Color3.fromRGB(255, 255, 255)
    cancel.Font = Enum.Font.GothamBold
    Instance.new("UICorner", cancel).CornerRadius = UDim.new(0, 6)
    
    confirm.MouseButton1Click:Connect(function()
        local toolName = input.Text
        if toolName ~= "" then
            sendCommand("sync_equip " .. toolName)
            sendNotify("Army Sync", "Soldiers searching for " .. toolName)
        end
        dialog:Destroy()
    end)
    
    cancel.MouseButton1Click:Connect(function()
        dialog:Destroy()
    end)
end

local function showPrepareFinishGUI()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyPrepareFinish") then
        pg.ArmyPrepareFinish:Destroy()
    end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyPrepareFinish"
    screenGui.ResetOnSpawn = false
    
    local btn = Instance.new("TextButton", screenGui)
    btn.Size = UDim2.new(0, 180, 0, 40)
    btn.Position = UDim2.new(0.5, -90, 0.8, 0)
    btn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
    btn.Text = "Finish Preparing"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 14
    Instance.new("UICorner", btn)
    Instance.new("UIStroke", btn).Color = Color3.fromRGB(80, 80, 90)
    
    btn.MouseButton1Click:Connect(function()
        -- Stop locally immediately, then broadcast cancel so soldiers stop too.
        stopPrepare()
        sendCommand("cancel")
        screenGui:Destroy()
    end)
end

local function showPrepareDialog()
    local coreGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not coreGui then return end
    
    local dialog = Instance.new("ScreenGui", coreGui)
    dialog.Name = "ArmyPrepareDialog"
    
    local frame = Instance.new("Frame", dialog)
    frame.Size = UDim2.new(0, 300, 0, 150)
    frame.Position = UDim2.new(0.5, -150, 0.5, -75)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    frame.BorderSizePixel = 0
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    Instance.new("UIStroke", frame).Color = Color3.fromRGB(60, 60, 70)
    
    local title = Instance.new("TextLabel", frame)
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Text = "Prepare Army Tool"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.BackgroundTransparency = 1
    
    local input = Instance.new("TextBox", frame)
    input.Size = UDim2.new(0.8, 0, 0, 35)
    input.Position = UDim2.new(0.1, 0, 0.35, 0)
    input.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    input.Text = ""
    input.PlaceholderText = "Tool Name (e.g. Wood Hoe)"
    input.TextColor3 = Color3.fromRGB(255, 255, 255)
    input.TextSize = 14
    input.Font = Enum.Font.Gotham
    Instance.new("UICorner", input).CornerRadius = UDim.new(0, 6)
    
    local confirm = Instance.new("TextButton", frame)
    confirm.Size = UDim2.new(0.35, 0, 0, 30)
    confirm.Position = UDim2.new(0.1, 0, 0.7, 0)
    confirm.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
    confirm.Text = "OK"
    confirm.TextColor3 = Color3.fromRGB(255, 255, 255)
    confirm.Font = Enum.Font.GothamBold
    Instance.new("UICorner", confirm).CornerRadius = UDim.new(0, 6)
    
    local cancel = Instance.new("TextButton", frame)
    cancel.Size = UDim2.new(0.35, 0, 0, 30)
    cancel.Position = UDim2.new(0.55, 0, 0.7, 0)
    cancel.BackgroundColor3 = Color3.fromRGB(100, 100, 110)
    cancel.Text = "Cancel"
    cancel.TextColor3 = Color3.fromRGB(255, 255, 255)
    cancel.Font = Enum.Font.GothamBold
    Instance.new("UICorner", cancel).CornerRadius = UDim.new(0, 6)
    
    confirm.MouseButton1Click:Connect(function()
        local itemName = input.Text
        if itemName ~= "" then
            dialog:Destroy()
            
            sendNotify("Prepare", "Select Pos 1: Have the tool")
            setPendingClick(Mouse.Button1Down:Connect(function()
                if Mouse.Hit then
                    local p1 = Mouse.Hit.Position
                    cancelPendingClick()
                    
                    task.wait(0.2)
                    sendNotify("Prepare", "Select Pos 2: Don't have it")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local p2 = Mouse.Hit.Position
                            cancelPendingClick()
                            
                            local cmd = string.format("prepare_tool %s %.1f,%.1f,%.1f %.1f,%.1f,%.1f",
                                itemName, p1.X, p1.Y, p1.Z, p2.X, p2.Y, p2.Z)
                            sendCommand(cmd)
                            sendNotify("Prepare", "Enforcing: " .. itemName)
                            showPrepareFinishGUI()
                        end
                    end), nil)
                end
            end), nil)
        else
            dialog:Destroy()
        end
    end)
    
    cancel.MouseButton1Click:Connect(function()
        dialog:Destroy()
    end)
end

terminateScript = function()
    isRunning = false
    sendNotify("Army Script", "Script Terminated")

    -- Stop any ongoing behaviors immediately (even if connections are about to be disconnected).
    stopMoveTween()
    stopFollowTween()
    toggleClicking(false)
    cancelPendingClick()
    stopFollowing()
    stopGotoWalk()
    moveTarget = nil

    -- Best-effort: close auxiliary UI(s) created by this script.
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local inv = pg and pg:FindFirstChild("ArmyInventoryManager")
        if inv then inv:Destroy() end
        local dlg = pg and pg:FindFirstChild("ArmySearchDialog")
        if dlg then dlg:Destroy() end
        local pkm = pg and pg:FindFirstChild("ArmyPickupManager")
        if pkm then pkm:Destroy() end
        local tlm = pg and pg:FindFirstChild("ArmyToolsMenu")
        if tlm then tlm:Destroy() end
        local frm = pg and pg:FindFirstChild("ArmyFarmMenu")
        if frm then frm:Destroy() end
        local rtm = pg and pg:FindFirstChild("ArmyRouteManager")
        if rtm then rtm:Destroy() end
        local rte = pg and pg:FindFirstChild("ArmyRouteEditor")
        if rte then rte:Destroy() end
        local pfn = pg and pg:FindFirstChild("ArmyPrepareFinish")
        if pfn then pfn:Destroy() end
    end)

    for _, conn in ipairs(connections) do
        if conn then conn:Disconnect() end
    end
    if panelGui then 
        panelGui:Destroy()
        panelGui = nil
    end
    isPanelOpen = false
    isCommander = false

    if infJumpConnection then
        infJumpConnection:Disconnect()
        infJumpConnection = nil
    end

    -- Close WebSocket gracefully
    if activeWS then
        pcall(function()
            activeWS:Send(HttpService:JSONEncode({
                type = "unregister",
                clientId = clientId
            }))
            task.wait(0.1)
            activeWS:Close()
        end)
        activeWS = nil
    end
end


local function showPickupManager()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyPickupManager") then
        pg.ArmyPickupManager:Destroy()
    end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyPickupManager"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 300, 0, 400)
    panel.Position = UDim2.new(0.5, -150, 0.5, -200)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "PICKUP MANAGER"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local content = Instance.new("ScrollingFrame", panel)
    content.Size = UDim2.new(1, -20, 1, -110)
    content.Position = UDim2.new(0, 10, 0, 60)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 4
    content.CanvasSize = UDim2.new(0, 0, 0, 0)
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    
    local list = Instance.new("UIListLayout", content)
    list.Padding = UDim.new(0, 5)
    
    local toggleBtn = Instance.new("TextButton", panel)
    toggleBtn.Size = UDim2.new(1, -20, 0, 40)
    toggleBtn.Position = UDim2.new(0, 10, 1, -95)
    toggleBtn.BackgroundColor3 = serverConfigs.auto_pickup and Color3.fromRGB(50, 150, 50) or Color3.fromRGB(150, 50, 50)
    toggleBtn.Text = "AUTO PICKUP: " .. (serverConfigs.auto_pickup and "ON" or "OFF")
    toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggleBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", toggleBtn)
    
    toggleBtn.MouseButton1Click:Connect(function()
        local newState = not serverConfigs.auto_pickup
        if updateServerConfig({ auto_pickup = newState }) then
            toggleBtn.BackgroundColor3 = newState and Color3.fromRGB(50, 150, 50) or Color3.fromRGB(150, 50, 50)
            toggleBtn.Text = "AUTO PICKUP: " .. (newState and "ON" or "OFF")
        end
    end)
    
    local inputFrame = Instance.new("Frame", panel)
    inputFrame.Size = UDim2.new(1, -20, 0, 35)
    inputFrame.Position = UDim2.new(0, 10, 1, -45)
    inputFrame.BackgroundTransparency = 1
    
    local input = Instance.new("TextBox", inputFrame)
    input.Size = UDim2.new(1, -45, 1, 0)
    input.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    input.BorderSizePixel = 0
    input.Text = ""
    input.PlaceholderText = "Add item to whitelist..."
    input.TextColor3 = Color3.fromRGB(255, 255, 255)
    input.TextSize = 13
    input.Font = Enum.Font.Gotham
    Instance.new("UICorner", input)
    
    local add = Instance.new("TextButton", inputFrame)
    add.Size = UDim2.new(0, 35, 1, 0)
    add.Position = UDim2.new(1, -35, 0, 0)
    add.BackgroundColor3 = Color3.fromRGB(100, 200, 255)
    add.Text = "+"
    add.TextColor3 = Color3.fromRGB(255, 255, 255)
    add.TextSize = 20
    add.Font = Enum.Font.GothamBold
    Instance.new("UICorner", add)
    
    local function refreshWhitelist()
        for _, child in ipairs(content:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        
        for i, name in ipairs(serverConfigs.pickup_whitelist) do
            local item = Instance.new("Frame", content)
            item.Size = UDim2.new(1, 0, 0, 30)
            item.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
            item.BorderSizePixel = 0
            Instance.new("UICorner", item)
            
            local label = Instance.new("TextLabel", item)
            label.Size = UDim2.new(1, -40, 1, 0)
            label.Position = UDim2.new(0, 10, 0, 0)
            label.BackgroundTransparency = 1
            label.Text = name
            label.TextColor3 = Color3.fromRGB(220, 220, 220)
            label.TextSize = 12
            label.Font = Enum.Font.Gotham
            label.TextXAlignment = Enum.TextXAlignment.Left
            
            local rm = Instance.new("TextButton", item)
            rm.Size = UDim2.new(0, 24, 0, 24)
            rm.Position = UDim2.new(1, -27, 0, 3)
            rm.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
            rm.Text = "-"
            rm.TextColor3 = Color3.fromRGB(255, 255, 255)
            rm.TextSize = 16
            rm.Font = Enum.Font.GothamBold
            Instance.new("UICorner", rm)
            
            rm.MouseButton1Click:Connect(function()
                local newList = {}
                for idx, val in ipairs(serverConfigs.pickup_whitelist) do
                    if idx ~= i then table.insert(newList, val) end
                end
                if updateServerConfig({ pickup_whitelist = newList }) then
                    refreshWhitelist()
                end
            end)
        end
    end
    
    add.MouseButton1Click:Connect(function()
        if input.Text ~= "" then
            local newList = {}
            for _, v in ipairs(serverConfigs.pickup_whitelist) do table.insert(newList, v) end
            table.insert(newList, input.Text)
            if updateServerConfig({ pickup_whitelist = newList }) then
                input.Text = ""
                refreshWhitelist()
            end
        end
    end)
    
    refreshWhitelist()
end

startFarmingTarget = function(targetPos, targetId)
    stopFarming()
    local myToken = farmToken
    isFarming = true
    
    task.spawn(function()

        local function findTarget()
            -- Spatial search at the target position (radius 4)
            local overlapParams = OverlapParams.new()
            overlapParams.FilterDescendantsInstances = {LocalPlayer.Character}
            overlapParams.FilterType = Enum.RaycastFilterType.Exclude

            local parts = workspace:GetPartBoundsInRadius(targetPos, 4, overlapParams)
            print("[TARGET] Search at", targetPos, "Hit Parts:", #parts)

            for _, part in ipairs(parts) do
                local current = part
                -- Walk up up to 10 levels to find the entity container
                local depth = 0
                while current and current ~= workspace and depth < 10 do
                    local eid = current:GetAttribute("EntityID")
                    if eid then
                        -- STRICT CHECK: If a specific targetId was requested, we MUST match it.
                        if targetId and eid ~= targetId then
                            print("[TARGET] Skipping Entity (ID mismatch):", eid, "Expected:", targetId)
                        else
                            if current:IsA("Model") then
                                print("[TARGET] Found Valid Target (Model):", current.Name, "ID:", eid)
                                return current
                            else
                                print("[TARGET] Found EntityID but not a Model:", current.Name, "Class:", current.ClassName)
                            end
                        end
                    end
                    current = current.Parent
                    depth = depth + 1
                end
            end
            print("[TARGET] No valid target found in radius")
            return nil
        end
        
        local targetObject = findTarget()
        if not targetObject then
            sendNotify("Farm", "Target not found at position")
            isFarming = false
            return
        end
        
        local swingDelay = 0.05
        local lastSwing = 0
        local lastMoveToCall = 0
        
        while isRunning and myToken == farmToken do
            if not targetObject or not targetObject.Parent then
                targetObject = findTarget()
                if not targetObject then break end
            end
            
            local char, humanoid, root = getMyRig()
            if not (char and root) then break end
            
            local currentPos = root.Position
            local targetPart = targetObject:IsA("BasePart") and targetObject or (targetObject:IsA("Model") and targetObject.PrimaryPart)
            if not targetPart then break end
            
            local edgePoint = findEdgePointRaycast(targetObject, currentPos)
            local dist2D = (Vector2.new(currentPos.X, currentPos.Z) - Vector2.new(edgePoint.X, edgePoint.Z)).Magnitude
            
            if dist2D > 10 then
                -- Only call walkTo if we aren't already moving there or periodically to refresh
                if moveTarget ~= edgePoint or os.clock() - lastMoveToCall > 2 then
                    lastMoveToCall = os.clock()
                    Movement.walkTo(edgePoint)
                end
            else
                -- In range, stop moving and hit
                if moveTarget then
                    stopGotoWalk()
                end
                
                -- Look at the target
                root.CFrame = CFrame.new(root.Position, Vector3.new(edgePoint.X, root.Position.Y, edgePoint.Z))
                
                if os.clock() - lastSwing >= swingDelay then
                    local entityID = targetObject:GetAttribute("EntityID")
                    if entityID and PacketIds.SwingTool then
                        fireAction(PacketIds.SwingTool, entityID)
                        lastSwing = os.clock()
                    end
                end
            end
            task.wait()
        end
        
        if myToken == farmToken then
            isFarming = false
            stopGotoWalk()
        end
    end)
end

startFarmingList = function(targetIds)
    stopFarming()
    local myToken = farmToken
    isFarming = true
    
    task.spawn(function()
        for _, id in ipairs(targetIds) do
            if not isFarming or myToken ~= farmToken then break end
            
            -- Find the target object first to get its position
            local targetObject = nil
            -- We need a way to find object by ID globally or assume it's streamed in.
            -- We can reuse the findTarget logic but we need to search broadly.
            -- For now, we rely on the soldier searching when they get the command.
            -- Actually, startFarmingTarget takes a pos... we might need the pos for each target.
            -- The protocol `farm_targets_list` should probably ideally accept positions too, 
            -- OR the soldier just searches the whole relevant workspace for that ID.
            
            -- Since the user only mentioned sending IDs in the list ("farm_targets_list id1,id2"),
            -- we have to find the object by ID.
            -- We can scan the known resource folders.
            
            local function findObjectById(eid)
                local searchLocations = {
                    workspace, -- Direct children
                    workspace:FindFirstChild("Resources"),
                    workspace:FindFirstChild("Critters"),
                    workspace:FindFirstChild("Totems"),
                    workspace:FindFirstChild("ScavengerMounds"),
                    workspace:FindFirstChild("Mounds"),
                    workspace:FindFirstChild("Deployables")
                }
                for _, container in ipairs(searchLocations) do
                    if container then
                        for _, child in ipairs(container:GetChildren()) do
                            if child:GetAttribute("EntityID") == eid then
                                return child
                            end
                        end
                    end
                end
                return nil
            end
            
            local target = findObjectById(id)
            if target then
                local pos = target:IsA("BasePart") and target.Position or (target:IsA("Model") and target.PrimaryPart and target.PrimaryPart.Position)
                if pos then
                    -- Execute single target farm
                    -- We need to wait for it to finish. startFarmingTarget is async/spawned.
                    -- We need to refactor startFarmingTarget to be yieldable or just check status.
                    
                    -- HACK: We will just set the target and monitor it here instead of calling startFarmingTarget directly
                    -- actually duplicating logic is bad. 
                    -- Let's change startFarmingTarget to yield if requested? No, it spawns.
                    
                    -- Let's just wait until the target is gone or we are told to stop.
                    print("[FARM LIST] Starting target:", id)
                    
                    targetPos = pos -- Update global targetPos if used elsewhere? 
                    -- Actually startFarmingTarget takes pos as arg.
                    
                    -- We will run the farming logic for this target.
                    -- To avoid code duplication, we can wrap startFarmingTarget's inner logic
                    -- but for now, let's just make startFarmingTarget waitable? 
                    -- Or simpler: Just loop here.
                    
                    local swingDelay = 0.05
                    local lastSwing = 0
                    local lastMoveToCall = 0
                    
                    while isFarming and myToken == farmToken and target.Parent do
                        local char, humanoid, root = getMyRig()
                        if not (char and root) then break end
                        
                        local current = target -- verify it still exists
                        local currentPos = root.Position
                        local targetPart = current:IsA("BasePart") and current or (current:IsA("Model") and current.PrimaryPart)
                        if not targetPart then break end
                        
                        -- Simple distance check
                        local dist = (root.Position - targetPart.Position).Magnitude
                        
                        if dist > 10 then
                            if os.clock() - lastMoveToCall > 1 then
                                lastMoveToCall = os.clock()
                                Movement.walkTo(targetPart.Position)
                            end
                        else
                            stopGotoWalk()
                            -- Look and Swing
                            root.CFrame = CFrame.new(root.Position, Vector3.new(targetPart.Position.X, root.Position.Y, targetPart.Position.Z))
                            
                            if os.clock() - lastSwing >= swingDelay then
                                fireAction(PacketIds.SwingTool, id)
                                lastSwing = os.clock()
                            end
                        end
                        task.wait()
                    end
                    print("[FARM LIST] Finished target:", id)
                end
            else
                print("[FARM LIST] Could not find object with ID:", id)
            end
        end
        isFarming = false
        stopGotoWalk()
    end)
end



local function showFarmMenu()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyFarmMenu") then
        pg.ArmyFarmMenu:Destroy()
    end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyFarmMenu"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 250, 0, 150)
    panel.Position = UDim2.new(0.5, -125, 0.5, -75)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 45)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -50, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "FARM MANAGER"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 7)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local targetBtn = Instance.new("TextButton", panel)
    targetBtn.Size = UDim2.new(1, -20, 0, 40)
    targetBtn.Position = UDim2.new(0, 10, 0, 60)
    targetBtn.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    targetBtn.Text = "Target"
    targetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    targetBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", targetBtn)
    
    targetBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
        
        local selectedTargets = {} -- Set of ID -> Model
        local highlights = {} -- Set of ID -> Highlight Instance
        local isAltHeld = false
        local connection = nil
        local inputBegan = nil
        local inputEnded = nil

        local function cleanup()
            if connection then connection:Disconnect() end
            if inputBegan then inputBegan:Disconnect() end
            if inputEnded then inputEnded:Disconnect() end
            if pendingClickConnection then pendingClickConnection:Disconnect() end
            pendingClickConnection = nil
            
            for _, hl in pairs(highlights) do
                hl:Destroy()
            end
            highlights = {}
            selectedTargets = {}
        end
        
        sendNotify("Farm", "Target Mode: Click to select single, HOLD ALT to select multiple.")

        -- Track Alt Key
        inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
            if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
                isAltHeld = true
            end
        end)
        
        inputEnded = UserInputService.InputEnded:Connect(function(input, processed)
            if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
                isAltHeld = false
                
                -- ALT RELEASED: Send aggregated list if we have any
                local idList = {}
                for id, _ in pairs(selectedTargets) do
                    table.insert(idList, id)
                end
                
                if #idList > 0 then
                    local cmd = table.concat(idList, ",")
                    sendCommand("farm_targets_list " .. cmd)
                    sendNotify("Farm", "Sent " .. #idList .. " targets via List")
                end
                
                -- Clear selection after sending
                cleanup()
            end
        end)
        
        -- Mouse Click Handler
        connection = Mouse.Button1Down:Connect(function()
            local target = Mouse.Target
            if target and not target:IsA("Terrain") then
                -- Find valid Model target
                local resourceModel = nil
                local current = target
                while current and current ~= workspace do
                    if current:GetAttribute("EntityID") and current:IsA("Model") then
                        resourceModel = current
                        break
                    end
                    current = current.Parent
                end
                
                if resourceModel then
                    local eid = resourceModel:GetAttribute("EntityID")
                    
                    if isAltHeld then
                        -- Toggle selection
                        if selectedTargets[eid] then
                            -- Deselect
                            selectedTargets[eid] = nil
                            if highlights[eid] then
                                highlights[eid]:Destroy()
                                highlights[eid] = nil
                            end
                            -- sendNotify("Farm", "Deselected: " .. resourceModel.Name)
                        else
                            -- Select
                            selectedTargets[eid] = resourceModel
                            
                            local hl = Instance.new("Highlight")
                            hl.FillColor = Color3.fromRGB(255, 0, 0)
                            hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                            hl.FillTransparency = 0.5
                            hl.OutlineTransparency = 0
                            hl.Parent = resourceModel
                            highlights[eid] = hl
                            
                            -- sendNotify("Farm", "Selected: " .. resourceModel.Name)
                        end
                    else
                        -- No Alt: Normal Single Target Behavior (Immediate Send)
                        local targetPos = resourceModel:IsA("BasePart") and resourceModel.Position or (resourceModel.PrimaryPart and resourceModel.PrimaryPart.Position) or target.Position
                        
                        -- Clear any existing multi-selection just in case
                        cleanup() 
                        
                        sendCommand(string.format("farm_target %.2f,%.2f,%.2f,%d", targetPos.X, targetPos.Y, targetPos.Z, eid))
                        sendNotify("Farm", "Targeting Single: " .. resourceModel.Name .. " (ID: " .. eid .. ")")
                        -- cleanup() handles disconnection so we don't double click
                    end
                else
                    sendNotify("Farm", "Invalid target (No Model entity)")
                    if not isAltHeld then cleanup() end
                end
            end
        end)
        
        -- Assign to global pendingClickConnection so other UI actions cancel it properly
        setPendingClick(connection, function()
             -- Custom cleanup callback not needed as we handle it internally, but good for safety
             if inputBegan then inputBegan:Disconnect() end
             if inputEnded then inputEnded:Disconnect() end
             for _, hl in pairs(highlights) do hl:Destroy() end
        end)
    end)
end

local function showToolsMenu()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyToolsMenu") then
        pg.ArmyToolsMenu:Destroy()
    end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyToolsMenu"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 250, 0, 230)
    panel.Position = UDim2.new(0.5, -125, 0.5, -115)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 45)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -50, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "TOOLS"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 7)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local equipBtn = Instance.new("TextButton", panel)
    equipBtn.Size = UDim2.new(1, -20, 0, 40)
    equipBtn.Position = UDim2.new(0, 10, 0, 60)
    equipBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 255)
    equipBtn.Text = "Equip Tool"
    equipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    equipBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", equipBtn)
    equipBtn.MouseButton1Click:Connect(function() 
        screenGui:Destroy()
        showToolSearchDialog() 
    end)

    local prepareBtn = Instance.new("TextButton", panel)
    prepareBtn.Size = UDim2.new(1, -20, 0, 40)
    prepareBtn.Position = UDim2.new(0, 10, 0, 110)
    prepareBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
    prepareBtn.Text = "Prepare Tool"
    prepareBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    prepareBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", prepareBtn)
    prepareBtn.MouseButton1Click:Connect(function() 
        screenGui:Destroy()
        showPrepareDialog() 
    end)
    
    local unequipBtn = Instance.new("TextButton", panel)
    unequipBtn.Size = UDim2.new(1, -20, 0, 40)
    unequipBtn.Position = UDim2.new(0, 10, 0, 160)
    unequipBtn.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
    unequipBtn.Text = "Unequip Tools"
    unequipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    unequipBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", unequipBtn)
    unequipBtn.MouseButton1Click:Connect(function() 
        screenGui:Destroy()
        sendCommand("unequip_all")
        sendNotify("Equip", "Army clearing toolbar to inventory")
    end)
end

local function showRouteEditor(routeName)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyRouteEditor"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 300, 0, 400)
    panel.Position = UDim2.new(0.5, -150, 0.5, -200)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -100, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    local currentRouteName = tostring(routeName or "")
    title.Text = "NEW ROUTE: " .. string.upper(currentRouteName)
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 14
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() 
        screenGui:Destroy() 
        showRouteManager()
    end)

    -- Route name input (lets you override the auto "Route N" name).
    local nameBox = Instance.new("TextBox", panel)
    nameBox.Size = UDim2.new(1, -20, 0, 30)
    nameBox.Position = UDim2.new(0, 10, 0, 60)
    nameBox.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
    nameBox.BorderSizePixel = 0
    nameBox.Text = currentRouteName
    nameBox.PlaceholderText = "Route name"
    nameBox.TextColor3 = Color3.fromRGB(235, 235, 235)
    nameBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
    nameBox.TextSize = 13
    nameBox.Font = Enum.Font.GothamSemibold
    Instance.new("UICorner", nameBox)

    local function commitRouteName()
        local txt = tostring(nameBox.Text or "")
        txt = txt:gsub("^%s+", ""):gsub("%s+$", "")
        -- Keep a sane default if the user clears the field.
        if txt == "" then
            txt = tostring(routeName or "Route")
        end
        -- Prevent extremely long names from blowing up UI and URLs.
        if #txt > 48 then
            txt = string.sub(txt, 1, 48)
        end
        currentRouteName = txt
        nameBox.Text = currentRouteName
        title.Text = "NEW ROUTE: " .. string.upper(currentRouteName)
    end

    nameBox.FocusLost:Connect(function()
        commitRouteName()
    end)

    local content = Instance.new("ScrollingFrame", panel)
    -- Push content down to make room for the nameBox.
    content.Size = UDim2.new(1, -20, 1, -170)
    content.Position = UDim2.new(0, 10, 0, 100)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 2
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    
    local list = Instance.new("UIListLayout", content)
    list.Padding = UDim.new(0, 5)
    
    local waypoints = {}
    local currentAutoJump = true
    
    local function refreshList()
        for _, child in ipairs(content:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        for i, wp in ipairs(waypoints) do
            local f = Instance.new("Frame", content)
            f.Size = UDim2.new(1, 0, 0, 25)
            f.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
            f.BorderSizePixel = 0
            Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)
            
            local l = Instance.new("TextLabel", f)
            l.Size = UDim2.new(1, -10, 1, 0)
            l.Position = UDim2.new(0, 10, 0, 0)
            l.BackgroundTransparency = 1
            l.Text = string.format("%d. (%.1f, %.1f, %.1f) | Jump: %s", i, wp.pos.x, wp.pos.y, wp.pos.z, tostring(wp.autoJump))
            l.TextColor3 = Color3.fromRGB(180, 180, 180)
            l.TextSize = 11
            l.Font = Enum.Font.Gotham
            l.TextXAlignment = Enum.TextXAlignment.Left
        end
    end
    
    local jumpToggle = Instance.new("TextButton", panel)
    jumpToggle.Size = UDim2.new(1, -20, 0, 30)
    jumpToggle.Position = UDim2.new(0, 10, 1, -110)
    jumpToggle.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
    jumpToggle.Text = "AutoJump: ON"
    jumpToggle.TextColor3 = Color3.fromRGB(100, 255, 150)
    jumpToggle.Font = Enum.Font.GothamBold
    Instance.new("UICorner", jumpToggle)
    
    jumpToggle.MouseButton1Click:Connect(function()
        currentAutoJump = not currentAutoJump
        jumpToggle.Text = "AutoJump: " .. (currentAutoJump and "ON" or "OFF")
        jumpToggle.TextColor3 = currentAutoJump and Color3.fromRGB(100, 255, 150) or Color3.fromRGB(255, 100, 100)
    end)
    
    local setBtn = Instance.new("TextButton", panel)
    setBtn.Size = UDim2.new(0.48, 0, 0, 35)
    setBtn.Position = UDim2.new(0, 10, 1, -70)
    setBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 255)
    setBtn.Text = "Set Point"
    setBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    setBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", setBtn)
    
    setBtn.MouseButton1Click:Connect(function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            local pos = root.Position
            table.insert(waypoints, {
                pos = {x = pos.X, y = pos.Y, z = pos.Z},
                autoJump = currentAutoJump
            })
            refreshList()
        end
    end)
    
    local saveBtn = Instance.new("TextButton", panel)
    saveBtn.Size = UDim2.new(0.48, 0, 0, 35)
    saveBtn.Position = UDim2.new(0.52, 0, 1, -70)
    saveBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
    saveBtn.Text = "Save Route"
    saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    saveBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", saveBtn)
    
    saveBtn.MouseButton1Click:Connect(function()
        commitRouteName()
        if #waypoints > 0 then
            if not currentRouteName or currentRouteName == "" then
                sendNotify("Error", "Please name the route")
                return
            end
            savedRoutes[currentRouteName] = { waypoints = waypoints }
            syncSaveRoute(currentRouteName, waypoints)
            screenGui:Destroy()
            showRouteManager()
        else
            sendNotify("Error", "Route needs at least 1 point")
        end
    end)
    
    local clearBtn = Instance.new("TextButton", panel)
    clearBtn.Size = UDim2.new(1, -20, 0, 25)
    clearBtn.Position = UDim2.new(0, 10, 1, -30)
    clearBtn.BackgroundTransparency = 1
    clearBtn.Text = "Cancel & Back"
    clearBtn.TextColor3 = Color3.fromRGB(150, 150, 160)
    clearBtn.TextSize = 12
    clearBtn.Font = Enum.Font.Gotham
    clearBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
        showRouteManager()
    end)
end

showRouteManager = function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyRouteManager") then pg.ArmyRouteManager:Destroy() end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyRouteManager"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 320, 0, 350)
    panel.Position = UDim2.new(0.5, -160, 0.5, -175)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -100, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "ROUTE MANAGER"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local addBtn = Instance.new("TextButton", header)
    addBtn.Size = UDim2.new(0, 35, 0, 35)
    addBtn.Position = UDim2.new(1, -80, 0, 7)
    addBtn.BackgroundColor3 = Color3.fromRGB(100, 255, 150)
    addBtn.Text = "+"
    addBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    addBtn.TextSize = 24
    addBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", addBtn)
    
    addBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
        -- Pick a deterministic next "Route N" name instead of a time-based value.
        local maxN = 0
        for existingName, _ in pairs(savedRoutes) do
            local n = tonumber(string.match(existingName, "^Route%s+(%d+)$"))
            if n and n > maxN then
                maxN = n
            end
        end
        local nextName = "Route " .. tostring(maxN + 1)
        showRouteEditor(nextName)
    end)
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local content = Instance.new("ScrollingFrame", panel)
    content.Size = UDim2.new(1, -20, 1, -60)
    content.Position = UDim2.new(0, 10, 0, 60)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 4
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    
    local list = Instance.new("UIListLayout", content)
    list.Padding = UDim.new(0, 10)
    
    local function refreshRoutes()
        for _, child in ipairs(content:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        
        local any = false
        -- `pairs()` iteration order is unspecified, so sort route names for a stable ascending list.
        local routeNames = {}
        for routeName, _ in pairs(savedRoutes) do
            table.insert(routeNames, routeName)
        end
        table.sort(routeNames, function(a, b)
            local na = tonumber(string.match(a, "^Route%s+(%d+)$"))
            local nb = tonumber(string.match(b, "^Route%s+(%d+)$"))
            if na and nb then
                return na < nb
            end
            if na and not nb then
                return true
            end
            if not na and nb then
                return false
            end
            return tostring(a):lower() < tostring(b):lower()
        end)

        for _, name in ipairs(routeNames) do
            local data = savedRoutes[name]
            if data then
                -- Capture loop vars; Luau closures otherwise see the final loop values.
                local routeName = name
                local routeData = data
            any = true
            local row = Instance.new("Frame", content)
            row.Size = UDim2.new(1, 0, 0, 50)
            row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
            Instance.new("UICorner", row)
            
            local l = Instance.new("TextLabel", row)
             l.Size = UDim2.new(1, -120, 1, 0)
             l.Position = UDim2.new(0, 10, 0, 0)
             l.BackgroundTransparency = 1
             l.Text = routeName .. " (" .. #routeData.waypoints .. " pts)"
             l.TextColor3 = Color3.fromRGB(220, 220, 220)
             l.TextSize = 13
             l.Font = Enum.Font.GothamSemibold
             l.TextXAlignment = Enum.TextXAlignment.Left
            
            local play = Instance.new("TextButton", row)
            play.Size = UDim2.new(0, 50, 0, 30)
            play.Position = UDim2.new(1, -100, 0.5, -15)
            play.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
            play.Text = "Play"
            play.TextColor3 = Color3.fromRGB(255, 255, 255)
            play.Font = Enum.Font.GothamBold
            Instance.new("UICorner", play)
            
            play.MouseButton1Click:Connect(function()
                local json = HttpService:JSONEncode({ waypoints = routeData.waypoints })
                sendCommand("execute_route " .. json)
                sendNotify("Route", "Broadcasting route: " .. routeName)
                screenGui:Destroy()
            end)
            
            local del = Instance.new("TextButton", row)
            del.Size = UDim2.new(0, 30, 0, 30)
            del.Position = UDim2.new(1, -40, 0.5, -15)
            del.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
            del.Text = "X"
            del.TextColor3 = Color3.fromRGB(255, 255, 255)
            del.Font = Enum.Font.GothamBold
            Instance.new("UICorner", del)
            
            del.MouseButton1Click:Connect(function()
                savedRoutes[routeName] = nil
                syncDeleteRoute(routeName)
                refreshRoutes()
            end)
            end
        end
        
        if not any then
            local empty = Instance.new("TextLabel", content)
            empty.Size = UDim2.new(1, 0, 0, 50)
            empty.BackgroundTransparency = 1
            empty.Text = "No routes saved."
            empty.TextColor3 = Color3.fromRGB(100, 100, 110)
            empty.TextSize = 13
            empty.Font = Enum.Font.Item
        end
    end
    
    task.spawn(function()
        if fetchRoutes() then
            refreshRoutes()
        end
    end)
end

local function showWhoisDialog()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyWhoisDialog") then pg.ArmyWhoisDialog:Destroy() end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyWhoisDialog"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 300, 0, 400)
    panel.Position = UDim2.new(0.5, -150, 0.5, -200)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -50, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "WHOIS (SERVER VIEW)"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 14
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)
    
    local statusLabel = Instance.new("TextLabel", panel)
    statusLabel.Size = UDim2.new(1, -20, 0, 30)
    statusLabel.Position = UDim2.new(0, 10, 0, 60)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Fetching clients..."
    statusLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
    statusLabel.TextSize = 12
    statusLabel.Font = Enum.Font.Gotham
    
    local content = Instance.new("ScrollingFrame", panel)
    content.Size = UDim2.new(1, -20, 1, -110)
    content.Position = UDim2.new(0, 10, 0, 100)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 2
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    content.Visible = false
    
    local list = Instance.new("UIListLayout", content)
    list.Padding = UDim.new(0, 5)
    
    task.spawn(function()
        local success, response = robustRequest({
            Url = SERVER_URL .. "/clients",
            Method = "GET"
        })
        
        if success and response and response.Body then
            local jsonSuccess, data = pcall(function()
                return HttpService:JSONDecode(response.Body)
            end)
            
            if jsonSuccess and data then
                local soldiers = {}
                local commanderCount = 0
                for _, client in ipairs(data) do
                    if client.isCommander then
                        commanderCount = commanderCount + 1
                    else
                        table.insert(soldiers, client)
                    end
                end
                
                statusLabel.Text = string.format("Soldiers: %d | Commanders: %d", #soldiers, commanderCount)
                statusLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
                
                for _, soldier in ipairs(soldiers) do
                    local row = Instance.new("Frame", content)
                    row.Size = UDim2.new(1, 0, 0, 30)
                    row.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
                    row.BorderSizePixel = 0
                    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)
                    
                    local nameL = Instance.new("TextLabel", row)
                    nameL.Size = UDim2.new(1, -10, 1, 0)
                    nameL.Position = UDim2.new(0, 10, 0, 0)
                    nameL.BackgroundTransparency = 1
                    nameL.Text = soldier.id
                    nameL.TextColor3 = (soldier.id == clientId) and Color3.fromRGB(100, 255, 150) or Color3.fromRGB(200, 200, 200)
                    nameL.TextSize = 12
                    nameL.Font = Enum.Font.Gotham
                    nameL.TextXAlignment = Enum.TextXAlignment.Left
                end
                
                content.Visible = true
            else
                statusLabel.Text = "Error decoding client data"
                statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            end
        else
            statusLabel.Text = "Failed to fetch clients"
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end
    end)
end

local function showFireButton()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyFireButton") then pg.ArmyFireButton:Destroy() end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyFireButton"
    screenGui.ResetOnSpawn = false
    
    local btn = Instance.new("TextButton", screenGui)
    btn.Size = UDim2.new(0, 120, 0, 60)
    btn.Position = UDim2.new(0.5, -60, 0.85, 0)
    btn.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    btn.Text = "FIRE"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBlack
    btn.TextSize = 24
    
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    Instance.new("UIStroke", btn).Color = Color3.fromRGB(255, 200, 200)
    Instance.new("UIStroke", btn).Thickness = 2
    
    btn.MouseButton1Click:Connect(function()
        sendCommand("projectile_fire")
        sendNotify("Projectile", "FIRING!")
        screenGui:Destroy()
    end)
end

local function showProjectileDialog()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    
    if pg:FindFirstChild("ArmyProjectileDialog") then pg.ArmyProjectileDialog:Destroy() end
    
    local screenGui = Instance.new("ScreenGui", pg)
    screenGui.Name = "ArmyProjectileDialog"
    screenGui.ResetOnSpawn = false
    
    local panel = Instance.new("Frame", screenGui)
    panel.Size = UDim2.new(0, 300, 0, 320)
    panel.Position = UDim2.new(0.5, -150, 0.5, -160)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    panel.BorderSizePixel = 0
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
    Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)
    
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 50)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    Instance.new("UICorner", header)
    
    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -50, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "SELECT PROJECTILE"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    
    local close = Instance.new("TextButton", header)
    close.Size = UDim2.new(0, 30, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "X"
    close.TextColor3 = Color3.fromRGB(200, 200, 200)
    close.TextSize = 18
    close.Font = Enum.Font.GothamBold
    close.MouseButton1Click:Connect(function() screenGui:Destroy() end)

    local content = Instance.new("ScrollingFrame", panel)
    content.Size = UDim2.new(1, -20, 1, -60)
    content.Position = UDim2.new(0, 10, 0, 60)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 2
    
    local list = Instance.new("UIListLayout", content)
    list.Padding = UDim.new(0, 8)

    local weapons = {"Bow", "Crossbow", "Cannon", "Ballista"}
    
    for _, weapon in ipairs(weapons) do
        local btn = Instance.new("TextButton", content)
        btn.Size = UDim2.new(1, 0, 0, 40)
        btn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
        btn.Text = weapon
        btn.TextColor3 = Color3.fromRGB(220, 220, 220)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 14
        Instance.new("UICorner", btn)

        btn.MouseButton1Click:Connect(function()
            screenGui:Destroy()
            -- Commander logic:
            sendCommand("projectile_init " .. weapon)
            sendNotify("Projectile", "Initialized " .. weapon .. " - Press 'F' to aim")
            
            setPendingClick(UserInputService.InputBegan:Connect(function(input, processed)
                if processed then return end
                if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.F then
                    -- Find player under mouse cursor
                    local target = Mouse.Target
                    if target then
                        local targetPlayer = Players:GetPlayerFromCharacter(target.Parent)
                        if targetPlayer and targetPlayer ~= LocalPlayer then
                            sendCommand("projectile_aim " .. tostring(targetPlayer.UserId))
                            sendNotify("Projectile", "Locked onto " .. targetPlayer.Name .. " - Click 'FIRE' to shoot")
                            cancelPendingClick()
                            showFireButton()
                        else
                            sendNotify("Projectile", "No player found under cursor")
                        end
                    end
                end
            end), nil)
        end)
    end
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

    local commandsGroup, settingsGroup, shortcutsGroup -- Forward declare containers
    local headerTitle, headerSubtitle -- Forward declare UI elements

    local function switchView(target)
        if not commandsGroup or not settingsGroup or not shortcutsGroup then return end
        
        -- Reset all visibility
        commandsGroup.Visible = false
        settingsGroup.Visible = false
        shortcutsGroup.Visible = false
        commandsGroup.GroupTransparency = 1
        settingsGroup.GroupTransparency = 1
        shortcutsGroup.GroupTransparency = 1

        if target == "Settings" then
            settingsGroup.Visible = true
            settingsGroup.GroupTransparency = 0
            headerSubtitle.Text = "Settings"
        elseif target == "Shortcuts" then
            shortcutsGroup.Visible = true
            shortcutsGroup.GroupTransparency = 0
            headerSubtitle.Text = "Shortcut Config"
        else
            commandsGroup.Visible = true
            commandsGroup.GroupTransparency = 0
            headerSubtitle.Text = "Commander Mode"
        end
    end
    
    -- Header
    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 60)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    header.BorderSizePixel = 0
    
    local headerCorner = Instance.new("UICorner", header)
    headerCorner.CornerRadius = UDim.new(0, 12)
    
    headerTitle = Instance.new("TextLabel", header)
    headerTitle.Size = UDim2.new(1, -20, 0, 24)
    headerTitle.Position = UDim2.new(0, 20, 0, 12)
    headerTitle.BackgroundTransparency = 1
    headerTitle.Text = "ARMY CONTROL"
    headerTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    headerTitle.TextSize = 18
    headerTitle.Font = Enum.Font.GothamBold
    headerTitle.TextXAlignment = Enum.TextXAlignment.Left
    
    headerSubtitle = Instance.new("TextLabel", header)
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
    gearBtn.MouseButton1Click:Connect(function()
        if settingsGroup.Visible then
            switchView("Commands")
        else
            switchView("Settings")
        end
    end)

    local gearCorner = Instance.new("UICorner", gearBtn)
    gearCorner.CornerRadius = UDim.new(0, 8)

    local gearStroke = Instance.new("UIStroke", gearBtn)
    gearStroke.Color = Color3.fromRGB(60, 60, 70)
    gearStroke.Thickness = 1
    gearStroke.Transparency = 0.6

    -- Shortcuts Button
    local shortcutsBtn = Instance.new("TextButton", header)
    shortcutsBtn.Name = "ShortcutsBtn"
    shortcutsBtn.Size = UDim2.new(0, 28, 0, 28)
    shortcutsBtn.Position = UDim2.new(1, -72, 0, 16)
    shortcutsBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    shortcutsBtn.BorderSizePixel = 0
    shortcutsBtn.AutoButtonColor = false
    shortcutsBtn.Text = "⌨"
    shortcutsBtn.TextColor3 = Color3.fromRGB(210, 210, 220)
    shortcutsBtn.TextSize = 16
    shortcutsBtn.Font = Enum.Font.GothamBold

    local shortcutsCorner = Instance.new("UICorner", shortcutsBtn)
    shortcutsCorner.CornerRadius = UDim.new(0, 8)

    local shortcutsStroke = Instance.new("UIStroke", shortcutsBtn)
    shortcutsStroke.Color = Color3.fromRGB(60, 60, 70)
    shortcutsStroke.Thickness = 1
    shortcutsStroke.Transparency = 0.6
    
    shortcutsBtn.MouseButton1Click:Connect(function()
        if shortcutsGroup.Visible then
            switchView("Commands")
        else
            switchView("Shortcuts")
        end
    end)
    
    -- Fade transition containers (CanvasGroup fades all descendants cleanly).
    commandsGroup = Instance.new("CanvasGroup", panel)
    commandsGroup.Name = "CommandsGroup"
    commandsGroup.Size = UDim2.new(1, -20, 1, -80)
    commandsGroup.Position = UDim2.new(0, 10, 0, 70)
    commandsGroup.BackgroundTransparency = 1
    commandsGroup.Visible = true
    commandsGroup.GroupTransparency = 0

    settingsGroup = Instance.new("CanvasGroup", panel)
    settingsGroup.Name = "SettingsGroup"
    settingsGroup.Size = UDim2.new(1, -20, 1, -80)
    settingsGroup.Position = UDim2.new(0, 10, 0, 70)
    settingsGroup.BackgroundTransparency = 1
    settingsGroup.Visible = false
    settingsGroup.GroupTransparency = 1

    shortcutsGroup = Instance.new("CanvasGroup", panel)
    shortcutsGroup.Name = "ShortcutsGroup"
    shortcutsGroup.Size = UDim2.new(1, -20, 1, -80)
    shortcutsGroup.Position = UDim2.new(0, 10, 0, 70)
    shortcutsGroup.BackgroundTransparency = 1
    shortcutsGroup.Visible = false
    shortcutsGroup.GroupTransparency = 1

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

    -- Shortcuts page: compact rows + group sections + search/filter.
    local shortcutsScroll = Instance.new("ScrollingFrame", shortcutsGroup)
    shortcutsScroll.Size = UDim2.new(1, 0, 1, 0)
    shortcutsScroll.Position = UDim2.new(0, 0, 0, 0)
    shortcutsScroll.BackgroundTransparency = 1
    shortcutsScroll.BorderSizePixel = 0
    shortcutsScroll.ScrollBarThickness = 4
    shortcutsScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 110)
    shortcutsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    shortcutsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

    local shortcutsList = Instance.new("UIListLayout", shortcutsScroll)
    shortcutsList.SortOrder = Enum.SortOrder.LayoutOrder
    shortcutsList.Padding = UDim.new(0, 8)

    local shortcutSearchTerm = ""
    local shortcutActiveGroup = "All"
    local shortcutSectionHeaders = {}

    local shortcutsHint = Instance.new("TextLabel", shortcutsScroll)
    shortcutsHint.Size = UDim2.new(1, 0, 0, 30)
    shortcutsHint.BackgroundTransparency = 1
    shortcutsHint.Text = "Search, filter, and bind. Esc cancels recording, Backspace clears."
    shortcutsHint.TextWrapped = true
    shortcutsHint.TextColor3 = Color3.fromRGB(175, 175, 190)
    shortcutsHint.TextSize = 11
    shortcutsHint.Font = Enum.Font.Gotham
    shortcutsHint.TextXAlignment = Enum.TextXAlignment.Left
    shortcutsHint.TextYAlignment = Enum.TextYAlignment.Top

    local shortcutsSearch = Instance.new("TextBox", shortcutsScroll)
    shortcutsSearch.Size = UDim2.new(1, 0, 0, 32)
    shortcutsSearch.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    shortcutsSearch.BorderSizePixel = 0
    shortcutsSearch.Text = ""
    shortcutsSearch.PlaceholderText = "Search shortcuts..."
    shortcutsSearch.TextColor3 = Color3.fromRGB(230, 230, 235)
    shortcutsSearch.PlaceholderColor3 = Color3.fromRGB(135, 135, 145)
    shortcutsSearch.TextSize = 12
    shortcutsSearch.Font = Enum.Font.Gotham
    shortcutsSearch.ClearTextOnFocus = false
    Instance.new("UICorner", shortcutsSearch).CornerRadius = UDim.new(0, 6)

    local filterWrap = Instance.new("Frame", shortcutsScroll)
    filterWrap.Size = UDim2.new(1, 0, 0, 34)
    filterWrap.BackgroundTransparency = 1

    local filterScroll = Instance.new("ScrollingFrame", filterWrap)
    filterScroll.Size = UDim2.new(1, 0, 1, 0)
    filterScroll.BackgroundTransparency = 1
    filterScroll.BorderSizePixel = 0
    filterScroll.ScrollBarThickness = 2
    filterScroll.ScrollBarImageColor3 = Color3.fromRGB(95, 95, 110)
    filterScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    filterScroll.CanvasSize = UDim2.new(0, 0, 0, 0)

    local filterList = Instance.new("UIListLayout", filterScroll)
    filterList.FillDirection = Enum.FillDirection.Horizontal
    filterList.SortOrder = Enum.SortOrder.LayoutOrder
    filterList.Padding = UDim.new(0, 6)

    local emptyShortcutsLabel = Instance.new("TextLabel", shortcutsScroll)
    emptyShortcutsLabel.Size = UDim2.new(1, 0, 0, 40)
    emptyShortcutsLabel.BackgroundTransparency = 1
    emptyShortcutsLabel.Text = "No shortcuts match this filter."
    emptyShortcutsLabel.TextColor3 = Color3.fromRGB(140, 140, 150)
    emptyShortcutsLabel.TextSize = 12
    emptyShortcutsLabel.Font = Enum.Font.Gotham
    emptyShortcutsLabel.TextXAlignment = Enum.TextXAlignment.Left
    emptyShortcutsLabel.Visible = false

    local function clearShortcutHeaders()
        for _, header in ipairs(shortcutSectionHeaders) do
            if header then header:Destroy() end
        end
        shortcutSectionHeaders = {}
    end

    local function createShortcutHeader(groupName, layoutOrder)
        local header = Instance.new("TextLabel", shortcutsScroll)
        header.Size = UDim2.new(1, 0, 0, 20)
        header.BackgroundTransparency = 1
        header.Text = string.upper(groupName or "OTHER")
        header.TextColor3 = Color3.fromRGB(150, 170, 220)
        header.TextSize = 11
        header.Font = Enum.Font.GothamBold
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.LayoutOrder = layoutOrder
        table.insert(shortcutSectionHeaders, header)
        return header
    end

    local function createShortcutRow(actionId)
        if shortcutRows[actionId] then return end
        local entry = shortcutBindings[actionId]
        if not entry then return end

        local row = Instance.new("Frame", shortcutsScroll)
        row.Name = "ShortcutRow"
        row.Size = UDim2.new(1, 0, 0, 52)
        row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
        row.BorderSizePixel = 0
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

        local rowStroke = Instance.new("UIStroke", row)
        rowStroke.Color = Color3.fromRGB(55, 55, 65)
        rowStroke.Thickness = 1
        rowStroke.Transparency = 0.7

        local title = Instance.new("TextLabel", row)
        title.Size = UDim2.new(1, -170, 0, 16)
        title.Position = UDim2.new(0, 10, 0, 5)
        title.BackgroundTransparency = 1
        title.Text = entry.actionName or entry.label
        title.TextColor3 = Color3.fromRGB(230, 230, 235)
        title.TextSize = 11
        title.Font = Enum.Font.GothamSemibold
        title.TextXAlignment = Enum.TextXAlignment.Left

        local groupLabel = Instance.new("TextLabel", row)
        groupLabel.Size = UDim2.new(1, -170, 0, 12)
        groupLabel.Position = UDim2.new(0, 10, 0, 20)
        groupLabel.BackgroundTransparency = 1
        groupLabel.Text = entry.group or "Other"
        groupLabel.TextColor3 = Color3.fromRGB(130, 145, 170)
        groupLabel.TextSize = 10
        groupLabel.Font = Enum.Font.GothamBold
        groupLabel.TextXAlignment = Enum.TextXAlignment.Left

        local bindLabel = Instance.new("TextLabel", row)
        bindLabel.Size = UDim2.new(1, -170, 0, 14)
        bindLabel.Position = UDim2.new(0, 10, 0, 35)
        bindLabel.BackgroundTransparency = 1
        bindLabel.Text = "Unbound"
        bindLabel.TextColor3 = Color3.fromRGB(150, 180, 255)
        bindLabel.TextSize = 10
        bindLabel.Font = Enum.Font.Gotham
        bindLabel.TextXAlignment = Enum.TextXAlignment.Left

        local clearBtn = Instance.new("TextButton", row)
        clearBtn.Size = UDim2.new(0, 60, 0, 22)
        clearBtn.Position = UDim2.new(1, -68, 0.5, -11)
        clearBtn.BackgroundColor3 = Color3.fromRGB(125, 70, 70)
        clearBtn.BorderSizePixel = 0
        clearBtn.Text = "Clear"
        clearBtn.TextColor3 = Color3.fromRGB(230, 230, 235)
        clearBtn.TextSize = 11
        clearBtn.Font = Enum.Font.GothamBold
        Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

        local recordBtn = Instance.new("TextButton", row)
        recordBtn.Size = UDim2.new(0, 70, 0, 22)
        recordBtn.Position = UDim2.new(1, -144, 0.5, -11)
        recordBtn.BackgroundColor3 = Color3.fromRGB(60, 95, 170)
        recordBtn.BorderSizePixel = 0
        recordBtn.Text = "Bind"
        recordBtn.TextColor3 = Color3.fromRGB(230, 230, 235)
        recordBtn.TextSize = 11
        recordBtn.Font = Enum.Font.GothamBold
        Instance.new("UICorner", recordBtn).CornerRadius = UDim.new(0, 6)

        recordBtn.MouseButton1Click:Connect(function()
            startShortcutRecording(actionId)
        end)

        clearBtn.MouseButton1Click:Connect(function()
            applyShortcutBind(actionId, nil)
            sendNotify("Shortcuts", "Cleared bind for " .. entry.label)
        end)

        shortcutRows[actionId] = {
            container = row,
            titleLabel = title,
            groupLabel = groupLabel,
            bindLabel = bindLabel,
            recordBtn = recordBtn
        }
        updateShortcutRow(actionId)
    end

    local function shortcutPassesFilter(entry)
        if not entry then return false end

        if shortcutActiveGroup ~= "All" and (entry.group or "Other") ~= shortcutActiveGroup then
            return false
        end

        if shortcutSearchTerm == "" then
            return true
        end

        local haystack = string.lower((entry.label or "") .. " " .. (entry.actionName or "") .. " " .. (entry.group or ""))
        local bindText = string.lower(getShortcutBindText(entry.bind))
        return (string.find(haystack, shortcutSearchTerm, 1, true) ~= nil) or (string.find(bindText, shortcutSearchTerm, 1, true) ~= nil)
    end

    local function applyFilterButtonStyle(btn, isActive)
        if isActive then
            btn.BackgroundColor3 = Color3.fromRGB(95, 130, 220)
            btn.TextColor3 = Color3.fromRGB(245, 245, 255)
        else
            btn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
            btn.TextColor3 = Color3.fromRGB(180, 180, 195)
        end
    end

    local function refreshShortcutRowsView()
        clearShortcutHeaders()

        local entries = {}
        for _, actionId in ipairs(shortcutOrder) do
            local entry = shortcutBindings[actionId]
            local row = shortcutRows[actionId]
            if entry and row and shortcutPassesFilter(entry) then
                table.insert(entries, { actionId = actionId, entry = entry, row = row })
            elseif row and row.container then
                row.container.Visible = false
            end
        end

        table.sort(entries, function(a, b)
            local ga = tostring(a.entry.group or "Other")
            local gb = tostring(b.entry.group or "Other")
            if ga ~= gb then
                return ga < gb
            end
            local na = tostring(a.entry.actionName or a.entry.label or "")
            local nb = tostring(b.entry.actionName or b.entry.label or "")
            return string.lower(na) < string.lower(nb)
        end)

        local nextOrder = 30
        local lastGroup = nil
        for _, item in ipairs(entries) do
            local groupName = item.entry.group or "Other"
            local showHeader = (shortcutActiveGroup == "All")
            if showHeader and groupName ~= lastGroup then
                createShortcutHeader(groupName, nextOrder)
                nextOrder = nextOrder + 1
                lastGroup = groupName
            end

            if item.row.container then
                item.row.container.Visible = true
                item.row.container.LayoutOrder = nextOrder
                nextOrder = nextOrder + 1
            end
        end

        emptyShortcutsLabel.Visible = (#entries == 0)
        if emptyShortcutsLabel.Visible then
            emptyShortcutsLabel.LayoutOrder = nextOrder
        end
    end

    local function rebuildShortcutFilterButtons()
        for _, child in ipairs(filterScroll:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        local groups = { "All" }
        local seen = { All = true }
        for _, actionId in ipairs(shortcutOrder) do
            local entry = shortcutBindings[actionId]
            local groupName = (entry and entry.group) or "Other"
            if not seen[groupName] then
                seen[groupName] = true
                table.insert(groups, groupName)
            end
        end

        table.sort(groups, function(a, b)
            if a == "All" then return true end
            if b == "All" then return false end
            return tostring(a) < tostring(b)
        end)

        for _, groupName in ipairs(groups) do
            local btn = Instance.new("TextButton", filterScroll)
            btn.Size = UDim2.new(0, math.max(58, #groupName * 7 + 18), 1, -4)
            btn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
            btn.BorderSizePixel = 0
            btn.Text = groupName
            btn.TextSize = 11
            btn.Font = Enum.Font.GothamSemibold
            btn.TextColor3 = Color3.fromRGB(180, 180, 195)
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

            applyFilterButtonStyle(btn, shortcutActiveGroup == groupName)
            btn.MouseButton1Click:Connect(function()
                shortcutActiveGroup = groupName
                for _, other in ipairs(filterScroll:GetChildren()) do
                    if other:IsA("TextButton") then
                        applyFilterButtonStyle(other, other.Text == shortcutActiveGroup)
                    end
                end
                refreshShortcutRowsView()
            end)
        end
    end

    shortcutsSearch:GetPropertyChangedSignal("Text"):Connect(function()
        shortcutSearchTerm = string.lower(shortcutsSearch.Text or "")
        refreshShortcutRowsView()
    end)

    local function syncShortcutRows()
        for _, actionId in ipairs(shortcutOrder) do
            createShortcutRow(actionId)
            updateShortcutRow(actionId)
        end
        rebuildShortcutFilterButtons()
        refreshShortcutRowsView()
    end

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

    local observeToggle = createToggleCard(
        "Observe Orders",
        "Show server orders on the commander (no execution).",
        function() return observeServerCommands end,
        function(v)
            observeServerCommands = v
        end
    )

    local autoResendToggle = createToggleCard(
        "Auto Resend",
        "Re-send a command if it doesn't show up in Observe Orders.",
        function() return autoResendIfNotObserved end,
        function(v)
            autoResendIfNotObserved = v
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
            observeToggle.Set(observeServerCommands)
            autoResendToggle.Set(autoResendIfNotObserved)

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

            local actionId = makeShortcutActionId(config.Title, subConfig.Text)
            registerShortcutAction(actionId, config.Title .. " / " .. subConfig.Text, function()
                subConfig.Callback(actualBtn)
            end)
            if subConfig.DefaultBind then
                setDefaultShortcutBind(actionId, subConfig.DefaultBind)
            end
            syncShortcutRows()
            
            actualBtn.MouseButton1Click:Connect(function()
                if isRecordingShortcut then
                    sendNotify("Shortcuts", "Finish current bind first (Esc to cancel)")
                    return
                end
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
                CommandString = "jump",
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
                Text = "Goto Mouse (Pathfind)",
                Color = Color3.fromRGB(255, 200, 150),
                Callback = function()
                    sendNotify("Pathfind Mode", "Click where you want soldiers to pathfind")
                    setPendingClick(Mouse.Button1Down:Connect(function()
                        if Mouse.Hit then
                            local targetPos = Mouse.Hit.Position + Vector3.new(0, 3, 0)
                            local pathCmd = string.format("pathfind %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                            sendCommand(pathCmd)
                            sendNotify("Pathfind", "Soldiers pathfinding to location")
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
            },
            {
                Text = "Route",
                Color = Color3.fromRGB(150, 120, 255),
                Callback = function()
                    showRouteManager()
                end
            },
            {
                Text = "InfJump: " .. (infJumpEnabled and "ON" or "OFF"),
                Color = Color3.fromRGB(100, 255, 200),
                Callback = function(btn)
                    infJumpEnabled = not infJumpEnabled
                    btn.Text = "InfJump: " .. (infJumpEnabled and "ON" or "OFF")
                    sendNotify("Settings", "Infinite Jump: " .. (infJumpEnabled and "Enabled" or "Disabled"))
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
                                if player then
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
                Text = "Follow Commander",
                Color = Color3.fromRGB(150, 255, 150),
                Callback = function()
                    local modeCmd = followMode or "Normal"
                    local fullCmd = string.format("follow %d %s", LocalPlayer.UserId, modeCmd)
                    sendCommand(fullCmd)
                    sendNotify("Following", "Commander (" .. modeCmd .. ")")
                    followTargetUserId = LocalPlayer.UserId
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
                Text = "Whois",
                Color = Color3.fromRGB(200, 200, 255),
                Callback = function()
                    showWhoisDialog()
                end
            },
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
                            if networkRequest then
                                local success, response = robustRequest({
                                    Url = SERVER_URL .. "/clients",
                                    Method = "GET"
                                })
                                
                                if success and response and response.Body then
                                    local jsonSuccess, data = pcall(function()
                                        return HttpService:JSONDecode(response.Body)
                                    end)
                                    if jsonSuccess and data then
                                        -- Filter out commanders from formation
                                        local soldiers = {}
                                        for _, client in ipairs(data) do
                                            if not client.isCommander then
                                                table.insert(soldiers, client)
                                            end
                                        end
                                        clientCount = #soldiers
                                        for _, client in ipairs(soldiers) do
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
                                    if player and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
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
                                    if player then
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
                Text = "Follow Commander",
                Color = Color3.fromRGB(150, 255, 150),
                Callback = function()
                    formationMode = "Follow"
                    sendNotify("Formation", "Calculating offsets for Commander follow...")
                    
                    task.spawn(function()
                        if networkRequest then
                            local success, response = robustRequest({
                                Url = SERVER_URL .. "/clients",
                                Method = "GET"
                            })
                            
                            if success and response and response.Body then
                                local jsonSuccess, data = pcall(function()
                                    return HttpService:JSONDecode(response.Body)
                                end)
                                if jsonSuccess and data then
                                    local soldiers = {}
                                    for _, client in ipairs(data) do
                                        if not client.isCommander then
                                            table.insert(soldiers, client)
                                        end
                                    end
                                    
                                    local count = #soldiers
                                    local offsets = calculateFormationOffsets(formationShape, count)
                                    local offsetsData = {}
                                    for i, soldier in ipairs(soldiers) do
                                        if offsets[i] then
                                            offsetsData[soldier.id] = {
                                                x = offsets[i].X,
                                                y = offsets[i].Y,
                                                z = offsets[i].Z
                                            }
                                        end
                                    end
                                    
                                    local offsetsJson = HttpService:JSONEncode(offsetsData)
                                    local formationCmd = string.format("formation_follow %d %s %s", LocalPlayer.UserId, formationShape, offsetsJson)
                                    sendCommand(formationCmd)
                                    
                                    sendNotify("Formation", "Soldiers are forming around Commander (" .. formationShape .. ")")
                                end
                            else
                                sendNotify("Error", "Could not fetch soldiers from server")
                            end
                        end
                    end)
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
                                    -- Filter out commanders from formation
                                    local soldiers = {}
                                    for _, client in ipairs(data) do
                                        if not client.isCommander then
                                            table.insert(soldiers, client)
                                        end
                                    end
                                    clientCount = #soldiers
                                    -- Extract client IDs
                                    for _, client in ipairs(soldiers) do
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
    local boogaDrawer = nil
    if game.PlaceId == 11729688377 or game.PlaceId == 11879754496 then
        boogaDrawer = createDrawer({
            Title = "Booga Booga",
            Description = "Booga Booga special actions",
            Icon = "👺",
            Color = Color3.fromRGB(255, 100, 50),
            Buttons = {
                {
                    Text = "Projectile",
                    Color = Color3.fromRGB(255, 50, 50),
                    Callback = function()
                        showProjectileDialog()
                    end
                },
                {
                    Text = "Spawn",
                    Color = Color3.fromRGB(100, 255, 100),
                    Callback = function()
                        sendCommand("spawn")
                        sendNotify("Army", "Broadcasting spawn command")
                    end
                },
                {
                    Text = "Auto Voodoo",
                    Color = Color3.fromRGB(200, 100, 255),
                    Callback = function()
                        sendNotify("Auto Voodoo", "Tap ground to fire (Hold F for Burst)")
                        local clicks = 0
                        setPendingClick(Mouse.Button1Down:Connect(function()
                            if Mouse.Hit then
                                local isBurst = UserInputService:IsKeyDown(Enum.KeyCode.F)
                                local targetPos = Mouse.Hit.Position
                                local coordsStr = string.format("%.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z)
                                
                                if isBurst then
                                    -- Burst mode: sends "voodoo burst coord,coord,coord"
                                    sendCommand("voodoo burst " .. coordsStr)
                                    sendNotify("Voodoo", "Fired 3-shot burst - Selection finished")
                                    cancelPendingClick()
                                else
                                    -- Precision mode: sends "voodoo single coord,coord,coord"
                                    clicks = clicks + 1
                                    sendCommand("voodoo single " .. coordsStr)
                                    
                                    if clicks < 3 then
                                        sendNotify("Voodoo", string.format("Fired %d/3 locations", clicks))
                                    else
                                        sendNotify("Voodoo", "Fired 3/3 locations - Selection finished")
                                        cancelPendingClick()
                                    end
                                end
                            end
                        end), nil)
                    end
                },
                {
                    Text = "Inventory Manager",
                    Color = Color3.fromRGB(200, 100, 255),
                    Callback = function()
                        showInventoryManager()
                    end
                },
                {
                    Text = "Tools",
                    Color = Color3.fromRGB(100, 200, 255),
                    Callback = function()
                        showToolsMenu()
                    end
                },
                {
                    Text = "Pickup",
                    Color = Color3.fromRGB(100, 255, 150),
                    Callback = function()
                        showPickupManager()
                    end
                },
                {
                    Text = "Farm",
                    Color = Color3.fromRGB(255, 150, 50),
                    Callback = function()
                        showFarmMenu()
                    end
                }
            }
        })
    end

    -- Re-order drawers to match the desired tab order:
    -- Movement, Follow, Formation, Booga Booga (if visible), Accounts
    movementDrawer.Container.LayoutOrder = 1
    followDrawer.Container.LayoutOrder = 2
    formationDrawer.Container.LayoutOrder = 3
    if boogaDrawer then
        boogaDrawer.Container.LayoutOrder = 4
    end
    serverDrawer.Container.LayoutOrder = 5

    -- "System" is merged into "Accounts" now.
    systemDrawer.Container.Visible = false

    -- Ensure shortcuts page contains every registered action (including drawers + core actions).
    syncShortcutRows()
    updateAllShortcutRows()

    -- Initial State: Hidden
    panel.Position = UDim2.new(1, 0, 0.5, -240)
    screenGui.Parent = LocalPlayer.PlayerGui
    
    return screenGui
end

local function togglePanelShortcut()
    local wasCommander = isCommander
    isCommander = true

    if not panelGui then
        panelGui = createPanel()
    end

    -- Re-register if we just became commander so the server knows
    if not wasCommander then
        task.spawn(registerClient)
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
        return
    end

    -- Close
    isPanelOpen = false
    TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
        Position = UDim2.new(1, 0, 0.5, -240)
    }):Play()

    task.delay(0.3, function()
        if not isPanelOpen and panelGui then
            panelGui.Enabled = false
            -- Close any open sub-menus
            pcall(function()
                local pg = LocalPlayer:FindFirstChild("PlayerGui")
                if pg then
                    if pg:FindFirstChild("ArmyInventoryManager") then pg.ArmyInventoryManager:Destroy() end
                    if pg:FindFirstChild("ArmySearchDialog") then pg.ArmySearchDialog:Destroy() end
                    if pg:FindFirstChild("ArmyPickupManager") then pg.ArmyPickupManager:Destroy() end
                    if pg:FindFirstChild("ArmyToolsMenu") then pg.ArmyToolsMenu:Destroy() end
                    if pg:FindFirstChild("ArmyFarmMenu") then pg.ArmyFarmMenu:Destroy() end
                    if pg:FindFirstChild("ArmyRouteManager") then pg.ArmyRouteManager:Destroy() end
                    if pg:FindFirstChild("ArmyRouteEditor") then pg.ArmyRouteEditor:Destroy() end
                    if pg:FindFirstChild("ArmyWhoisDialog") then pg.ArmyWhoisDialog:Destroy() end
                    -- We explicitly DO NOT destroy ArmyPrepareFinish here so it stays visible
                end
            end)
        end
    end)
end

local function cancelOrderShortcut()
    local now = os.clock()
    if now - lastCancelTime < CANCEL_COOLDOWN then
        return
    end

    -- Don't let cancel be used to spam notifications when nothing is happening.
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
end

local function terminateShortcut()
    terminateScript()
end

registerShortcutAction("core_toggle_panel", "Core / Toggle Panel", togglePanelShortcut)
setDefaultShortcutBind("core_toggle_panel", { key = Enum.KeyCode.G, ctrl = false, alt = false, shift = false })

registerShortcutAction("core_cancel", "Core / Cancel Current Order", cancelOrderShortcut)
setDefaultShortcutBind("core_cancel", { key = Enum.KeyCode.C, ctrl = false, alt = false, shift = false })

registerShortcutAction("core_terminate", "Core / Terminate Script", terminateShortcut)
setDefaultShortcutBind("core_terminate", { key = Enum.KeyCode.F3, ctrl = false, alt = false, shift = false })

table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    executeShortcutFromInput(input)
end))


-- Initial registration and WebSocket connection
task.wait(1)
connectWebSocket()

sendNotify("Army Script", "Press G to toggle Panel | F3 to Terminate")
print("Army Soldier loaded - WebSocket Mode")

local function setupInfiniteJump()
    if infJumpConnection then infJumpConnection:Disconnect() end
    infJumpConnection = UserInputService.JumpRequest:Connect(function()
        if infJumpEnabled and isRunning then
            local char, hum, root = getMyRig()
            if hum and not infJumpDebounce then
                infJumpDebounce = true
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
                task.wait()
                infJumpDebounce = false
            end
        end
    end)
end

setupInfiniteJump()
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    setupInfiniteJump()
end)

-- Polling loop removed. WebSocket handling is async via OnMessage.
while isRunning do
    -- Polling thru websockets: send heartbeat every 5s to verify registration
    task.wait(5)
    
    if activeWS and clientId then
        pcall(function()
            activeWS:Send(HttpService:JSONEncode({ type = "heartbeat", clientId = clientId }))
        end)
    elseif not activeWS and not isConnecting then
        connectWebSocket()
    end
end

sendNotify("Army Script", "Script Terminated")
