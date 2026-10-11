// Checks that a routed tab survives its speaker changing sample rate (what Bluetooth
// headphones do when an app opens their mic). Simulates the extension; needs the app running.
// Usage: SETRATE=<path to compiled Tests/setrate.swift> node Tests/samplerate-test.mjs
import { execFileSync } from 'node:child_process';
const DEVICE = 'MacBook Air Speakers';
const setrate = (r) => Number(execFileSync(process.env.SETRATE, r ? [DEVICE, String(r)] : [DEVICE]).toString());
let failures = 0;
const check = (ok, what) => { console.log((ok ? 'PASS ' : 'FAIL ') + what); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const original = setrate();
setrate(48000);
const ws = new WebSocket('ws://127.0.0.1:47390/', { headers: { Origin: 'chrome-extension://ratetest' } });
ws.binaryType = 'arraybuffer';
const inbox = [];
let followRoutes = true;      // the real extension follows 'route' messages
let rate = 0;
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  inbox.push(m);
  if (m.type === 'route' && followRoutes) { rate = m.sampleRate; ws.send(JSON.stringify({ type: 'captured', tabId: 7 })); }
};
await new Promise((r) => (ws.onopen = r));
const waitFor = async (pred, ms = 3000) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(20)) {
    const i = inbox.findIndex(pred); if (i >= 0) return inbox.splice(i, 1)[0];
  }
  return null;
};
const stats = async () => { ws.send(JSON.stringify({ type: 'debugStats', tabId: 7 })); return waitFor((m) => m.type === 'debugStats'); };

ws.send(JSON.stringify({ type: 'hello', browser: 'Google Chrome' }));
ws.send(JSON.stringify({ type: 'tabs', tabs: [{ id: 7, title: 'Rate test', url: 'https://x', audible: true }] }));
const state = await waitFor((m) => m.type === 'state');
const uid = state.devices.find((d) => d.name.includes(DEVICE)).uid;
ws.send(JSON.stringify({ type: 'setRoute', tabId: 7, deviceUID: uid }));
await sleep(300);
check(rate === 48000, `tab routed at ${rate} Hz`);

// Background tone generator, paced in real time at whatever rate we were last told.
let running = true, phase = 0;
(async () => {
  let t = performance.now();
  while (running) {
    const r = rate, frames = Math.round(r / 100);
    const buf = new ArrayBuffer(8 + frames * 8);
    new Uint32Array(buf, 0, 2).set([7, 2]);
    const s = new Float32Array(buf, 8);
    for (let i = 0; i < frames; i++) { const v = 0.2 * Math.sin(phase); phase += (2 * Math.PI * 440) / r; s[2 * i] = v; s[2 * i + 1] = v; }
    ws.send(buf);
    t += 10; await sleep(Math.max(0, t - performance.now()));
  }
})();

await sleep(2000);
const before = await stats();
check(before.sampleRate === 48000 && before.peak > 0.15, `playing at 48 kHz (peak ${before.peak.toFixed(3)})`);

// Headset-style switch.
setrate(44100);
const reroute = await waitFor((m) => m.type === 'route' && m.sampleRate === 44100, 3000);
check(!!reroute, 'app notices the rate change and asks the extension for 44.1 kHz audio');
await sleep(1000); // settle
const settled = await stats();
await sleep(3000);
const after = await stats();
check(after.sampleRate === 44100, `tab player rebuilt at ${after.sampleRate} Hz`);
check(after.peak > 0.15, `audio keeps playing after the switch (peak ${after.peak.toFixed(3)})`);
check(after.skips - settled.skips === 0 && after.underruns - settled.underruns === 0,
  `no drift over 3 s at the new rate (skips +${after.skips - settled.skips}, underruns +${after.underruns - settled.underruns})`);

// Control: behave like the old code (keep sending at the old rate) and show the test detects it.
followRoutes = false;
setrate(48000);
await waitFor((m) => m.type === 'route' && m.sampleRate === 48000, 3000);
await sleep(500);
const c1 = await stats();
await sleep(3000);
const c2 = await stats();
check(c2.underruns - c1.underruns > 0 || c2.skips - c1.skips > 0,
  `control: a stream left at the wrong rate is detected (skips +${c2.skips - c1.skips}, underruns +${c2.underruns - c1.underruns})`);

running = false;
ws.send(JSON.stringify({ type: 'forgetSite', host: 'x' }));   // leave no remembered test site behind
await sleep(300);
ws.close();
setrate(original);
console.log(`restored ${DEVICE} to ${setrate()} Hz`);
console.log(failures ? `${failures} FAILURE(S)` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
