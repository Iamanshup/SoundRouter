// Service worker: keeps the offscreen document (which holds the connection to the
// SoundRouter app and the captured tab streams) alive, reports tabs, and mints
// tab-capture stream ids.

async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  try {
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['USER_MEDIA'],
      justification: 'Capture tab audio and stream it to the SoundRouter app',
    });
  } catch (e) {
    if (!String(e).includes('single offscreen')) throw e;
  }
}

async function reportTabs() {
  await ensureOffscreen();
  const tabs = await chrome.tabs.query({});
  const list = tabs
    .filter((t) => t.url && !t.url.startsWith('chrome-extension://'))
    .map((t) => ({ id: t.id, title: t.title || '', url: t.url || '', audible: !!t.audible, favIconUrl: t.favIconUrl || '' }));
  chrome.runtime.sendMessage({ target: 'offscreen', type: 'tabs', tabs: list }).catch(() => {});
}

let pending;
function scheduleReport() {
  clearTimeout(pending);
  pending = setTimeout(reportTabs, 150);
}

chrome.runtime.onStartup.addListener(ensureOffscreen);
chrome.runtime.onInstalled.addListener(scheduleReport);
chrome.tabs.onCreated.addListener(scheduleReport);
chrome.tabs.onRemoved.addListener(scheduleReport);
chrome.tabs.onUpdated.addListener((_id, change) => {
  if ('audible' in change || 'title' in change || 'url' in change || 'favIconUrl' in change) scheduleReport();
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.target !== 'background') return;
  if (msg.type === 'ensure') {
    ensureOffscreen().then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.type === 'requestTabs') {
    reportTabs();
  } else if (msg.type === 'getStreamId') {
    chrome.tabCapture
      .getMediaStreamId({ targetTabId: msg.tabId })
      .then((streamId) => sendResponse({ streamId }), (e) => sendResponse({ error: e.message || String(e) }));
    return true;
  }
});

ensureOffscreen();
