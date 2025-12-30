# Roblox Army Botnet

Control multiple Roblox accounts using a GTA 5-style command wheel.

## Usage

### Army Soldier (Main Script)

Copy and paste this script into your executor on all accounts you want to control:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/andrewmanueI/roblox_botnet/master/army_soldier.lua"))()
```

### RemoteSpy (Integrated)

To intercept and log remote calls to your army server:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/andrewmanueI/roblox_botnet/master/remotespy.lua"))()
```

This will send all intercepted remote data to your army server at `http://127.0.0.1:5555/remoteinfo` (configurable). Perfect for reverse-engineering game mechanics!

## Controls

- **Hold G**: Open Command Wheel
- **Click Segment**: Send command to all connected soldiers
- **F3**: Terminate script

## Setup

1. Run the Node.js server (`army_server.js`) on your host machine.
2. Ensure the `SERVER_URL` in `army_soldier.lua` matches your server's IP.
3. Execute the script on your Roblox clients.

## RemoteSpy Integration

See [REMOTESPY_INTEGRATION.md](REMOTESPY_INTEGRATION.md) for detailed documentation on the RemoteSpy integration.
