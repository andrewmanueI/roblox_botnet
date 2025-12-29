const readline = require('readline');

// Configuration
// Using Node's native fetch (Node 18+) or http request
const SERVER_URL = "http://157.20.32.201:5555";

console.log(`Connecting to Army Server (HTTP) at ${SERVER_URL}...`);
console.log("-----------------------------------");
console.log("Type your orders below (e.g., 'jump', 'dance').");
console.log("-----------------------------------");

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

function prompt() {
    process.stdout.write('> ');
}

// Check if server is alive
fetch(SERVER_URL).then(() => {
    console.log("✅ SERVER ONLINE");
    prompt();
}).catch(err => {
    console.log("❌ SERVER OFFLINE OR UNREACHABLE: " + err.message);
    process.exit(1);
});

rl.on('line', async (line) => {
    const command = line.trim();
    if (!command) {
        prompt();
        return;
    }

    try {
        await fetch(SERVER_URL, {
            method: 'POST',
            body: command
        });
        // Success is silent, just prompt again
        prompt();
    } catch (err) {
        console.log(`\n❌ Failed to send order: ${err.message}`);
        prompt();
    }
});
