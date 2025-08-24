const { WebSocketServer } = require('ws');
const { execFile } = require('child_process');
const wss = new WebSocketServer({ port: 9001 });
function run(cmd, args) { return new Promise((resolve) => execFile(cmd, args, () => resolve())); }
wss.on('connection', (ws) => {
  ws.on('message', async (msg) => {
    try {
      const data = JSON.parse(msg.toString());
      if (data.type === 'mousemove') await run('xdotool', ['mousemove', String(data.x), String(data.y)]);
      if (data.type === 'click')     await run('xdotool', ['click', '1']);
      if (data.type === 'key')       await run('xdotool', ['key', String(data.key)]);
    } catch {}
  });
});
console.log('Control agent on :9001');
