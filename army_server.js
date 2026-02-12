const http = require('http');

// Store the latest command here
let latestCommand = {
    id: 0,           // Unique ID for the command (timestamp)
    action: "wait",  // The actual command (jump, dance, etc)
    time: Date.now()
};

console.log("⭐⭐ ARMY HTTP SERVER RUNNING (POLLING MODE) ⭐⭐");
console.log(" -> Listening on Port: 5555");

const server = http.createServer((req, res) => {
    // Enable CORS just in case
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST');

    // 1. SOLDIER ENDPOINT (GET)
    // Soldiers poll this to check for new orders.
    if (req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(latestCommand));
        return;
    }

    // 2. COMMANDER ENDPOINT (POST)
    if (req.method === 'POST') {
        let body = '';
        req.on('data', chunk => {
            body += chunk.toString();
        });
        
        req.on('end', () => {
            const newAction = body.trim();
            if (newAction) {
                console.log(`[CMD] New Order Issued: ${newAction}`);
                
                // Update the global state
                latestCommand = {
                    id: Date.now(),
                    action: newAction,
                    time: Date.now()
                };
                
                // Identify "Impulse" commands that should auto-clear
                const impulses = ["jump", "reset", "reload", "voodoo", "rejoin"];
                const isImpulse = impulses.some(imp => newAction.startsWith(imp));

                if (isImpulse) {
                    console.log(`[TIMER] Impulse detected. Clearing in 5s: ${newAction}`);
                    setTimeout(() => {
                        if (latestCommand.action === newAction) {
                            console.log(`[AUTO-CLEAR] Clearing impulse: ${newAction}`);
                            latestCommand = {
                                id: Date.now(),
                                action: "wait",
                                time: Date.now()
                            };
                        }
                    }, 5000);
                } else {
                    console.log(`[PERSISTENT] State command set: ${newAction}`);
                }
            }
            res.writeHead(200);
            res.end("Order Updated");
        });
        return;
    }
});

server.listen(5555, '0.0.0.0');

// Internal Console Support
process.stdin.on('data', (data) => {
    const cmd = data.toString().trim();
    if (!cmd) return;
    console.log(`[INTERNAL] Order: ${cmd}`);
    latestCommand = {
        id: Date.now(),
        action: cmd,
        time: Date.now()
    };
    
    // Auto-clear command after 5 seconds
    setTimeout(() => {
        if (latestCommand.action === cmd) {
            console.log(`[AUTO-CLEAR] Clearing command: ${cmd}`);
            latestCommand = {
                id: Date.now(),
                action: "wait",
                time: Date.now()
            };
        }
    }, 2000);
});
