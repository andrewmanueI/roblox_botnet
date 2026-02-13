const http = require('http');
const fs = require('fs');
const path = require('path');

const IMPULSES = new Set(["rejoin", "reset", "reload"]);
const BODY_LIMIT_BYTES = 8 * 1024;

let commandSeq = 0;
let latestCommand = {
    id: 0,           // Monotonic command id
    action: "wait",  // The actual command (jump, dance, etc)
    time: Date.now()
};

const clients = new Map(); // clientId -> { id, registeredAt, lastSeen, lastCommandId, executedCommands, status, error }
const crypto = require('crypto');
const commandHistory = new Map(); // commandId -> { id, action, time, type, executedBy }
const MAX_HISTORY = 100;
let impulseTimer = null;
const clientInventories = new Map(); // clientId -> { data, timestamp }

// Storage path
const STORAGE_DIR = path.join(__dirname, 'storage');
const CONFIG_FILE = path.join(STORAGE_DIR, 'config.json');

// Ensure storage directory exists
if (!fs.existsSync(STORAGE_DIR)) {
    fs.mkdirSync(STORAGE_DIR);
}

// Server-wide configurations with persistence
let serverConfigs = {
    auto_pickup: false,
    pickup_whitelist: [], // List of item names (strings)
    routes: {}            // Saved routes: { name: { waypoints: [...] } }
};

const loadConfig = () => {
    if (fs.existsSync(CONFIG_FILE)) {
        try {
            const data = fs.readFileSync(CONFIG_FILE, 'utf8');
            const parsed = JSON.parse(data);
            serverConfigs = { ...serverConfigs, ...parsed };
            console.log(`[STORAGE] Config loaded from ${CONFIG_FILE}`);
        } catch (e) {
            console.error(`[STORAGE] Error loading config: ${e.message}`);
        }
    } else {
        console.log(`[STORAGE] No config file found, using defaults.`);
    }
};

const saveConfig = () => {
    try {
        fs.writeFileSync(CONFIG_FILE, JSON.stringify(serverConfigs, null, 4));
        console.log(`[STORAGE] Config saved to ${CONFIG_FILE}`);
    } catch (e) {
        console.error(`[STORAGE] Error saving config: ${e.message}`);
    }
};

// Initial load
loadConfig();

// Formation state
let formationState = {
    active: false,
    mode: null,           // "Follow" or "Goto"
    shape: null,          // "Line", "Row", or "Circle"
    center: null,         // { x, y, z } for Goto mode
    leaderId: null,       // UserId for Follow mode
    assignments: new Map() // clientId -> formationIndex
};

// Formation position calculators
const calculateFormationPositions = (shape, count, center = { x: 0, y: 0, z: 0 }) => {
    const positions = [];
    
    if (shape === "Line") {
        // Horizontal line
        for (let i = 0; i < count; i++) {
            positions.push({
                x: center.x + (i - Math.floor(count / 2)) * 4,
                y: center.y,
                z: center.z
            });
        }
    } else if (shape === "Row") {
        // Rows of 3
        const rowSize = 3;
        for (let i = 0; i < count; i++) {
            const row = Math.floor(i / rowSize);
            const col = i % rowSize;
            positions.push({
                x: center.x + (col - 1) * 4,
                y: center.y,
                z: center.z + row * 4
            });
        }
    } else if (shape === "Circle") {
        // Circle formation
        const radius = 15;
        for (let i = 0; i < count; i++) {
            const angle = (i / count) * Math.PI * 2;
            positions.push({
                x: center.x + Math.cos(angle) * radius,
                y: center.y,
                z: center.z + Math.sin(angle) * radius
            });
        }
    }
    
    return positions;
};

const assignFormationPositions = () => {
    const clientList = Array.from(clients.keys());
    formationState.assignments.clear();
    
    clientList.forEach((clientId, index) => {
        formationState.assignments.set(clientId, index);
    });
    
    console.log(`[FORMATION] Assigned ${clientList.length} clients to formation positions`);
};

const generateClientId = () => {
    return crypto.randomUUID();
};


const updateCommand = (action, source) => {
    if (!action) return false;

    commandSeq += 1;

    const command = {
        id: commandSeq,
        action,
        time: Date.now(),
        type: (action === 'wait') ? 'persistent' : 'impulse',
        executedBy: []
    };

    latestCommand = command;
    commandHistory.set(commandSeq, command);

    // Prune old commands
    if (commandHistory.size > MAX_HISTORY) {
        const oldestId = Math.min(...commandHistory.keys());
        commandHistory.delete(oldestId);
    }

    console.log(`[CMD:${source}] ${action} (ID: ${commandSeq}, Type: ${command.type})`);

    if (impulseTimer) {
        clearTimeout(impulseTimer);
        impulseTimer = null;
    }

    const isImpulse = command.type === 'impulse';
    if (isImpulse) {
        const currentId = latestCommand.id;
        // All impulses now clear in 1s
        const timeout = 1000;
        console.log(`[TIMER] Impulse detected. Clearing in ${timeout}ms: ${action}`);
        impulseTimer = setTimeout(() => {
            if (latestCommand.id === currentId) {
                console.log(`[AUTO-CLEAR] Clearing impulse: ${action}`);
                latestCommand = {
                    id: ++commandSeq,
                    action: "wait",
                    time: Date.now(),
                    type: 'persistent',
                    executedBy: []
                };
                commandHistory.set(commandSeq, latestCommand);
            }
        }, timeout);
    } else {
        console.log(`[PERSISTENT] State command set: ${action}`);
    }

    return true;
};

const cleanupClients = () => {
    const now = Date.now();
    for (const [id, client] of clients.entries()) {
        if (now - client.lastSeen > 10000) { // 10 seconds timeout
            console.log(`[CLIENT] Time-out: ${id}`);
            clients.delete(id);
        }
    }
};
setInterval(cleanupClients, 5000); // Check every 5 seconds

console.log("ARMY HTTP SERVER RUNNING (POLLING MODE)");
console.log("Listening on Port: 5555");

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    // Client registration endpoint (Handled as ANY method to be flexible, but soldier will POST)
    if (req.url === '/register') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            let clientId;
            try {
                const data = body ? JSON.parse(body) : {};
                clientId = data.name || data.displayName || generateClientId();
            } catch (e) {
                clientId = generateClientId();
            }

            clients.set(clientId, {
                id: clientId,
                registeredAt: Date.now(),
                lastSeen: Date.now(),
                lastCommandId: 0,
                executedCommands: new Set()
            });
            console.log(`[REGISTER] New client: ${clientId}`);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ clientId }));
        });
        return;
    }

    if (req.method === 'GET') {
        // List clients endpoint
        if (req.url === '/clients') {
            const clientList = [];
            for (const [id, client] of clients.entries()) {
                clientList.push({
                    id,
                    registeredAt: client.registeredAt,
                    lastSeen: client.lastSeen,
                    lastCommandId: client.lastCommandId,
                });
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(clientList));
            return;
        }

        // List cached inventories endpoint
        if (req.url === '/inventories') {
            const inventoryData = {};
            for (const [clientId, info] of clientInventories.entries()) {
                inventoryData[clientId] = info.data;
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(inventoryData));
            return;
        }

        // Server status endpoint
        if (req.url === '/status') {
            const recentCommands = [];
            for (const [id, cmd] of commandHistory.entries()) {
                recentCommands.push({
                    id: cmd.id,
                    action: cmd.action,
                    time: cmd.time,
                    type: cmd.type,
                    executedCount: cmd.executedBy ? cmd.executedBy.length : 0
                });
            }
            recentCommands.sort((a, b) => b.id - a.id);

            const status = {
                server: {
                    uptime: Date.now(),
                    clients: clients.size,
                    totalCommands: commandHistory.size,
                    latestCommandId: latestCommand.id
                },
                commands: recentCommands.slice(0, 10)
            };
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(status, null, 2));
            return;
        }

        // Server config endpoint
        if (req.url === '/config') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(serverConfigs));
            return;
        }

        // Command details endpoint
        if (req.url.startsWith('/command/')) {
            const commandId = parseInt(req.url.split('/')[2]);
            const command = commandHistory.get(commandId);

            if (!command) {
                res.writeHead(404);
                res.end('Command not found');
                return;
            }

            const details = {
                id: command.id,
                action: command.action,
                time: command.time,
                type: command.type,
                executedBy: command.executedBy ? command.executedBy.map(exec => {
                    const client = clients.get(exec.clientId);
                    return {
                        clientId: exec.clientId,
                        executedAt: exec.executedAt,
                        success: exec.success,
                        error: exec.error,
                        lastSeen: client ? client.lastSeen : null
                    };
                }) : [],
                totalClients: clients.size,
                executionRate: clients.size > 0 ? ((command.executedBy ? command.executedBy.length : 0) / clients.size * 100).toFixed(1) + '%' : '0%'
            };
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(details, null, 2));
            return;
        }

        // Poll for latest command (with ETag support)
        if (req.url === '/') {
            const ifNoneMatch = req.headers['if-none-match'];
            const currentEtag = `"${latestCommand.id}"`;

            if (ifNoneMatch === currentEtag) {
                res.writeHead(304);
                res.end();
                return;
            }

            res.writeHead(200, {
                'Content-Type': 'application/json',
                'ETag': currentEtag,
                'Cache-Control': 'no-cache'
            });
            res.end(JSON.stringify(latestCommand));
            return;
        }

        // List routes endpoint
        if (req.url === '/routes') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(serverConfigs.routes || {}));
            return;
        }

        res.writeHead(404);
        res.end('Not Found');
        return;
    }

    if (req.method === 'POST') {
        // Heartbeat endpoint
        if (req.url === '/heartbeat') {
            let body = '';
            req.on('data', chunk => { body += chunk.toString(); });
            req.on('end', () => {
                try {
                    const { clientId } = JSON.parse(body);
                    const client = clients.get(clientId);
                    if (client) {
                        client.lastSeen = Date.now();
                        res.writeHead(200);
                        res.end('OK');
                    } else {
                        res.writeHead(404);
                        res.end('Client not found');
                    }
                } catch (e) {
                    res.writeHead(400);
                    res.end('Invalid request');
                }
            });
            return;
        }

        // Command acknowledgment endpoint
        if (req.url === '/acknowledge') {
            let body = '';
            req.on('data', chunk => { body += chunk.toString(); });
            req.on('end', () => {
                try {
                    const parsed = JSON.parse(body);
                    const clientId = parsed.clientId;
                    const commandId = parsed.commandId;
                    const success = (parsed.success === undefined) ? true : parsed.success;

                    // Inventory reports have historically been sent in `error` even on success.
                    // Newer clients may send them in `result` / `report`.
                    const error = (parsed.error === undefined) ? null : parsed.error;
                    const result = (parsed.result !== undefined) ? parsed.result
                        : (parsed.report !== undefined) ? parsed.report
                        : (parsed.data !== undefined) ? parsed.data
                        : null;

                    const payloadRaw = (result !== null && result !== undefined) ? result : error;
                    const client = clients.get(clientId);

                    if (!client) {
                        res.writeHead(404);
                        res.end('Client not found');
                        return;
                    }

                    // Record command execution in client
                    if (!client.executedCommands) {
                        client.executedCommands = new Set();
                    }

                    client.executedCommands.add(commandId);
                    client.lastCommandId = commandId;
                    client.lastSeen = Date.now();

                    // Avoid "[object Object]" spam on JSON payloads.
                    const logPayload = (typeof payloadRaw === 'string') ? payloadRaw : (payloadRaw ? '[json]' : '');
                    console.log(`[ACK] Client ${clientId} executed command ${commandId} ${success ? 'successfully' : 'failed'}${logPayload ? ': ' + logPayload : ''}`);

                    // Record in command history
                    const command = commandHistory.get(commandId);
                    if (command) {
                        if (!command.executedBy) {
                            command.executedBy = [];
                        }
                        
                        // Try to parse payload as JSON (relay data)
                        let processedPayload = payloadRaw;
                        if (typeof payloadRaw === 'string' && (payloadRaw.startsWith('[') || payloadRaw.startsWith('{'))) {
                            try {
                                processedPayload = JSON.parse(payloadRaw);
                            } catch (e) {
                                // Not valid JSON, keep as string
                            }
                        }

                        command.executedBy.push({
                            clientId,
                            executedAt: Date.now(),
                            success,
                            data: processedPayload, // Store as 'data' for clarity if JSON
                            error: (success ? null : (typeof processedPayload === 'string' ? processedPayload : null)),
                            lastSeen: client ? client.lastSeen : null
                        });

                        // Cache inventory if this was a report command
                        if (command.action.startsWith('inventory_report_all') && processedPayload && typeof processedPayload === 'object') {
                            clientInventories.set(clientId, {
                                data: processedPayload,
                                timestamp: Date.now()
                            });
                        }
                    }

                    res.writeHead(200);
                    res.end('OK');
                } catch (e) {
                    console.error('[ACK] Error:', e.message);
                    res.writeHead(400);
                    res.end('Invalid request');
                }
            });
            return;
        }

        // Default POST: issue new command
        if (req.url === '/') {
            let body = '';
            let received = 0;

            req.on('data', chunk => {
                received += chunk.length;
                if (received > BODY_LIMIT_BYTES) {
                    res.writeHead(413);
                    res.end("Body too large");
                    req.destroy();
                    return;
                }
                body += chunk.toString();
            });

            req.on('end', () => {
                const newAction = body.trim();
                
                // Handle formation commands specially
                if (newAction.startsWith('formation_follow ')) {
                    // Format: formation_follow <userId> <shape> <offsets_json>
                    // Offsets are now calculated by commander and sent to server
                    const parts = newAction.split(' ');
                    if (parts.length >= 4) {
                        formationState.active = true;
                        formationState.mode = "Follow";
                        formationState.leaderId = parts[1];
                        formationState.shape = parts[2];
                        formationState.center = null;
                        
                        // Offsets are already calculated by commander
                        const offsetsJson = parts[3];
                        
                        console.log(`[FORMATION] Follow mode: ${formationState.shape} around user ${formationState.leaderId}`);
                        console.log(`[FORMATION] Using commander-calculated offsets`);
                        
                        // Broadcast formation to all clients
                        if (!updateCommand(newAction, "HTTP")) {
                            res.writeHead(400);
                            res.end("Missing command");
                            return;
                        }
                    }
                } else if (newAction.startsWith('formation_goto ')) {
                    // Format: formation_goto <x,y,z> <shape> <positions_json>
                    // Positions are now calculated by commander and sent to server
                    const parts = newAction.split(' ');
                    if (parts.length >= 4) {
                        const coords = parts[1].split(',');
                        if (coords.length === 3) {
                            formationState.active = true;
                            formationState.mode = "Goto";
                            formationState.shape = parts[2];
                            formationState.center = {
                                x: parseFloat(coords[0]),
                                y: parseFloat(coords[1]),
                                z: parseFloat(coords[2])
                            };
                            formationState.leaderId = null;
                            
                            // Positions are already calculated by commander
                            const positionsJson = parts[3];
                            
                            console.log(`[FORMATION] Goto mode: ${formationState.shape} at (${formationState.center.x}, ${formationState.center.y}, ${formationState.center.z})`);
                            console.log(`[FORMATION] Using commander-calculated positions`);
                            
                            // Broadcast formation to all clients with positions from commander
                            if (!updateCommand(newAction, "HTTP")) {
                                res.writeHead(400);
                                res.end("Missing command");
                                return;
                            }
                        }
                    }
                } else if (newAction === 'formation_clear') {
                    formationState.active = false;
                    formationState.mode = null;
                    formationState.shape = null;
                    formationState.center = null;
                    formationState.leaderId = null;
                    formationState.assignments.clear();
                    
                    console.log(`[FORMATION] Cleared formation`);
                    
                    if (!updateCommand(newAction, "HTTP")) {
                        res.writeHead(400);
                        res.end("Missing command");
                        return;
                    }
                } else {
                    // Regular command
                    if (!updateCommand(newAction, "HTTP")) {
                        res.writeHead(400);
                        res.end("Missing command");
                        return;
                    }
                }
                
                res.writeHead(200);
                res.end("Order Updated");
            });
            return;
        }

        // Server config update endpoint
        if (req.url === '/config') {
            let body = '';
            req.on('data', chunk => { body += chunk.toString(); });
            req.on('end', () => {
                try {
                    const newConfig = JSON.parse(body);
                    if (newConfig.auto_pickup !== undefined) {
                        serverConfigs.auto_pickup = !!newConfig.auto_pickup;
                    }
                    if (newConfig.pickup_whitelist !== undefined && Array.isArray(newConfig.pickup_whitelist)) {
                        serverConfigs.pickup_whitelist = newConfig.pickup_whitelist;
                    }
                    saveConfig();
                    console.log(`[CONFIG] Updated: auto_pickup=${serverConfigs.auto_pickup}, whitelist=[${serverConfigs.pickup_whitelist.join(', ')}]`);
                    updateCommand("refresh_configs", "CONFIG_UPDATE");
                    res.writeHead(200);
                    res.end('Config Updated');
                } catch (e) {
                    res.writeHead(400);
                    res.end('Invalid config data');
                }
            });
            return;
        }

        // Route save/update endpoint
        if (req.url === '/routes') {
            let body = '';
            req.on('data', chunk => { body += chunk.toString(); });
            req.on('end', () => {
                try {
                    const { name, waypoints } = JSON.parse(body);
                    if (!name || !waypoints) throw new Error("Missing name or waypoints");
                    
                    serverConfigs.routes[name] = { waypoints };
                    saveConfig();
                    console.log(`[ROUTES] Saved route: ${name}`);
                    res.writeHead(200);
                    res.end('Route Saved');
                } catch (e) {
                    res.writeHead(400);
                    res.end('Invalid route data: ' + e.message);
                }
            });
            return;
        }

        // Route delete endpoint
        if (req.url.startsWith('/routes/')) {
            const routeName = decodeURIComponent(req.url.slice(8));
            if (serverConfigs.routes[routeName]) {
                delete serverConfigs.routes[routeName];
                saveConfig();
                console.log(`[ROUTES] Deleted route: ${routeName}`);
                res.writeHead(200);
                res.end('Route Deleted');
            } else {
                res.writeHead(404);
                res.end('Route not found');
            }
            return;
        }

        res.writeHead(404);
        res.end('Not Found');
        return;
    }

    res.writeHead(405);
    res.end("Method Not Allowed");
});

server.listen(5555, '0.0.0.0');

// Client cleanup routine - remove inactive clients
setInterval(() => {
    const now = Date.now();
    const TIMEOUT_MS = 10000; // 10 seconds timeout
    let removedCount = 0;

    for (const [clientId, client] of clients.entries()) {
        if (now - client.lastSeen > TIMEOUT_MS) {
            clients.delete(clientId);
            removedCount++;
            console.log(`[CLEANUP] Removed inactive client: ${clientId}`);
        }
    }

    if (removedCount > 0) {
        console.log(`[CLEANUP] Removed ${removedCount} inactive clients. Active: ${clients.size}`);
    }
}, 5000); // Check every 5 seconds

// Admin console monitoring
setInterval(() => {
    const now = Date.now();
    const activeClients = Array.from(clients.values()).filter(
        c => now - c.lastSeen < 10000
    ).length;

    // Cleanup inventories older than 1 minute
    const INVENTORY_TIMEOUT = 60000;
    for (const [clientId, info] of clientInventories.entries()) {
        if (now - info.timestamp > INVENTORY_TIMEOUT) {
            clientInventories.delete(clientId);
        }
    }

    if (latestCommand.id > 0) {
        const command = commandHistory.get(latestCommand.id);
        const executedCount = command ? command.executedBy.length : 0;
        const execRate = activeClients > 0 ? (executedCount / activeClients * 100).toFixed(1) : 0;

        console.log(`[STATUS] Active: ${activeClients}/${clients.size} | Latest CMD: ${latestCommand.id} | Executed: ${execRate}%`);
    } else {
        console.log(`[STATUS] Active: ${activeClients}/${clients.size} | No active command`);
    }
}, 10000); // Every 10 seconds

process.stdin.on('data', (data) => {
    const cmd = data.toString().trim();
    if (!cmd) return;
    updateCommand(cmd, "INTERNAL");
});
