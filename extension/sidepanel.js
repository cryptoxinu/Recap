// Recap side panel — the in-call Q&A for Google Meet. Streams answers from the Recap Mac
// app's loopback server (POST /ask, Server-Sent Events). Uses fetch + a stream reader rather than
// EventSource because we must send the Authorization: Bearer <token> header.

const RECAP_QUERY =
  "What did they just say? Give me a quick, plain recap of the last thing that was said.";
const ASK_NEXT_QUERY =
  "What should I ask next? Suggest 2-3 sharp questions based on the call so far.";

const el = (id) => document.getElementById(id);
const messagesEl = () => el("messages");
const PORT_RANGE = Array.from({ length: 11 }, (_, i) => 8422 + i); // 8422–8432

let cfg = { port: null, token: null };
let streaming = false;
let pairing = false;

// ---- config + connection ---------------------------------------------------

async function loadConfig() {
  const stored = await chrome.storage.local.get(["port", "token", "captionsActive"]);
  cfg.port = stored.port || 8422;
  cfg.token = stored.token || null;
  updateCaptionsWarning(stored.captionsActive);
  if (!cfg.token) {
    el("pairCard").hidden = false;
    el("main").hidden = true;
    setStatus("off", "Not paired");
    if (!pairing) pairOrb("idle");
    return false;
  }
  el("pairCard").hidden = true;
  el("main").hidden = false;
  return true;
}

// ---- one-click pairing (launch the app + poll /pair) -----------------------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function fetchT(url, opts, ms) {  // hard-deadline fetch so a silent port can't hang the poll (#3)
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try { return await fetch(url, Object.assign({ signal: ctrl.signal }, opts || {})); }
  finally { clearTimeout(t); }
}
function pairOrb(state) { const o = el("pairOrb"); if (o) o.className = `orb state-${state}`; }
function pairStatus(text, cls) {
  const p = el("pairStatus"); if (!p) return;
  p.textContent = text; p.className = "pair-body" + (cls ? " " + cls : "");
}
function pairBusy(on) {
  pairing = on;
  const b = el("pairBtn"); if (!b) return;
  b.disabled = on; b.querySelector(".btn-label").textContent = on ? "Pairing…" : "Pair with Recap";
}

// Probe /pair across the port range. Returns {token,port} | "closed" (app up, window shut) | null.
async function probePair() {
  let sawApp = false;
  for (const port of PORT_RANGE) {
    try {
      const r = await fetchT(`http://127.0.0.1:${port}/pair`, { method: "GET" }, 1500);
      if (r.ok) {
        const data = await r.json().catch(() => null);
        if (data && data.ok && data.token) {
          const p = Number.isInteger(data.port) && PORT_RANGE.includes(data.port) ? data.port : port;
          return { token: data.token, port: p };
        }
      }
      if (r.status === 403) sawApp = true;
    } catch (_) { /* nothing here / timed out */ }
  }
  return sawApp ? "closed" : null;
}

async function verifyToken(token, port) {  // confirm the responder is really Recap (audit #1)
  try {
    const r = await fetchT(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${token}` } }, 1500);
    return r.ok;
  } catch { return false; }
}

// Hardened pairing: fetch the token over Chrome's authenticated native-messaging channel (only OUR pinned
// extension can reach the host, so the token isn't exposed on the spoofable /pair route). Returns
// {token,port} | null (host not installed / app not opened since install → caller falls back to /pair).
const NATIVE_HOST = "com.callbrain.pair";
function tryNativeMessaging() {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, { cmd: "pair" }, (resp) => {
        if (chrome.runtime.lastError || !resp || !resp.ok || !resp.token) return resolve(null);
        const p = Number.isInteger(resp.port) && PORT_RANGE.includes(resp.port) ? resp.port : PORT_RANGE[0];
        resolve({ token: resp.token, port: p });
      });
    } catch (_) { resolve(null); }
  });
}

let launchTabId = null;
function launchApp() {  // active tab so the first-run "Open Recap?" prompt is visible (audit #2)
  chrome.tabs.create({ url: "callbrain://pair", active: true }, (tab) => { launchTabId = tab?.id ?? null; });
}
function closeLaunchTab() {
  if (launchTabId != null) { chrome.tabs.remove(launchTabId).catch(() => {}); launchTabId = null; }
}

async function runPairing() {
  if (pairing) return;
  pairBusy(true); pairOrb("busy"); pairStatus("Looking for Recap…");
  try {
    // Hardened path first (no open window needed). Only short-circuit if the token VERIFIES — a stale
    // bridge must fall through to the loopback/deep-link flow, not strand the user.
    const nm = await tryNativeMessaging();
    if (nm && (await verifyToken(nm.token, nm.port))) { await applyPairing(nm.token, nm.port); return; }

    let got = await probePair();
    if (got && got !== "closed") return await pairingDone(got);

    pairStatus(got === "closed" ? "Connecting to Recap…" : "Opening Recap…");
    launchApp();

    for (let i = 0; i < 60; i++) {   // ~30s — room for Chrome's first-run "Open Recap?" prompt
      await sleep(500);
      got = await probePair();
      if (got && got !== "closed") return await pairingDone(got);
      if (i === 6 && got === null) pairStatus("Waiting for Recap to open…");
    }
    pairOrb("bad");
    pairStatus(got === "closed"
      ? "Recap is open but didn’t confirm — try again."
      : "Couldn’t reach Recap. Make sure it’s installed, then try again.", "bad");
  } finally {
    closeLaunchTab();
    pairBusy(false);
  }
}

async function pairingDone({ token, port }) {
  if (!(await verifyToken(token, port))) {
    pairOrb("bad"); pairStatus("Reached the port, but it isn’t Recap — make sure the app is running.", "bad");
    return;
  }
  await applyPairing(token, port);
}

// Persist a VERIFIED pairing (storage.onChanged → loadConfig swaps to main) + show success.
async function applyPairing(token, port) {
  await chrome.storage.local.set({ token, port });
  pairOrb("ok"); pairStatus("Paired ✓  You’re all set.", "ok");
}

// Zero-click: when the panel opens unpaired, silently check if the app is already running with its
// pairing window open (it auto-opens on launch) and pair on the spot — no button press, no app launch.
// If the app isn't reachable, we just leave the pair card for the user to click.
async function silentPairAttempt() {
  if (cfg.token || pairing) return;
  // Prefer the authenticated native-messaging channel — it pairs even with the loopback window closed.
  const nm = await tryNativeMessaging();
  if (nm && (await verifyToken(nm.token, nm.port))) {
    await chrome.storage.local.set({ token: nm.token, port: nm.port });
    return;
  }
  const got = await probePair();
  if (got && got !== "closed" && (await verifyToken(got.token, got.port))) {
    await chrome.storage.local.set({ token: got.token, port: got.port });  // → storage.onChanged swaps to main
  }
}

function base() {
  return `http://127.0.0.1:${cfg.port}`;
}
function authHeaders(extra) {
  return Object.assign({ Authorization: `Bearer ${cfg.token}` }, extra || {});
}

function setStatus(kind, text) {
  const s = el("status");
  s.classList.remove("ok", "off");
  if (kind) s.classList.add(kind);
  el("statusText").textContent = text;
}

async function checkHealth() {
  if (!cfg.token) return;
  try {
    const r = await fetch(`${base()}/health`, { headers: authHeaders() });
    if (r.ok) setStatus("ok", "Connected");
    else if (r.status === 401) setStatus("off", "Bad token");
    else setStatus("off", "App unreachable");
  } catch {
    setStatus("off", "App not running");
  }
}

function updateCaptionsWarning(active) {
  const warn = el("captionsWarn");
  if (warn) warn.hidden = active !== false;
}

// ---- chat rendering --------------------------------------------------------

function addBubble(role) {
  const wrap = document.createElement("div");
  wrap.className = `msg ${role}`;
  const bubble = document.createElement("div");
  bubble.className = "bubble";
  wrap.appendChild(bubble);
  messagesEl().appendChild(wrap);
  el("hint").hidden = true;
  scrollToBottom();
  return bubble;
}

function showTyping(bubble) {
  bubble.innerHTML = '<span class="dots"><span></span><span></span><span></span></span>';
}

function renderStreaming(bubble, text) {
  bubble.textContent = text;
  const caret = document.createElement("span");
  caret.className = "caret";
  caret.textContent = " ▌";
  bubble.appendChild(caret);
  scrollToBottom();
}

function scrollToBottom() {
  const m = messagesEl();
  m.scrollTop = m.scrollHeight;
}

function setComposerEnabled(on) {
  streaming = !on;
  el("input").disabled = !on;
  el("sendBtn").disabled = !on;
  el("recapBtn").disabled = !on;
  el("askNextBtn").disabled = !on;
}

// ---- ask (SSE) -------------------------------------------------------------

async function ask(query) {
  const q = (query || "").trim();
  if (!q || streaming) return;
  if (!cfg.token) {
    await loadConfig();
    return;
  }
  addBubble("user").textContent = q;
  const answer = addBubble("assistant");
  showTyping(answer);
  setComposerEnabled(false);

  let text = "";
  try {
    const resp = await fetch(`${base()}/ask`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json", Accept: "text/event-stream" }),
      body: JSON.stringify({ query: q }),
    });
    if (!resp.ok || !resp.body) {
      throw new Error(resp.status === 401 ? "bad token" : `status ${resp.status}`);
    }
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let done = false;
    while (!done) {
      const { value, done: streamDone } = await reader.read();
      if (streamDone) break;
      buf += decoder.decode(value, { stream: true });
      // Split complete SSE events on the blank-line delimiter.
      let idx;
      while ((idx = buf.indexOf("\n\n")) !== -1) {
        const frame = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const evt = parseSSE(frame);
        if (evt.event === "done") { done = true; break; }
        if (evt.event === "error") { throw new Error(evt.message || "error"); }
        if (evt.data !== undefined && evt.data !== null) {
          text += evt.data;
          renderStreaming(answer, text);
        }
      }
    }
    answer.textContent = text.trim() || "…";
  } catch (e) {
    answer.textContent = "Couldn't reach the Recap app. Is it running and paired?";
    setStatus("off", "App not running");
  } finally {
    setComposerEnabled(true);
    scrollToBottom();
  }
}

// ---- record control (POST /record/start|stop, GET /record/status) ----------

let recording = false;

function setRecordState(isRec, isProcessing, elapsed) {
  recording = isRec;
  const btn = el("recordBtn");
  const state = el("recordState");
  const bar = el("recordBar");
  if (!btn || !state || !bar) return;
  if (isProcessing) {
    btn.textContent = "Transcribing…";
    btn.disabled = true;
    state.textContent = "Finishing up…";
    bar.classList.remove("recording");
  } else if (isRec) {
    btn.textContent = "Stop recording";
    btn.disabled = false;
    state.textContent = `● Recording ${elapsed || ""}`.trim();
    bar.classList.add("recording");
  } else {
    btn.textContent = "Record this call";
    btn.disabled = false;
    state.textContent = "Not recording";
    bar.classList.remove("recording");
  }
}

async function pollRecordStatus() {
  if (!cfg.token) return;
  try {
    const r = await fetch(`${base()}/record/status`, { headers: authHeaders() });
    if (!r.ok) return;
    const j = await r.json().catch(() => ({}));
    setRecordState(!!j.recording, !!j.processing, j.elapsed);
  } catch { /* app unreachable — leave the last state, checkHealth surfaces the disconnect */ }
}

async function toggleRecord() {
  if (!cfg.token) { await loadConfig(); return; }
  const btn = el("recordBtn");
  btn.disabled = true;
  const starting = !recording;
  try {
    const r = await fetch(`${base()}${starting ? "/record/start" : "/record/stop"}`, {
      method: "POST",
      headers: authHeaders(),
    });
    const j = await r.json().catch(() => ({}));
    if (starting && r.ok && j.ok === false) {
      el("recordState").textContent = "Couldn't start — allow Microphone + Screen Recording for Recap.";
    }
  } catch {
    el("recordState").textContent = "Couldn't reach the app.";
  } finally {
    btn.disabled = false;
    setTimeout(pollRecordStatus, 300);   // reflect the new state promptly
  }
}

// ---- save the call to Recap (POST /import) -----------------------------

async function saveCall() {
  if (!cfg.token || streaming) return;
  const btn = el("saveBtn");
  btn.disabled = true;
  btn.textContent = "Saving…";
  try {
    const r = await fetch(`${base()}/import`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "Google Meet call" }),
    });
    const j = await r.json().catch(() => ({}));
    btn.textContent = r.ok && j.ok ? "Saved to Recap ✓" : "Nothing captured yet";
  } catch {
    btn.textContent = "Couldn't save — is the app running?";
  } finally {
    setTimeout(() => {
      btn.textContent = "Save this call to Recap";
      btn.disabled = false;
    }, 2500);
  }
}

// Parse one SSE frame into { event?, data?, message? }.
function parseSSE(frame) {
  const out = {};
  for (const line of frame.split("\n")) {
    if (line.startsWith("event:")) {
      out.event = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      const raw = line.slice(5).trim();
      try {
        const val = JSON.parse(raw);
        if (typeof val === "string") out.data = val;         // a streamed token
        else if (val && typeof val === "object") {           // done/error payload
          if (val.message) out.message = val.message;
        }
      } catch {
        out.data = raw; // tolerate a non-JSON data line
      }
    }
  }
  return out;
}

// ---- wire up ---------------------------------------------------------------

function init() {
  el("recapBtn").addEventListener("click", () => ask(RECAP_QUERY));
  el("askNextBtn").addEventListener("click", () => ask(ASK_NEXT_QUERY));
  el("sendBtn").addEventListener("click", () => {
    const v = el("input").value;
    el("input").value = "";
    ask(v);
  });
  el("input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.isComposing) {
      e.preventDefault();
      const v = el("input").value;
      el("input").value = "";
      ask(v);
    }
  });
  el("pairBtn").addEventListener("click", runPairing);
  el("openOptions").addEventListener("click", () => chrome.runtime.openOptionsPage());
  el("saveBtn").addEventListener("click", saveCall);
  el("recordBtn").addEventListener("click", toggleRecord);

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.token || changes.port) {
      loadConfig().then((ok) => { if (ok) checkHealth(); });
    }
    if (changes.captionsActive) updateCaptionsWarning(changes.captionsActive.newValue);
  });

  loadConfig().then((ok) => {
    if (ok) { checkHealth(); pollRecordStatus(); }
    else silentPairAttempt();   // app already running? pair with zero clicks
  });
  setInterval(checkHealth, 15000);
  setInterval(pollRecordStatus, 2000);   // keep the record indicator live during a call
}

init();
