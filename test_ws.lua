-- WebSocket Test Client for Volt API

local function sendNotify(title, text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = title,
        Text = text,
        Duration = 5
    })
end

print("[TEST CLIENT] Connecting to WebSocket...")
local ws = WebSocket.connect("ws://157.15.40.37:5555")

ws.OnMessage:Connect(function(message)
    print("[TEST CLIENT] Received:", message)
    if message == "pong" then
        sendNotify("WebSocket Test", "Received PONG from server!")
    end
end)

ws.OnClose:Connect(function()
    print("[TEST CLIENT] Connection closed")
    sendNotify("WebSocket Test", "Connection closed.")
end)

task.wait(2)
print("[TEST CLIENT] Sending PING...")
ws:Send("ping")

-- Keep script alive for the test
task.wait(10)
print("[TEST CLIENT] Closing connection...")
ws:Close()
