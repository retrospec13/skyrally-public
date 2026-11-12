// SkyRally clip recorder (TEST_LIST "clip" evidence): grabs the lane's own Studio window (skyrally_1.rbxlx) with the
// Studio MCP screen_capture tool as fast as it answers, for <seconds>, into <outDir>\f_00001.<ext> ..., then writes
// <outDir>\timing.json ({frames, seconds, fps, ext}). tools/clip.py runs it next to a test and encodes the MP4 on the PC.
// V5-3: screen_capture answers JPEG, so <ext> follows the image's own bytes (jpg / png) and clip.py reads it back.
// Usage: node clip_rec.js <outDir> <seconds>
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const [, , outDir, secondsArg] = process.argv;
const SECONDS = Number(secondsArg || 30);
const PLACE = process.env.SKY_PLACE || 'skyrally_1.rbxlx';
fs.mkdirSync(outDir, { recursive: true });

const mcp = spawn('cmd.exe', ['/c', 'mcp.bat'], { cwd: process.env.LOCALAPPDATA + '\\Roblox' });
let buf = '';
const waiters = {};
mcp.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    try { const m = JSON.parse(line); if (m.id !== undefined && waiters[m.id]) { waiters[m.id](m); delete waiters[m.id]; } } catch (e) { }
  }
});
// The image's own format: JPEG starts FF D8 FF, PNG 89 50 4E 47; the MCP mimeType only when the bytes say neither.
function frameExt(bytes, mimeType) {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'jpg';
  if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'png';
  return /png/i.test(mimeType || '') ? 'png' : 'jpg';
}
let nextId = 1;
function rpc(method, params, timeoutS) {
  const id = nextId++;
  return new Promise((resolve) => {
    const t = setTimeout(() => { delete waiters[id]; resolve({ error: { message: 'TIMEOUT' } }); }, (timeoutS || 30) * 1000);
    waiters[id] = (m) => { clearTimeout(t); resolve(m); };
    mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

(async () => {
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'skyrally-clip', version: '1' } });
  mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const ls = await rpc('tools/call', { name: 'list_roblox_studios', arguments: {} });
  let studios = [];
  try { studios = JSON.parse(ls.result.content[0].text).studios; } catch (e) { }
  const studio = studios.find((s) => s.name === PLACE);
  if (!studio) { console.log('NO_OWN_STUDIO'); process.exit(2); }
  const t0 = Date.now();
  let n = 0;
  let ext = null; // set by the first frame; every frame of one clip uses it (ffmpeg's pattern has one extension)
  let mixed = 0;
  while ((Date.now() - t0) / 1000 < SECONDS) {
    const r = await rpc('tools/call', { name: 'screen_capture', arguments: { studio_id: studio.id, capture_id: 'clip' } }, 15);
    const img = r.result && (r.result.content || []).find((p) => p.type === 'image' && p.data);
    if (img) {
      const bytes = Buffer.from(img.data, 'base64');
      const kind = frameExt(bytes, img.mimeType);
      if (ext === null) ext = kind;
      if (kind !== ext) { mixed += 1; continue; } // a frame ffmpeg could not decode under this clip's extension
      n += 1;
      fs.writeFileSync(path.join(outDir, `f_${String(n).padStart(5, '0')}.${ext}`), bytes);
    }
  }
  const secs = (Date.now() - t0) / 1000;
  fs.writeFileSync(path.join(outDir, 'timing.json'), JSON.stringify({ frames: n, seconds: secs, fps: n / secs, ext: ext || 'jpg', mixed }));
  console.log(`CLIP frames=${n} seconds=${secs.toFixed(1)} fps=${(n / secs).toFixed(2)} ext=${ext || 'jpg'} mixed=${mixed}`);
  setTimeout(() => { mcp.kill(); process.exit(0); }, 300);
})();
