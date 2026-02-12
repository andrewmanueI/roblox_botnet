-- Find & Click Spawn Button (Exact "PLAY") - FORCE CLICK
-- Tries multiple methods to click the button: VirtualInputManager, firesignal (exploit), and Property changes.

local Players = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TARGET_NAMES = {"PLAY"}

-- Helper: Try to click the button using EVERY method known to exploits
local function forceClick(btn)
    print("--------------------------------------------------")
    print("FORCE CLICKING: " .. btn:GetFullName())
    
    if not btn.Visible then
        warn("WARNING: Button is NOT Visible! Making it visible...")
        btn.Visible = true
    end
    if not btn.Active then
        btn.Active = true
    end

    -- Method 1: VirtualInputManager (Official Input Simulation)
    local pos = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
    task.wait(0.05)
    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
    print(" [1] Fired VirtualInputManager (Click)")

    -- Method 2: firesignal (Standard Exploit Function)
    if firesignal then
        pcall(function()
            firesignal(btn.MouseButton1Down)
            firesignal(btn.MouseButton1Click)
            firesignal(btn.MouseButton1Up)
            firesignal(btn.Activated)
            print(" [2] Fired signals via firesignal()")
        end)
    else
        print(" [2] 'firesignal' not supported by executor (Skipped)")
    end
    
    -- Method 3: Direct Function Call (If supported by game code)
    if getconnections then
        for _, conn in pairs(getconnections(btn.MouseButton1Click)) do
            conn:Fire()
            print(" [3] Fired getconnections(MouseButton1Click)")
        end
        for _, conn in pairs(getconnections(btn.Activated)) do
            conn:Fire()
            print(" [3] Fired getconnections(Activated)")
        end
    else
        print(" [3] 'getconnections' not supported by executor (Skipped)")
    end

    print("--------------------------------------------------")
end

local function scanGui(parent)
    for _, v in ipairs(parent:GetDescendants()) do
        if v:IsA("TextButton") or v:IsA("ImageButton") then
            
            local matched = false
            
            -- Check Exact Name
            for _, name in ipairs(TARGET_NAMES) do
                if v.Name == name then
                    matched = true
                    break
                end
            end
            
            -- Check Exact Text (if TextButton)
            if not matched and v:IsA("TextButton") then
                for _, name in ipairs(TARGET_NAMES) do
                    if v.Text == name then
                        matched = true
                        break
                    end
                end
            end
            
            if matched then
                print("Found match! Clicking in 3 seconds...")
                task.wait(3) -- User requested delay
                forceClick(v)
                return true
            end
        end
    end
    return false
end

print("Scanning for 'PLAY' Button...")
local found = scanGui(playerGui)

if not found then
    print("No button with Name or Text exactly 'PLAY' found.")
end
