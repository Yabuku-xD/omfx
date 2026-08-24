// omfx browser relay — MV3 worker. Dumb pipe: RPCs come from the Zig relay
// over ws://127.0.0.1:<port>/ext. chrome.debugger attaches to existing tabs
// so Chrome 136+ default profiles work without --remote-debugging-port.
const DEFAULT_PORT = 9224;
const PING_MS = 20_000;
const RECONNECT_MIN_MS = 1_000;
const RECONNECT_MAX_MS = 10_000;

let ws = null;
let reconnectDelay = RECONNECT_MIN_MS;
let pingTimer = null;

function attachable(url) {
  if (!url) return false;
  if (url.startsWith("chrome://") || url.startsWith("chrome-extension://")) return false;
  if (url.startsWith("devtools://") || url.startsWith("edge://")) return false;
  if (url.startsWith("https://chrome.google.com/webstore")) return false;
  if (url.startsWith("https://chromewebstore.google.com")) return false;
  return true;
}

function snapshot(tab) {
  if (tab.id === undefined) return null;
  const url = tab.url || tab.pendingUrl || "";
  if (!attachable(url) && url.length > 0) return null;
  return {
    tabId: tab.id,
    url,
    title: tab.title || "",
    active: !!tab.active,
    windowId: tab.windowId,
    pinned: !!tab.pinned,
    groupId: tab.groupId === undefined ? -1 : tab.groupId,
  };
}

async function loadSettings() {
  const stored = await chrome.storage.local.get({ port: DEFAULT_PORT, token: "" });
  const port = Number(stored.port);
  return {
    port: Number.isInteger(port) && port > 0 && port <= 65535 ? port : DEFAULT_PORT,
    token: typeof stored.token === "string" ? stored.token : "",
  };
}

function post(msg) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

async function setBadge(on) {
  try {
    await chrome.action.setBadgeText({ text: on ? "on" : "off" });
    await chrome.action.setBadgeBackgroundColor({ color: on ? "#1a7f37" : "#8b8b8b" });
  } catch (_) {}
}

async function buildHello() {
  const [tabs, targets] = await Promise.all([chrome.tabs.query({}), chrome.debugger.getTargets()]);
  const snapshots = [];
  for (const tab of tabs) {
    const snap = snapshot(tab);
    if (snap) snapshots.push(snap);
  }
  const attachedTabIds = [];
  for (const t of targets) {
    if (t.attached && t.tabId !== undefined) attachedTabIds.push(t.tabId);
  }
  const versionMatch = /Chrome\/[\d.]+/.exec(navigator.userAgent);
  return {
    t: "hello",
    userAgent: navigator.userAgent,
    browserVersion: versionMatch ? versionMatch[0] : "Chrome/unknown",
    tabs: snapshots,
    attachedTabIds,
  };
}

async function runRpc(msg) {
  const tabId = msg.tabId === undefined ? undefined : Number(msg.tabId);
  switch (msg.op) {
    case "listTabs": {
      const hello = await buildHello();
      return { tabs: hello.tabs };
    }
    case "attach":
      await chrome.debugger.attach({ tabId }, "1.3");
      return {};
    case "detach":
      await chrome.debugger.detach({ tabId });
      return {};
    case "send":
      return await chrome.debugger.sendCommand(
        msg.sessionId ? { tabId, sessionId: msg.sessionId } : { tabId },
        msg.method,
        msg.params || {},
      );
    case "createTab": {
      const tab = await chrome.tabs.create({ url: msg.url });
      const snap = snapshot(tab);
      if (!snap) throw new Error("created tab has no id");
      return { tab: snap };
    }
    case "removeTab":
      await chrome.tabs.remove(tabId);
      return {};
    case "activateTab": {
      const tab = await chrome.tabs.get(tabId);
      await chrome.windows.update(tab.windowId, { focused: false });
      await chrome.tabs.update(tabId, { active: true });
      return {};
    }
    default:
      throw new Error("unknown op " + msg.op);
  }
}

function handleRelayMessage(raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch (_) {
    return;
  }
  if (msg.t === "pong") return;
  runRpc(msg)
    .then((result) => post({ t: "rpcResult", id: msg.id, ok: true, result }))
    .catch((err) => post({ t: "rpcResult", id: msg.id, ok: false, error: String(err && err.message ? err.message : err) }));
}

function scheduleReconnect() {
  const delay = reconnectDelay;
  reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  setTimeout(() => connect(), delay);
}

async function relayListening(port) {
  try {
    await fetch("http://127.0.0.1:" + port + "/json/version", { cache: "no-store" });
    return true;
  } catch (_) {
    return false;
  }
}

async function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  const settings = await loadSettings();
  if (!(await relayListening(settings.port))) {
    setBadge(false);
    scheduleReconnect();
    return;
  }
  const q = settings.token ? "?token=" + encodeURIComponent(settings.token) : "";
  const url = "ws://127.0.0.1:" + settings.port + "/ext" + q;
  let socket;
  try {
    socket = new WebSocket(url);
  } catch (_) {
    scheduleReconnect();
    return;
  }
  ws = socket;
  socket.onopen = () => {
    reconnectDelay = RECONNECT_MIN_MS;
    setBadge(true);
    buildHello().then((hello) => post(hello));
    if (pingTimer) clearInterval(pingTimer);
    pingTimer = setInterval(() => post({ t: "ping" }), PING_MS);
  };
  socket.onmessage = (event) => {
    if (typeof event.data === "string") handleRelayMessage(event.data);
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    ws = null;
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
    setBadge(false);
    scheduleReconnect();
  };
  socket.onerror = () => {
    try {
      socket.close();
    } catch (_) {}
  };
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (source.tabId === undefined) return;
  post({ t: "cdpEvent", tabId: source.tabId, sessionId: source.sessionId, method, params });
});
chrome.debugger.onDetach.addListener((source, reason) => {
  if (source.tabId === undefined) return;
  post({ t: "detached", tabId: source.tabId, reason });
});
chrome.tabs.onCreated.addListener((tab) => {
  const snap = snapshot(tab);
  if (snap) post({ t: "tabCreated", tab: snap });
});
chrome.tabs.onUpdated.addListener((_id, _info, tab) => {
  const snap = snapshot(tab);
  if (snap) post({ t: "tabUpdated", tab: snap });
});
chrome.tabs.onRemoved.addListener((tabId) => post({ t: "tabRemoved", tabId }));

chrome.alarms.create("omfx-relay-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "omfx-relay-keepalive") connect();
});
chrome.storage.onChanged.addListener((_c, area) => {
  if (area !== "local") return;
  if (ws) ws.close();
  connect();
});
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
chrome.runtime.onInstalled.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
connect();
