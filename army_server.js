const http = require('http');

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
        if (now - client.lastSeen > 60000) { // 60 seconds timeout
            console.log(`[CLIENT] Time-out: ${id}`);
            clients.delete(id);
        }
    }
};
setInterval(cleanupClients, 10000);

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

    if (req.method === 'GET') {
        // Client registration endpoint
        if (req.url === '/register') {
            const clientId = generateClientId();
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
            return;
        }

        // List clients endpoint
        if (req.url === '/clients') {
            const clientList = [];
            for (const [id, client] of clients.entries()) {
                clientList.push({
                    id,
                    registeredAt: client.registeredAt,
                    lastSeen: client.lastSeen,
                    lastCommandId: client.lastCommandId,
                    executedCount: client.executedCommands ? client.executedCommands.size : 0
                });
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(clientList));
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
                    const { clientId, commandId, success = true, error = null } = JSON.parse(body);
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

                    console.log(`[ACK] Client ${clientId} executed command ${commandId} ${success ? 'successfully' : 'failed'}${error ? ': ' + error : ''}`);

                    // Record in command history
                    const command = commandHistory.get(commandId);
                    if (command) {
                        if (!command.executedBy) {
                            command.executedBy = [];
                        }
                        command.executedBy.push({
                            clientId,
                            executedAt: Date.now(),
                            success,
                            error
                        });
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
                if (!updateCommand(newAction, "HTTP")) {
                    res.writeHead(400);
                    res.end("Missing command");
                    return;
                }
                res.writeHead(200);
                res.end("Order Updated");
            });
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
    const TIMEOUT_MS = 60000; // 1 minute timeout
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
}, 30000); // Check every 30 seconds

// Admin console monitoring
setInterval(() => {
    const now = Date.now();
    const activeClients = Array.from(clients.values()).filter(
        c => now - c.lastSeen < 60000
    ).length;

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
