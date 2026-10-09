// Holds the WebSocket to the SoundRouter app and the captured tab streams.
// Each captured tab is resampled to the target device's rate by an AudioContext and
// streamed to the app as binary frames: [u32 tabId][u32 channels][f32 interleaved...].

const URL_APP = 'ws://127.0.0.1:47390/';
let ws = null;
let appState = { devices: [], routes: {}, errors: {} };
let lastTabs = [];
const captures = new Map(); // tabId -> { stream, ctx, sampleRate }
const pendingStreamIds = new Map(); // tabId -> stream id minted by the popup

function browserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const real = brands.map((b) => b.brand).find((b) => !/chromium|not.?a.?brand/i.test(b));
  return real || 'Chromium';
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function connect() {
  const sock = new WebSocket(URL_APP);
  sock.binaryType = 'arraybuffer';
  sock.onopen = () => {
    ws = sock;
    send({ type: 'hello', browser: browserName(), version: 1 });
    if (lastTabs.length) send({ type: 'tabs', tabs: lastTabs });
    chrome.runtime.sendMessage({ target: 'background', type: 'requestTabs' }).catch(() => {});
  };
  sock.onmessage = (e) => {
    if (typeof e.data === 'string') handle(JSON.parse(e.data));
  };
  sock.onclose = () => {
    if (ws === sock) {
      ws = null;
      // Without the app, captured tabs would be silent: give them back to the browser.
      for (const tabId of [...captures.keys()]) stopCapture(tabId);
      appState = { devices: [], routes: {}, errors: {} };
    }
    setTimeout(connect, 2000);
  };
  sock.onerror = () => {};
}

async function handle(msg) {
  if (msg.type === 'state') {
    appState = msg;
  } else if (msg.type === 'route') {
    try {
      await startCapture(msg.tabId, msg.sampleRate);
      send({ type: 'captured', tabId: msg.tabId });
    } catch (e) {
      send({ type: 'captureFailed', tabId: msg.tabId, reason: e.message || String(e) });
    }
  } else if (msg.type === 'unroute') {
    stopCapture(msg.tabId);
  }
}

async function streamFor(tabId) {
  const minted = pendingStreamIds.get(tabId);
  pendingStreamIds.delete(tabId);
  let streamId = minted;
  if (!streamId) {
    const r = await chrome.runtime.sendMessage({ target: 'background', type: 'getStreamId', tabId });
    if (!r || r.error) throw new Error((r && r.error) || 'no stream id');
    streamId = r.streamId;
  }
  return navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: false,
  });
}

async function startCapture(tabId, sampleRate) {
  let cap = captures.get(tabId);
  if (cap && cap.sampleRate === sampleRate) return;
  if (cap) await cap.ctx.close(); // device rate changed: rebuild the graph on the same stream
  const stream = cap ? cap.stream : await streamFor(tabId);

  const ctx = new AudioContext({ sampleRate, latencyHint: 'interactive' });
  await ctx.audioWorklet.addModule('worklet.js');
  const source = ctx.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(ctx, 'tab-tap', {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [1],
    processorOptions: { tabId, chunkFrames: Math.round(sampleRate / 100) },
  });
  node.port.onmessage = (e) => {
    if (ws && ws.readyState === WebSocket.OPEN && ws.bufferedAmount < 1 << 20) ws.send(e.data);
  };
  source.connect(node);
  node.connect(ctx.destination); // the worklet outputs silence; this just keeps it pulled

  stream.getAudioTracks().forEach((t) => {
    t.onended = () => {
      stopCapture(tabId);
      send({ type: 'captureEnded', tabId });
    };
  });
  captures.set(tabId, { stream, ctx, sampleRate });
}

function stopCapture(tabId) {
  const cap = captures.get(tabId);
  if (!cap) return;
  captures.delete(tabId);
  cap.stream.getTracks().forEach((t) => t.stop());
  cap.ctx.close();
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.target !== 'offscreen') return;
  if (msg.type === 'tabs') {
    lastTabs = msg.tabs;
    send({ type: 'tabs', tabs: msg.tabs });
  } else if (msg.type === 'getState') {
    sendResponse({ connected: !!ws, ...appState, captured: [...captures.keys()] });
  } else if (msg.type === 'setRoute') {
    if (msg.streamId) pendingStreamIds.set(msg.tabId, msg.streamId);
    send({ type: 'setRoute', tabId: msg.tabId, deviceUID: msg.deviceUID ?? null });
    sendResponse({ ok: !!ws });
  } else if (msg.type === 'setVolume') {
    send({ type: 'setRoute', tabId: msg.tabId, volume: msg.volume });
  }
});

connect();
