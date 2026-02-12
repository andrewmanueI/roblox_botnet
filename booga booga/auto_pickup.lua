-- Auto-Pickup Script (F1: Single, F2: All, F3: Terminate)
-- Usage:
-- F1: Pick up nearest item
-- F2: Pick up ALL nearby items (simultaneous)
-- F3: Disconnect keybinds and stop script

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PICKUP_RANGE = 30 -- Studs (Max range confirmed 30)
local FALLBACK_PACKET_ID = 213 -- Change manually if your server rotates to a different ID
local AUTO_START_ON_PARTIAL = true -- true: allow start with warnings, false: require all critical checks
local DEBUG_SEND_RESULT = false -- Prints per-send diagnostics (good for troubleshooting, noisy for mass pickup)
local AUTO_PROBE_PACKET_ID = false -- If dynamic read fails, probe packet IDs by testing pickup behavior
local PROBE_ID_MIN = 180 -- Narrow range keeps probes fast and less noisy
local PROBE_ID_MAX = 240 -- Adjust if needed
local PROBE_DELAY = 0.12 -- Delay between probes

-- 1. Helper: Find child by name recursively without using unsupported API overloads
local function findDescendantByName(parent, targetName)
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == targetName then
            return child
        end
        local found = findDescendantByName(child, targetName)
        if found then
            return found
        end
    end
    return nil
end

local function logCheck(name, ok, detail)
    if ok then
        print(string.format("[OK]   %s - %s", name, detail or ""))
    else
        warn(string.format("[FAIL] %s - %s", name, detail or ""))
    end
end

-- 2. Find ByteNet Remote
local function findByteNetRemote()
    -- Prioritize "ByteNetReliable"
    local reliable = findDescendantByName(ReplicatedStorage, "ByteNetReliable")
    if reliable then return reliable end
    
    -- Fallback to "ByteNet"
    local standard = findDescendantByName(ReplicatedStorage, "ByteNet")
    if standard then return standard end

    return nil
end

local ByteNetRemote = findByteNetRemote()

-- 3. Get Packet ID (dynamic if possible, fallback if executor can't handle module require)
local packetID = FALLBACK_PACKET_ID
local gotRuntimeID = false
local packetReadDetail = "not attempted"

local okOuter, outerErr = pcall(function()
    local ByteNetModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ByteNet")
    local Replicated = ByteNetModule:WaitForChild("replicated")
    if not Replicated:FindFirstChild("values") then
        packetReadDetail = "Replicated.values module not found"
        return
    end

    local okRequire, Values = pcall(require, Replicated.values)
    if not okRequire or not Values then
        packetReadDetail = "require(values) failed: " .. tostring(Values)
        return
    end

    local okRead, boogaData = pcall(function()
        return Values.access("booga"):read()
    end)
    if not okRead then
        packetReadDetail = "Values.access('booga'):read() failed: " .. tostring(boogaData)
        return
    end

    if not boogaData then
        packetReadDetail = "boogaData is nil"
        return
    end

    if not boogaData.packets then
        packetReadDetail = "boogaData.packets is nil"
        return
    end

    if not boogaData.packets.Pickup then
        packetReadDetail = "boogaData.packets.Pickup is nil"
        return
    end

    if type(boogaData.packets.Pickup) ~= "number" then
        packetReadDetail = "boogaData.packets.Pickup is not a number"
        return
    end

    if boogaData and boogaData.packets and boogaData.packets.Pickup then
        packetID = boogaData.packets.Pickup
        gotRuntimeID = true
        packetReadDetail = "success"
    end
end)

if gotRuntimeID then
    print("Auto-Pickup: Packet ID set to " .. packetID)
else
    if not okOuter then
        packetReadDetail = "packet read outer failure: " .. tostring(outerErr)
    end
    warn("Auto-Pickup: Runtime packet read failed, using fallback ID: " .. packetID)
end

-- 4. Preflight Diagnostics
local function getItemsFolder()
    return workspace:FindFirstChild("Items")
end

local function getCharacterRoot()
    local char = Players.LocalPlayer.Character
    if char and char.PrimaryPart then
        return char.PrimaryPart
    end
    return nil
end

local function runDiagnostics()
    print("--------------------------------------------------")
    print("Auto-Pickup Preflight Diagnostics")
    print("--------------------------------------------------")

    local checks = {
        remote = ByteNetRemote ~= nil,
        bufferSupport = (buffer ~= nil and buffer.fromstring ~= nil),
        packetDynamic = gotRuntimeID,
        packetUsable = (type(packetID) == "number" and packetID >= 0 and packetID <= 255),
        itemsFolder = getItemsFolder() ~= nil,
        characterRoot = getCharacterRoot() ~= nil,
    }

    logCheck("ByteNet Remote", checks.remote, checks.remote and ByteNetRemote:GetFullName() or "ByteNetReliable/ByteNet not found")
    logCheck("Buffer Support", checks.bufferSupport, checks.bufferSupport and "buffer.fromstring available" or "fallback to string payload")
    logCheck("Packet ID (Dynamic)", checks.packetDynamic, checks.packetDynamic and tostring(packetID) or "using fallback ID")
    if not checks.packetDynamic then
        warn("Packet ID dynamic read detail: " .. tostring(packetReadDetail))
    end
    logCheck("Packet ID (Usable)", checks.packetUsable, tostring(packetID))
    logCheck("Workspace.Items", checks.itemsFolder, checks.itemsFolder and "found" or "folder missing")
    logCheck("Character Root", checks.characterRoot, checks.characterRoot and "found" or "character or PrimaryPart missing")

    print("--------------------------------------------------")

    local criticalOK = checks.remote and checks.packetUsable
    if not criticalOK then
        warn("Auto-Pickup: Critical checks failed. Script will not start.")
        return false
    end

    if not (checks.itemsFolder and checks.characterRoot) and not AUTO_START_ON_PARTIAL then
        warn("Auto-Pickup: Environment checks incomplete and AUTO_START_ON_PARTIAL=false. Not starting.")
        return false
    end

    return true
end

local function buildPayload(testPacketID, entityID)
    local b1 = bit32.band(entityID, 0xFF)
    local b2 = bit32.band(bit32.rshift(entityID, 8), 0xFF)
    local b3 = bit32.band(bit32.rshift(entityID, 16), 0xFF)
    local b4 = bit32.band(bit32.rshift(entityID, 24), 0xFF)

    local payloadStr = string.char(0) .. string.char(testPacketID) .. string.char(b1, b2, b3, b4)
    if buffer and buffer.fromstring then
        return buffer.fromstring(payloadStr)
    end
    return payloadStr
end

local function firePickupPacket(testPacketID, item)
    if not item then return end
    local entityID = item:GetAttribute("EntityID")
    if not entityID then return false, "missing entityID" end

    local payload = buildPayload(testPacketID, entityID)
    local ok, err = pcall(function()
        ByteNetRemote:FireServer(payload)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- 4. Pickup Function
local function pickupItem(item)
    if not item then return end
    local entityID = item:GetAttribute("EntityID")
    if not entityID then return end

    local ok, err = firePickupPacket(packetID, item)
    if not ok then
        warn("Auto-Pickup: FireServer failed -> " .. tostring(err))
    elseif DEBUG_SEND_RESULT then
        print(string.format("Auto-Pickup: Sent packetID=%d entityID=%d item=%s", packetID, entityID, item.Name))
        task.delay(0.25, function()
            local stillThere = item and item.Parent ~= nil
            if stillThere then
                warn(string.format("Auto-Pickup: Item still exists after send (%s, EntityID=%d). Packet may be wrong or out of server range.", item.Name, entityID))
            else
                print(string.format("Auto-Pickup: Item disappeared after send (%s, EntityID=%d).", item.Name, entityID))
            end
        end)
    end
end

-- 5. Logic Managers

-- F1 Logic: Single Nearest
local function pickupNearest()
    local root = getCharacterRoot()
    local folder = getItemsFolder()
    if not root or not folder then return end
    
    local nearestObj = nil
    local nearestDist = PICKUP_RANGE
    
    for _, v in ipairs(folder:GetChildren()) do
        local entityID = v:GetAttribute("EntityID")
        if entityID then
            local pos = v:IsA("BasePart") and v.Position or (v:IsA("Model") and v.PrimaryPart and v.PrimaryPart.Position)
            if pos then
                local dist = (root.Position - pos).Magnitude
                if dist < nearestDist then
                    nearestDist = dist
                    nearestObj = v
                end
            end
        end
    end
    
    if nearestObj then
        print("F1: Picking up " .. nearestObj.Name)
        pickupItem(nearestObj)
    else
        print("F1: No items in range.")
    end
end

-- F2 Logic: Pick Up ALL
local function pickupAll()
    local root = getCharacterRoot()
    local folder = getItemsFolder()
    if not root or not folder then return end
    
    local count = 0
    for _, v in ipairs(folder:GetChildren()) do
        local entityID = v:GetAttribute("EntityID")
        if entityID then
            local pos = v:IsA("BasePart") and v.Position or (v:IsA("Model") and v.PrimaryPart and v.PrimaryPart.Position)
            if pos then
                local dist = (root.Position - pos).Magnitude
                if dist < PICKUP_RANGE then
                    pickupItem(v)
                    count = count + 1
                end
            end
        end
    end
    print("F2: Mass pickup fired for " .. count .. " items.")
end

local function probePacketID()
    if gotRuntimeID then
        return true
    end
    if not AUTO_PROBE_PACKET_ID then
        return true
    end

    local root = getCharacterRoot()
    local folder = getItemsFolder()
    if not root or not folder then
        warn("Auto-Pickup: Probe skipped (missing character root or workspace.Items).")
        return true
    end

    local target = nil
    local nearestDist = PICKUP_RANGE
    for _, v in ipairs(folder:GetChildren()) do
        local entityID = v:GetAttribute("EntityID")
        if entityID then
            local pos = v:IsA("BasePart") and v.Position or (v:IsA("Model") and v.PrimaryPart and v.PrimaryPart.Position)
            if pos then
                local dist = (root.Position - pos).Magnitude
                if dist < nearestDist then
                    nearestDist = dist
                    target = v
                end
            end
        end
    end

    if not target then
        warn("Auto-Pickup: Probe skipped (no nearby target in range).")
        return true
    end

    print(string.format("Auto-Pickup: Probing packet IDs %d..%d using target '%s'...", PROBE_ID_MIN, PROBE_ID_MAX, target.Name))
    for id = PROBE_ID_MIN, PROBE_ID_MAX do
        if not target.Parent then
            break
        end
        firePickupPacket(id, target)
        task.wait(PROBE_DELAY)
        if not target.Parent then
            packetID = id
            print("Auto-Pickup: Probe success. Discovered Pickup packet ID = " .. packetID)
            return true
        end
    end

    warn("Auto-Pickup: Probe did not find a working packet ID in configured range.")
    return true
end

-- 6. Keybind Connection
local connection
if runDiagnostics() then
    probePacketID()

    connection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        
        if input.KeyCode == Enum.KeyCode.F1 then
            pickupNearest()
        elseif input.KeyCode == Enum.KeyCode.F2 then
            pickupAll()
        elseif input.KeyCode == Enum.KeyCode.F3 then
            print("F3: Terminating Auto-Pickup Script.")
            if connection then
                connection:Disconnect()
                connection = nil
            end
        end
    end)

    print("--------------------------------------------------")
    print("Auto-Pickup Loaded!")
    print("F1: Pick up nearest item")
    print("F2: Pick up ALL nearby items")
    print("F3: Terminate Script")
    print("--------------------------------------------------")
else
    warn("Auto-Pickup did not start. Fix the failed checks above first.")
end
