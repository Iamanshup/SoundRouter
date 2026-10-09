const list = document.getElementById('list');
const msg = document.getElementById('msg');
const speakers = document.getElementById('speakers');
const volSection = document.getElementById('volumeSection');
const volRow = document.getElementById('volume');
const vol = document.getElementById('vol');
const volText = document.getElementById('volText');
let tab;
let lastKey = '';
let dragging = false;
const NEUTRAL = '#8e8e93';

function setMessage(text, kind = '') {
  msg.textContent = text;
  msg.className = kind;
}

async function state() {
  return chrome.runtime.sendMessage({ target: 'offscreen', type: 'getState' });
}

function option(value, title, { color = NEUTRAL, tag = '', sub = '', checked = false } = {}) {
  const label = document.createElement('label');
  label.className = 'opt' + (checked ? ' selected' : '');
  label.style.setProperty('--c', color);
  const input = document.createElement('input');
  input.type = 'radio';
  input.name = 'dev';
  input.value = value;
  input.checked = checked;
  input.addEventListener('change', () => choose(value || null));
  const dot = document.createElement('span');
  dot.className = 'dot';
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = title;
  label.append(input, dot, name);
  if (tag) {
    const t = document.createElement('span');
    t.className = 'tag';
    t.textContent = tag;
    label.append(t);
  }
  if (sub) {
    const s = document.createElement('span');
    s.className = 'sub';
    s.textContent = sub;
    label.append(s);
  }
  const check = document.createElement('span');
  check.className = 'check';
  label.append(check);
  return label;
}

async function render() {
  const s = await state();
  if (!s || !s.connected) {
    speakers.style.display = 'none';
    volSection.style.display = 'none';
    lastKey = '';
    setMessage('SoundRouter isn’t running. Open the SoundRouter app on your Mac, then try again.', 'error');
    return;
  }
  speakers.style.display = '';
  const route = s.routes[String(tab.id)];
  const error = s.errors[String(tab.id)];
  const key = JSON.stringify([s.devices, route && route.deviceUID]);
  if (key !== lastKey) {
    lastKey = key;
    list.replaceChildren(
      option('', 'Same as browser', { sub: 'default', checked: !route }),
      ...s.devices.map((d) => option(d.uid, d.name, {
        color: d.color || NEUTRAL,
        tag: d.isDefault ? 'Mac default' : '',
        checked: !!route && route.deviceUID === d.uid,
      })),
    );
  }
  volSection.style.display = route ? '' : 'none';
  volRow.style.display = route ? 'flex' : 'none';
  if (route) {
    const device = s.devices.find((d) => d.uid === route.deviceUID);
    vol.style.setProperty('--vc', (device && device.color) || '');
    if (!dragging) {
      vol.value = Math.round(route.volume * 100);
      volText.textContent = vol.value + '%';
    }
  }
  if (error) setMessage(error, 'error');
  else if (route) setMessage('This tab is playing through SoundRouter.', 'live');
  else setMessage('Tab audio follows the browser’s speaker.');
}

async function choose(deviceUID) {
  const s = await state();
  let streamId;
  // Capturing needs this popup's user gesture, so mint the stream id here.
  if (deviceUID && !s.captured.includes(tab.id)) {
    try {
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
    } catch (e) {
      setMessage('Couldn’t capture this tab: ' + (e.message || e), 'error');
      return;
    }
  }
  await chrome.runtime.sendMessage({ target: 'offscreen', type: 'setRoute', tabId: tab.id, deviceUID, streamId });
  setTimeout(render, 150);
}

vol.addEventListener('input', () => {
  dragging = true;
  volText.textContent = vol.value + '%';
  chrome.runtime.sendMessage({ target: 'offscreen', type: 'setVolume', tabId: tab.id, volume: vol.value / 100 });
});
vol.addEventListener('change', () => { dragging = false; });

(async () => {
  [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const tabLine = document.getElementById('tab');
  if (tab.favIconUrl && /^(https|data):/.test(tab.favIconUrl)) {
    const img = document.createElement('img');
    img.src = tab.favIconUrl;
    img.onerror = () => img.remove();
    tabLine.append(img);
  }
  const title = document.createElement('span');
  title.textContent = tab.title || tab.url;
  tabLine.append(title);
  await chrome.runtime.sendMessage({ target: 'background', type: 'ensure' });
  await new Promise((r) => setTimeout(r, 100));
  await render();
  setInterval(render, 700);
})();
