# RemoteSpy → Army Server Integration

## Overview
This setup allows the RemoteSpy to intercept Roblox remote calls and send them to your Army Server as **informational data only**. The server logs these remotes but **does NOT relay them to soldiers**.

## How It Works

### 1. **RemoteSpy (remotespy.lua)**
- Intercepts all `RemoteEvent:FireServer()` and `RemoteFunction:InvokeServer()` calls
- Serializes the remote data (name, path, type, arguments)
- Sends HTTP POST request to `http://127.0.0.1:5555/remoteinfo`

### 2. **Army Server (army_server.js)**
- **Endpoint 1**: `GET /` - Soldiers poll this for commands (unchanged)
- **Endpoint 2**: `POST /` - Commander sends commands here (unchanged)
- **Endpoint 3**: `POST /remoteinfo` - **NEW** - Receives remote spy data (NOT relayed to soldiers)
- **Endpoint 4**: `GET /remoteinfo` - **NEW** - View logged remote data

## Configuration

### In `remotespy.lua` (lines 5-13):
```lua
local realconfigs = {
    sendToArmyServer = true, -- Enable/disable sending to army server
    armyServerUrl = "http://127.0.0.1:5555/remoteinfo" -- Server endpoint
}
```

### Toggle at runtime:
```lua
-- Disable sending to server
configs.sendToArmyServer = false

-- Change server URL
configs.armyServerUrl = "http://192.168.1.100:5555/remoteinfo"
```

## Usage

### 1. Start the Army Server
```bash
cd c:\Users\Lenovo\Downloads\scripts\roblox_army
node army_server.js
```

You should see:
```
⭐⭐ ARMY HTTP SERVER RUNNING (POLLING MODE) ⭐⭐
 -> Listening on Port: 5555
 -> Remote Spy Info Endpoint: POST /remoteinfo
```

### 2. Run RemoteSpy in Roblox
Execute `remotespy.lua` in your Roblox executor

### 3. Monitor Remote Calls
As you play the game, the server console will show:
```
[REMOTE SPY] PickupItem (RemoteEvent)
  └─ Args: [{"type":"Instance","value":"workspace.Items.Apple"}]
```

### 4. View Logged Remotes
Open browser or use curl:
```bash
curl http://localhost:5555/remoteinfo
```

Response:
```json
{
  "count": 5,
  "logs": [
    {
      "remoteName": "PickupItem",
      "remotePath": "game.ReplicatedStorage.Remotes.PickupItem",
      "remoteType": "RemoteEvent",
      "method": "FireServer",
      "args": [
        {"type": "Instance", "value": "workspace.Items.Apple"}
      ],
      "timestamp": 1735549200000
    }
  ]
}
```

## Data Flow

```
┌─────────────────┐
│  Roblox Game    │
│  (Player picks  │
│   up an item)   │
└────────┬────────┘
         │
         │ RemoteEvent:FireServer(item)
         ▼
┌─────────────────┐
│  RemoteSpy      │
│  (Intercepts)   │
└────────┬────────┘
         │
         │ HTTP POST /remoteinfo
         │ {remoteName, args, ...}
         ▼
┌─────────────────┐
│  Army Server    │
│  (Logs only,    │
│   NOT relayed)  │
└─────────────────┘
```

## Important Notes

1. **Soldiers are NOT affected** - Remote spy data is completely separate from command system
2. **Last 100 remotes** - Server keeps only the most recent 100 remote calls
3. **Auto-serialization** - Complex types (Vector3, CFrame, etc.) are converted to strings
4. **Non-blocking** - Uses `spawn()` and `pcall()` to prevent lag

## For Your Pickup Script

Now you can:
1. Pick up an item manually
2. Check `http://localhost:5555/remoteinfo` to see the exact remote and arguments
3. Write your auto-pickup script based on the logged data

Example:
```lua
-- Based on logged data, you might see:
-- Remote: game.ReplicatedStorage.Remotes.PickupItem
-- Args: [{"type":"Instance","value":"workspace.Items.Apple"}]

local PickupRemote = game:GetService("ReplicatedStorage").Remotes.PickupItem

for _, item in pairs(workspace.Items:GetChildren()) do
    PickupRemote:FireServer(item)
    task.wait(0.1)
end
```
