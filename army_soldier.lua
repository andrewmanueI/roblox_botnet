-- [[ ARMY SOLDIER CLIENT - HYBRID MODE ]]
-- FEATURES:
-- 1. Polls Server for Commands (Every 0.5s)
-- 2. COMMANDER MODE: Alt + Left Click to move the army.
-- 3. TERMINATE: Press F3 to stop the script.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local SERVER_URL = "http://157.20.32.201:5555"
local POLL_RATE = 0.5
local lastCommandId = 0

local isRunning = true
local connections = {} -- Store connections to clean them up later

local function sendNotify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 3
    })
end

print("Army Soldier Started (Hybrid Mode)")
print("PRESS [F3] TO TERMINATE SCRIPT")
sendNotify("Army Script", "Script Started. Press F3 to Stop.")

-- [[ TERMINATION LOGIC (F3) ]]
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if input.KeyCode == Enum.KeyCode.F3 then
        isRunning = false
        print("SCRIPT TERMINATED BY USER (F3)")
        sendNotify("Army Script", "Script Terminated.")
        
        -- Disconnect all events
        for _, conn in ipairs(connections) do
            if conn then conn:Disconnect() end
        end
        connections = {}
        sendNotify("Status", "Offline")
    end
end))

-- [[ COMMANDER INPUTS (Alt + Click) ]]
table.insert(connections, Mouse.Button1Down:Connect(function()
    if isRunning and (UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)) then
        local pos = Mouse.Hit.Position
        local cmd = string.format("walk %.2f,%.2f,%.2f", pos.X, pos.Y, pos.Z)
        
        print("ISSUING MOVE ORDER:", cmd)
        sendNotify("Commander", "Move Order Sent")
        
        -- Send POST request
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
                game:HttpPost(SERVER_URL, cmd)
            end
        end)
    end
end))

-- [[ MAIN POLLING LOOP ]]
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
            
            if jsonSuccess and data then
                if data.id and data.id ~= lastCommandId then
                    lastCommandId = data.id 
                    local action = data.action
                    
                    if action ~= "wait" then
                        print("EXECUTE:", action)
                        sendNotify("New Order", action)
                        
                        -- 1. WALK COMMAND
                        if string.sub(action, 1, 4) == "walk" then
                            local coords = string.split(string.sub(action, 6), ",")
                            if #coords == 3 then
                                local targetPos = Vector3.new(tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3]))
                                sendNotify("Moving", "Walking to Target")
                                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                    LocalPlayer.Character.Humanoid:MoveTo(targetPos)
                                end
                            end
                            
                        -- 2. ACTION COMMANDS
                        else
                            sendNotify("Action", action)
                            
                            if action == "jump" then
                                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                                    LocalPlayer.Character.Humanoid.Jump = true
                                end
                                
                            elseif action == "dance" then
                                game:GetService("ReplicatedStorage"):WaitForChild("DefaultChatSystemChatEvents")
                                    :WaitForChild("SayMessageRequest"):FireServer("/e dance", "All")
                                    
                            elseif action == "ping" then
                                print("Pong!")
                                
                            elseif action == "rejoin" then
                                game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                            end
                        end
                    end
                end
            end
        end
    end
end)
