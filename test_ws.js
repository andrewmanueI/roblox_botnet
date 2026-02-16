const WebSocket = require('ws');

const wss = new WebSocket.Server({ port: 5555 });

console.log('[TEST SERVER] WebSocket server started on ws://157.15.40.37:5555');

wss.on('connection', (ws) => {
    console.log('[TEST SERVER] Client connected');
    
    ws.on('message', (message) => {
        const msg = message.toString();
        console.log(`[TEST SERVER] Received: ${msg}`);
        
        if (msg === 'ping') {
            console.log('[TEST SERVER] Sending: pong');
            ws.send('pong');
        }
    });
    
    ws.on('close', () => {
        console.log('[TEST SERVER] Client disconnected');
    });
});
