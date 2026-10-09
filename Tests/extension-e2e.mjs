// End-to-end: real extension in Chrome for Testing + running SoundRouter app.
// Usage: CHROME=<path to Chrome for Testing> node Tests/extension-e2e.mjs   (needs `npm i puppeteer`)
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';

const EXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../BrowserExtension');
const TARGET = process.env.TARGET_DEVICE || 'MacBook Air Speakers';
let failures = 0;
const check = (ok, what) => { console.log((ok ? 'PASS ' : 'FAIL ') + what); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A page that plays a quiet 440 Hz tone (amplitude 0.05).
const page = `<!doctype html><title>Tone</title><button id=go>play</button><script>
go.onclick = () => { const c = new AudioContext(); const o = c.createOscillator(); const g = c.createGain();
  g.gain.value = 0.05; o.frequency.value = 440; o.connect(g).connect(c.destination); o.start(); document.title = 'Tone playing'; };
</script>`;
const server = http.createServer((_q, r) => { r.setHeader('content-type', 'text/html'); r.end(page); }).listen(8099);

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME, headless: false, pipe: true, enableExtensions: true,
  args: ['--autoplay-policy=no-user-gesture-required', '--window-size=900,700'],
});
try {
  const extId = await browser.installExtension(EXT);
  check(!!extId, 'extension installs (' + extId + ')');

  const offscreenTarget = await browser.waitForTarget((t) => t.url().endsWith('/offscreen.html'), { timeout: 10000 });
  const offscreen = await offscreenTarget.asPage();
  const connected = await offscreen.waitForFunction(() => ws && ws.readyState === 1, { timeout: 10000, polling: 100 }).then(() => true, () => false);
  check(connected, 'offscreen document connects to the SoundRouter app');
  // Collect app → extension messages for assertions.
  await offscreen.evaluate(() => { window.inbox = []; ws.addEventListener('message', (e) => typeof e.data === 'string' && inbox.push(JSON.parse(e.data))); });
  const stats = async (tabId) => {
    await offscreen.evaluate((id) => { inbox = inbox.filter((m) => m.type !== 'debugStats'); ws.send(JSON.stringify({ type: 'debugStats', tabId: id })); }, tabId);
    return offscreen.waitForFunction(() => inbox.find((m) => m.type === 'debugStats'), { timeout: 3000, polling: 50 }).then((h) => h.jsonValue(), () => null);
  };

  const tab = await browser.newPage();
  await tab.goto('http://127.0.0.1:8099/');
  await tab.click('#go');
  await tab.waitForFunction(() => document.title === 'Tone playing');
  await sleep(800);
  const tabId = await offscreen.evaluate(() => (lastTabs.find((t) => t.url.startsWith('http://127.0.0.1:8099')) || {}).id);
  const reported = await offscreen.evaluate(() => lastTabs.find((t) => t.url.startsWith('http://127.0.0.1:8099')));
  check(!!tabId, 'tab is reported to the app');
  check(reported && reported.audible, 'tab is reported as playing sound');

  // Open the popup on that tab (as clicking the toolbar button would) and pick a speaker.
  const ext = (await browser.extensions()).get(extId);
  await tab.bringToFront();
  await ext.triggerAction(tab);
  const popupTarget = await browser.waitForTarget((t) => t.url().endsWith('/popup.html'), { timeout: 5000 });
  const popup = await popupTarget.asPage();
  await popup.waitForSelector('input[name=dev]', { timeout: 5000 });
  const options = await popup.$$eval('label.opt', (ls) => ls.map((l) => l.textContent));
  check(options.length >= 2, 'popup lists speakers: ' + options.join(' | '));
  const uid = await popup.$$eval('label.opt', (ls, name) => {
    const l = ls.find((x) => x.textContent.includes(name)); return l && l.querySelector('input').value;
  }, TARGET);
  check(!!uid, `target speaker "${TARGET}" is offered`);
  await popup.click(`input[value="${uid}"]`);
  await sleep(1500);
  const captured = await offscreen.evaluate((id) => captures.has(id), tabId);
  check(captured, 'tab audio is captured after choosing a speaker in the popup');
  const s1 = await stats(tabId);
  check(s1 && s1.device === uid, `app plays the tab on ${TARGET} (${s1 && s1.device})`);
  check(s1 && s1.callbacks > 20 && s1.peak > 0.03 && s1.peak < 0.07, `tab tone arrives at the right level (peak ${s1 && s1.peak.toFixed(3)}, ${s1 && s1.callbacks} callbacks)`);
  const status = await popup.$eval('#msg', (e) => e.textContent);
  check(/playing through SoundRouter/.test(status), 'popup shows routed status');

  // Volume slider in the popup.
  await popup.$eval('#vol', (el) => { el.value = 50; el.dispatchEvent(new Event('input')); el.dispatchEvent(new Event('change')); });
  await sleep(600);
  const s2 = await stats(tabId);
  check(s2 && s2.peak > 0.015 && s2.peak < 0.035, `popup volume 50% halves the level (peak ${s2 && s2.peak.toFixed(3)})`);
  await popup.close().catch(() => {}); // Chrome may already have closed it

  // Switch device from the app side (no popup / no new gesture): simulated by the
  // app's setRoute path, which re-targets the already captured tab.
  await offscreen.evaluate((id) => ws.send(JSON.stringify({ type: 'setRoute', tabId: id, deviceUID: null })), tabId);
  await sleep(800);
  check(!(await offscreen.evaluate((id) => captures.has(id), tabId)), '"Same as browser" releases the capture (tab plays normally again)');

  // App-initiated routing on a tab that was granted earlier (popup was opened on it).
  await offscreen.evaluate((id, u) => ws.send(JSON.stringify({ type: 'setRoute', tabId: id, deviceUID: u })), tabId, uid);
  await sleep(1500);
  const s3 = await stats(tabId);
  check(s3 && s3.peak > 0.02, `routing chosen in the app works on a tab the extension was opened on (peak ${s3 && s3.peak.toFixed(3)})`);

  // Remembered website: a new tab on the same site is routed just by opening the popup.
  const tab3 = await browser.newPage();
  await tab3.goto('http://127.0.0.1:8099/?remember');
  await tab3.click('#go');
  await sleep(800);
  const tab3Id = await offscreen.evaluate(() => (lastTabs.find((t) => t.url.endsWith('?remember')) || {}).id);
  await tab3.bringToFront();
  await ext.triggerAction(tab3);
  const popup3 = await (await browser.waitForTarget((t) => t.url().endsWith('/popup.html'), { timeout: 5000 })).asPage();
  await sleep(1500);
  const site = await popup3.$eval('#site', (e) => getComputedStyle(e).display !== 'none' && e.textContent);
  check(await offscreen.evaluate((id) => captures.has(id), tab3Id), 'opening the popup on a remembered site routes the tab with no click');
  check(!!site && /Remembered for 127.0.0.1/.test(site), 'popup shows the remembered site: ' + (site || '').trim().replace(/\s+/g, ' '));
  await popup3.$eval('#vol', (el) => el.max).then((max) => check(max === '200', 'popup volume goes to 200%'));
  await popup3.click('#forget').catch(() => {});
  await sleep(500);
  await popup3.close().catch(() => {});
  await tab3.close();
  await sleep(500);

  // A tab the extension was never opened on: app-initiated routing must explain what to do.
  const tab2 = await browser.newPage();
  await tab2.goto('http://127.0.0.1:8099/?2');
  await sleep(800);
  const tab2Id = await offscreen.evaluate(() => (lastTabs.find((t) => t.url.endsWith('?2')) || {}).id);
  await offscreen.evaluate((id, u) => { inbox = []; ws.send(JSON.stringify({ type: 'setRoute', tabId: id, deviceUID: u })); }, tab2Id, uid);
  const err = await offscreen.waitForFunction((id) => { const s = inbox.filter((m) => m.type === 'state').pop(); return s && s.errors[id]; }, { timeout: 4000, polling: 50 }, String(tab2Id)).then((h) => h.jsonValue(), () => null);
  check(!!err, 'un-granted tab gets a clear hint: ' + err);

  // Closing a routed tab cleans up.
  await tab.close();
  await sleep(1000);
  check(!(await offscreen.evaluate((id) => captures.has(id), tabId)), 'closing a routed tab ends its capture');
  // Leave no remembered test site behind.
  await offscreen.evaluate(() => ws.send(JSON.stringify({ type: 'forgetSite', host: '127.0.0.1' })));
  await sleep(300);
} catch (e) {
  console.log('FAIL exception: ' + (e.stack || e));
  failures++;
} finally {
  await browser.close();
  server.close();
}
console.log(failures ? `${failures} FAILURE(S)` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
