local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Forward declarations
-- Forward declarations
local highlightPlayers, clearHighlights, startFollowing, stopFollowing, startFollowingPosition, stopFollowingPosition, sendCommand, stopGotoWalk, stopFarming, stopRoute, showRouteManager, startRouteExecution, fetchRoutes, syncSaveRoute, syncDeleteRoute, walkToUntilWithin, startFarmingTarget, startPrepareTool, stopPrepare
-- Used before their definitions below; forward-declare to avoid global/nil lookups.
local getMyRig, fireEquip, fireInventoryUse
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


-- Centralized Network Request Helper
local networkRequest = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request

local function robustRequest(options)
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
                    if check1 or check2 then
                        hum.Jump = true
                    end
                end
            end
        end
    end
end)

-- Persistent WalkSpeed enforcement: keep it at 16.
task.spawn(function()
    while isRunning do
        task.wait(0.5)
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.WalkSpeed ~= 16 then
            hum.WalkSpeed = 16
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
local pickupPacketId = 213 -- Fallback

local function getPickupPacketId()
    local ok, result = pcall(function()
        local ByteNetModule = ReplicatedStorage:FindFirstChild("Modules", true) and ReplicatedStorage.Modules:FindFirstChild("ByteNet")
        if not ByteNetModule then return nil end
        
        local Replicated = ByteNetModule:FindFirstChild("replicated")
        local values = Replicated and Replicated:FindFirstChild("values")
        if not values then return nil end
        
        local Values = require(values)
        local boogaData = Values.access("booga"):read()
        return boogaData and boogaData.packets and boogaData.packets.Pickup
    end)
    if ok and result then
        pickupPacketId = result
        print("[PICKUP] Dynamic Packet ID found: " .. pickupPacketId)
    else
        warn("[PICKUP] Using fallback Packet ID: " .. pickupPacketId)
    end
end

local function firePickup(item)
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
    buffer.writeu8(b, 1, pickupPacketId)
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
    getPickupPacketId()
    
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

    local success = robustRequest({
        Url = SERVER_URL .. "/heartbeat",
        Method = "POST",
        Body = HttpService:JSONEncode({ clientId = clientId }),
        Headers = { ["Content-Type"] = "application/json" }
    })

    return success
end

local function acknowledgeCommand(commandId, success, errorMsg)
    if not clientId then return false end

    -- Normalize success: allow explicit false (the previous `success or true` would force it to true).
    local normalizedSuccess = (success == nil) and true or success

    local payload = HttpService:JSONEncode({
        clientId = clientId,
        commandId = commandId,
        success = normalizedSuccess,
        -- Some server implementations use "error" only on failure, and a separate "result"/"report" on success.
        -- Send the response in multiple fields for compatibility; the server can ignore what it doesn't need.
        error = (normalizedSuccess == false) and (errorMsg or nil) or nil,
        result = (normalizedSuccess ~= false) and (errorMsg or nil) or nil,
        report = (normalizedSuccess ~= false) and (errorMsg or nil) or nil
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

fireEquip = function(slot)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 3-byte buffer: [0][191][u8(slot)]
    local b = buffer.create(3)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, 191)  -- Packet ID 191 (Equip/Unequip)
    buffer.writeu8(b, 2, slot) -- Slot index
    
    -- Fire the buffer object DIRECTLY
    ByteNetRemote:FireServer(b)
end

local function fireInventoryStore(slot)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 3-byte buffer: [0][209][u8(slot)]
    local b = buffer.create(3)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, 209)  -- Packet ID 209 (Retool/Inventory Store)
    buffer.writeu8(b, 2, slot) -- Slot index
    
    ByteNetRemote:FireServer(b)
end

fireInventoryUse = function(order)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 4-byte buffer: [0][43][u16(order)]
    -- Packet 43: UseBagItem
    local b = buffer.create(4)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, 43)  -- Packet ID 43
    buffer.writeu16(b, 2, order) -- Index (u16 little-endian)
    
    ByteNetRemote:FireServer(b)
end

local function fireInventoryDrop(order)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    -- Create 4-byte buffer: [0][74][u16(order)]
    -- Packet 74: DropBagItem
    local b = buffer.create(4)
    buffer.writeu8(b, 0, 0)   -- Namespace 0
    buffer.writeu8(b, 1, 74)  -- Packet ID 74
    buffer.writeu16(b, 2, order) -- Index (u16 little-endian)
    
    ByteNetRemote:FireServer(b)
end

local function fireAction(actionId, entityId)
    local ByteNetRemote = ReplicatedStorage:FindFirstChild("ByteNetReliable", true) or ReplicatedStorage:FindFirstChild("ByteNet", true)
    if not ByteNetRemote then return end
    
    if actionId == 17 then
        -- Packet 17 (SwingTool) structure: [0][17][count_u16][entityId_u32]
        local b = buffer.create(8)
        buffer.writeu8(b, 0, 0)   -- Namespace 0
        buffer.writeu8(b, 1, 17)  -- Packet ID 17
        buffer.writeu16(b, 2, 1)  -- Count (1 target)
        buffer.writeu32(b, 4, entityId) -- Target Entity ID
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



local function getInventoryReport(query)
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

local function dropItemByName(itemName, quantity)
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

local function scanAndEquip(toolName)
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

local function terminateScript()
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

startFarmingTarget = function(targetPos)
    stopFarming()
    local myToken = farmToken
    isFarming = true
    
    task.spawn(function()
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

        local function findTarget()
            local resources = workspace:FindFirstChild("Resources")
            if resources then
                for _, child in ipairs(resources:GetChildren()) do
                    local pos = child:IsA("BasePart") and child.Position or (child:IsA("Model") and child.PrimaryPart and child.PrimaryPart.Position)
                    if pos and (pos - targetPos).Magnitude < 5 then
                        if child:GetAttribute("EntityID") then
                            return child
                        end
                    end
                end
            end
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
            
            local closestWorld = getClosestPointOnPart(targetPart, currentPos)
            local dist2D = (Vector2.new(currentPos.X, currentPos.Z) - Vector2.new(closestWorld.X, closestWorld.Z)).Magnitude
            
            if dist2D > 6 then
                -- Only call walkTo if we aren't already moving there or periodically to refresh
                if moveTarget ~= targetPart.Position or os.clock() - lastMoveToCall > 2 then
                    lastMoveToCall = os.clock()
                    Movement.walkTo(targetPart.Position)
                end
            else
                -- In range, stop moving and hit
                if moveTarget then
                    stopGotoWalk()
                end
                
                -- Look at the target
                root.CFrame = CFrame.new(root.Position, Vector3.new(closestWorld.X, root.Position.Y, closestWorld.Z))
                
                if os.clock() - lastSwing >= swingDelay then
                    local entityID = targetObject:GetAttribute("EntityID")
                    if entityID then
                        fireAction(17, entityID)
                        lastSwing = os.clock()
                    end
                end
            end
            task.wait(0.1)
        end
        
        if myToken == farmToken then
            isFarming = false
            stopGotoWalk()
        end
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
    
    local singleBtn = Instance.new("TextButton", panel)
    singleBtn.Size = UDim2.new(1, -20, 0, 40)
    singleBtn.Position = UDim2.new(0, 10, 0, 60)
    singleBtn.BackgroundColor3 = Color3.fromRGB(255, 150, 50)
    singleBtn.Text = "Single Target"
    singleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    singleBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", singleBtn)
    
    singleBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
        sendNotify("Farm", "Click an object to set as army target")
        setPendingClick(Mouse.Button1Down:Connect(function()
            local target = Mouse.Target
            if target then
                if target:IsA("Terrain") then
                    return -- Ignore terrain, allow another click
                end
                
                local resources = workspace:FindFirstChild("Resources")
                if not (resources and target:IsDescendantOf(resources)) then
                    sendNotify("Farm", "Invalid target (not in Resources) - cancelled")
                    cancelPendingClick()
                    return
                end
                
                -- Find the direct child of Resources that contains the clicked part
                local resourceModel = target
                while resourceModel and resourceModel.Parent ~= resources do
                    resourceModel = resourceModel.Parent
                    if resourceModel == workspace or not resourceModel then
                        break
                    end
                end
                
                if not resourceModel or resourceModel.Parent ~= resources then
                    sendNotify("Farm", "Error: Parent resource not found - cancelled")
                    cancelPendingClick()
                    return
                end
                
                local targetPos = resourceModel:IsA("BasePart") and resourceModel.Position or (resourceModel:IsA("Model") and resourceModel.PrimaryPart and resourceModel.PrimaryPart.Position) or target.Position
                sendCommand(string.format("farm_target %.2f,%.2f,%.2f", targetPos.X, targetPos.Y, targetPos.Z))
                sendNotify("Farm", "All soldiers targeting object: " .. resourceModel.Name)
                cancelPendingClick()
            end
        end), nil)
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

    -- Initial State: Hidden
    panel.Position = UDim2.new(1, 0, 0.5, -240)
    screenGui.Parent = LocalPlayer.PlayerGui
    
    return screenGui
end

-- Panel toggle with slide animation
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    if input.KeyCode == Enum.KeyCode.G then
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
        else
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
                            -- We explicitly DO NOT destroy ArmyPrepareFinish here so it stays visible
                        end
                    end)
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
        -- Terminate everything.
        terminateScript()
    end
end))


-- Register client before polling starts
task.wait(1)
-- One registration attempt. No retries.
local registered = registerClient()

if not registered then
    sendNotify("Warning", "Failed to register - running without ID")
end

sendNotify("Army Script", "Press G to toggle Panel | F3 to Terminate")
print("Army Soldier loaded - Press G for panel")

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

-- Polling loop (Main Thread)
print("[ARMY] Starting command loop...")
while isRunning do
    -- Send periodic heartbeat
    if clientId and os.time() - lastHeartbeat >= HEARTBEAT_INTERVAL then
        sendHeartbeat()
        lastHeartbeat = os.time()
    end

    -- Enhanced polling with ETag support
    local success, response

    if networkRequest then
        local headers = {}
        if lastETag then
            headers["If-None-Match"] = lastETag
        end
        success, response = robustRequest({
            Url = SERVER_URL .. "/",
            Method = "GET",
            Headers = headers
        }) -- Retries disabled
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
                    recordObservedAction(action)
                    
                    consecutiveNoChange = 0
                    currentPollRate = MIN_POLL_RATE

                    task.spawn(function()
                        -- By default, the commander does NOT obey server-issued commands.
                        -- Enable `debugFollowCommands` if you want the commander to follow commands too.
                        local shouldExecute = (action ~= "wait") and (not isCommander or debugFollowCommands)

                        -- Even if we don't execute on commander, still show what came back from the server
                        -- so you can verify the command actually made it through.
                        -- Silence automated order notifications on commander per request
                        -- if isCommander and observeServerCommands and (action ~= "wait") then
                        --     sendNotify("Order Received", action)
                        -- end

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

                                    -- Prefer sending a decoded table (real JSON) if possible, so the server
                                    -- doesn't have to JSON-decode a string inside JSON.
                                    pcall(function()
                                        reportPayload = HttpService:JSONDecode(reportJson)
                                    end)

                                    acknowledgeCommand(commandId, true, reportPayload)
                                    return true
                                elseif string.sub(action, 1, 12) == "farm_target " then
                                    local coordsStr = string.sub(action, 13)
                                    local coords = string.split(coordsStr, ",")
                                    if #coords == 3 then
                                        local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                        startFarmingTarget(targetPos)
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
                                elseif string.sub(action, 1, 15) == "target_drop_at " then
                                    -- Format: target_drop_at <clientId> <x,y,z> <name...> <qty>
                                    local parts = string.split(action, " ")
                                    local targetId = parts[2]
                                    if targetId == clientId or targetId == "all" then
                                        local coordsStr = parts[3]
                                        local qty = parts[#parts]
                                        local name = table.concat(parts, " ", 4, math.max(4, #parts - 1))

                                        local coords = string.split(coordsStr or "", ",")
                                        if #coords == 3 then
                                            local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                            -- Walk until we're close, then start dropping.
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
                                    -- Format: target_drop <clientId> <name> <qty>
                                    local parts = string.split(action, " ")
                                    if parts[2] == clientId then
                                        -- Item names can contain spaces, e.g. "Raw Iron". Treat the last token as qty.
                                        local qty = parts[#parts]
                                        local name = table.concat(parts, " ", 3, math.max(3, #parts - 1))
                                        dropItemByName(name, qty)
                                    end
                                    return true
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
                                    -- "C" key no longer cancels preparing locally, but a server-issued
                                    -- cancel should stop everything, including prepare loops.
                                    stopPrepare()
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
                                elseif action == "refresh_configs" then
                                    fetchServerConfigs()
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
                                elseif string.sub(action, 1, 6) == "equip " then
                                    local slot = tonumber(string.sub(action, 7))
                                    if slot then
                                        fireEquip(slot)
                                        print("[EQUIP] Fired for slot " .. slot)
                                    end
                                elseif action == "unequip_all" then
                                    for slot = 1, 6 do
                                        fireInventoryStore(slot)
                                        task.wait(0.05)
                                    end
                                    print("[UNEQUIP] All slots cleared to inventory")
                                elseif string.sub(action, 1, 11) == "sync_equip " then
                                    local toolName = string.sub(action, 12)
                                    if toolName then
                                        task.spawn(scanAndEquip, toolName)
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
                                elseif action == "spawn" then
                                    task.spawn(function()
                                        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                                        if not playerGui then return end
                                        
                                        local function findPlayButton()
                                            -- Look for SpawnGui first
                                            local spawnGui = playerGui:FindFirstChild("SpawnGui", true)
                                            if spawnGui then
                                                return spawnGui:FindFirstChild("PlayButton", true) or spawnGui:FindFirstChild("Play", true)
                                            end
                                            -- Fallback: Search all of PlayerGui for a PlayButton
                                            return playerGui:FindFirstChild("PlayButton", true) or playerGui:FindFirstChild("Play", true)
                                        end

                                        local playButton = findPlayButton()
                                        
                                        -- Retry once after a small delay if not found (UI might be loading)
                                        if not playButton then
                                            task.wait(0.5)
                                            playButton = findPlayButton()
                                        end
                                        
                                        if playButton and playButton:IsA("TextButton") then
                                            if firesignal then
                                                firesignal(playButton.MouseButton1Click)
                                                firesignal(playButton.Activated)
                                            end
                                            pcall(function() playButton:Activate() end)
                                            sendNotify("Army", "Spawn button triggered")
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
