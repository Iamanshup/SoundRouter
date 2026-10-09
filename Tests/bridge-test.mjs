// Simulates the browser extension against a running SoundRouter app.
// Usage: node Tests/bridge-test.mjs
const URL_APP = 'ws://127.0.0.1:47390/';
let failures = 0;
const check = (ok, what) => { console.log((ok ? 'PASS ' : 'FAIL ') + what); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function open(origin) {
  return new Promise((resolve) => {
    const ws = new WebSocket(URL_APP, { headers: { Origin: origin } });
    ws.binaryType = 'arraybuffer';
    const inbox = [];
    ws.onmessage = (e) => inbox.push(JSON.parse(e.data));
    ws.onopen = () => resolve({ ws, inbox });
    ws.onerror = () => resolve(null);
  });
}
async function waitFor(inbox, pred, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = inbox.findIndex(pred);
    if (i >= 0) return inbox.splice(i, 1)[0];
    await sleep(20);
  }
  return null;
}

// 1. Web pages must be refused.
check((await open('https://example.com')) === null, 'connection from a web page origin is rejected');

// 2. Extension handshake.
const c = await open('chrome-extension://abcdefghijklmnop');
check(!!c, 'extension origin can connect');
const { ws, inbox } = c;
ws.send(JSON.stringify({ type: 'hello', browser: 'Google Chrome', version: 1 }));
const st = await waitFor(inbox, (m) => m.type === 'state');
check(st && st.devices.length > 0, `app sends device list (${st && st.devices.map((d) => d.name).join(', ')})`);
const dev = st.devices.find((d) => d.isDefault) || st.devices[0];

ws.send(JSON.stringify({ type: 'tabs', tabs: [
  { id: 7, title: 'YouTube - test video', url: 'https://www.youtube.com/watch?v=x', audible: true },
  { id: 8, title: 'Docs', url: 'https://example.com', audible: false },
] }));

// 3. Route tab 7 the way the popup does.
ws.send(JSON.stringify({ type: 'setRoute', tabId: 7, deviceUID: dev.uid }));
const route = await waitFor(inbox, (m) => m.type === 'route' && m.tabId === 7);
check(!!route && route.sampleRate > 0, `app asks extension to capture tab 7 at ${route && route.sampleRate} Hz`);
ws.send(JSON.stringify({ type: 'captured', tabId: 7 }));
const st2 = await waitFor(inbox, (m) => m.type === 'state' && m.routes['7']);
check(st2 && st2.routes['7'].deviceUID === dev.uid, 'state reports tab 7 routed to ' + dev.name);

// 4. Stream a quiet 440 Hz tone for 2 s in 10 ms chunks (amplitude 0.2).
const rate = route.sampleRate, frames = Math.round(rate / 100);
let phase = 0;
const start = Date.now();
for (let n = 0; n < 200; n++) {
  const buf = new ArrayBuffer(8 + frames * 8);
  new Uint32Array(buf, 0, 2).set([7, 2]);
  const s = new Float32Array(buf, 8);
  for (let i = 0; i < frames; i++) {
    const v = 0.2 * Math.sin(phase); phase += (2 * Math.PI * 440) / rate;
    s[2 * i] = v; s[2 * i + 1] = v;
  }
  ws.send(buf);
  const due = start + (n + 1) * 10;
  await sleep(Math.max(0, due - Date.now()));
  if (n === 150) ws.send(JSON.stringify({ type: 'debugStats', tabId: 7 }));
}
const stats = await waitFor(inbox, (m) => m.type === 'debugStats');
check(stats && stats.callbacks > 20, `tab player running on device (${stats && stats.callbacks} IO callbacks)`);
check(stats && Math.abs(stats.peak - 0.2) < 0.03, `streamed tone reaches the speaker at the right level (peak ${stats && stats.peak.toFixed(3)})`);

// 5. Tab volume from the popup.
ws.send(JSON.stringify({ type: 'setRoute', tabId: 7, volume: 0.5 }));
const st3 = await waitFor(inbox, (m) => m.type === 'state' && m.routes['7'] && m.routes['7'].volume === 0.5);
check(!!st3, 'tab volume change is applied and reported');
for (let n = 0; n < 50; n++) {
  const buf = new ArrayBuffer(8 + frames * 8);
  new Uint32Array(buf, 0, 2).set([7, 2]);
  const s = new Float32Array(buf, 8);
  for (let i = 0; i < frames; i++) { const v = 0.2 * Math.sin(phase); phase += (2 * Math.PI * 440) / rate; s[2*i] = v; s[2*i+1] = v; }
  ws.send(buf); await sleep(10);
}
ws.send(JSON.stringify({ type: 'debugStats', tabId: 7 }));
const stats2 = await waitFor(inbox, (m) => m.type === 'debugStats');
check(stats2 && Math.abs(stats2.peak - 0.1) < 0.02, `50% tab volume halves the level (peak ${stats2 && stats2.peak.toFixed(3)})`);

// 6. Back to "Same as browser" releases the capture.
ws.send(JSON.stringify({ type: 'setRoute', tabId: 7, deviceUID: null }));
check(!!(await waitFor(inbox, (m) => m.type === 'unroute' && m.tabId === 7)), 'choosing "Same as browser" tells the extension to stop capturing');

// 7. Capture failure surfaces a helpful message.
ws.send(JSON.stringify({ type: 'setRoute', tabId: 8, deviceUID: dev.uid }));
await waitFor(inbox, (m) => m.type === 'route' && m.tabId === 8);
ws.send(JSON.stringify({ type: 'captureFailed', tabId: 8, reason: 'Extension has not been invoked for the current page (see activeTab permission).' }));
const st4 = await waitFor(inbox, (m) => m.type === 'state' && m.errors['8']);
check(st4 && !st4.routes['8'] && /Click the SoundRouter extension/.test(st4.errors['8']), 'needs-click error is shown and route cleared');

ws.close();
console.log(failures ? `${failures} FAILURE(S)` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
