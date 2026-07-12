// One-click pairing. Clicking "Pair" opens the callbrain:// deep link (which launches/focuses the Mac
// app and opens its loopback pairing window), then polls the /pair endpoint until the token appears.
// Works whether or not the app was already running. Manual token entry remains as a fallback.
const el = (id) => document.getElementById(id);
const PORT_RANGE = Array.from({ length: 11 }, (_, i) => 8422 + i); // 8422–8432 (app port + fallbacks)

// ── UI helpers ──────────────────────────────────────────────────────────────
function setOrb(state) {
  el("orb").className = `orb state-${state}`;
}
function status(text, cls) {
  const s = el("statusLine");
  s.textContent = text;
  s.className = "status-line" + (cls ? " " + cls : "");
}
function busy(on) {
  const b = el("pair");
  b.disabled = on;
  b.classList.toggle("is-busy", on);
  b.querySelector(".btn-label").textContent = on ? "Pairing…" : "Pair with Recap";
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// fetch with a hard deadline — a port that accepts a connection but never responds must NOT leave the
// request pending (which would hang the whole poll and disable the button forever). (audit #3)
async function fetchT(url, opts, ms) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try { return await fetch(url, Object.assign({ signal: ctrl.signal }, opts || {})); }
  finally { clearTimeout(t); }
}

// ── storage ─────────────────────────────────────────────────────────────────
async function restore() {
  const s = await chrome.storage.local.get(["port", "token"]);
  if (s.port) el("port").value = s.port;
  if (s.token) el("token").value = s.token;
  return s;
}
async function storePairing(token, port) {
  await chrome.storage.local.set({ token, port });
  el("token").value = token;
  el("port").value = port;
}

// ── loopback probe ───────────────────────────────────────────────────────────
// Try to fetch the token from /pair across the port range. Returns {token,port} | 'closed' | null.
// 'closed' = the app answered but its pairing window isn't open (403); null = app not reachable.
async function probeOnce() {
  let sawApp = false;
  for (const port of PORT_RANGE) {
    try {
      const r = await fetchT(`http://127.0.0.1:${port}/pair`, { method: "GET" }, 1500);
      if (r.ok) {
        const data = await r.json().catch(() => null);
        // Trust only an in-range numeric port that matches what we probed (no redirect to a stray port).
        if (data && data.ok && data.token) {
          const p = Number.isInteger(data.port) && PORT_RANGE.includes(data.port) ? data.port : port;
          return { token: data.token, port: p };
        }
      }
      if (r.status === 403) sawApp = true; // app is there, window not open
    } catch (_) { /* nothing on this port / timed out */ }
  }
  return sawApp ? "closed" : null;
}

// ── native-messaging pairing (preferred, hardened) ───────────────────────────
// Ask the Recap Native Messaging host for the token over Chrome's authenticated stdio channel.
// Chrome only connects this host to OUR pinned extension id (per the host manifest's allowed_origins),
// so — unlike the loopback /pair route, whose Origin header a local process can spoof — a website or
// rogue extension can't obtain the token here. Returns {token,port} | null (host absent / app not open).
const NATIVE_HOST = "com.callbrain.pair";
function tryNativeMessaging() {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, { cmd: "pair" }, (resp) => {
        // lastError = host manifest not installed / app never opened since install → fall back silently.
        if (chrome.runtime.lastError || !resp || !resp.ok || !resp.token) return resolve(null);
        const port = Number.isInteger(resp.port) && PORT_RANGE.includes(resp.port) ? resp.port : PORT_RANGE[0];
        resolve({ token: resp.token, port });
      });
    } catch (_) { resolve(null); }   // nativeMessaging unavailable in this browser build
  });
}

// Confirm the token actually works against the authenticated API before trusting the responder — catches
// a stale token and raises the bar on a local impostor (audit #1; full mitigation is native messaging).
async function verifyToken(token, port) {
  try {
    const r = await fetchT(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${token}` } }, 1500);
    return r.ok;
  } catch { return false; }
}

// Open the deep link that launches/focuses the app. An ACTIVE tab so Chrome's first-run "Open Recap?"
// protocol prompt is visible (an inactive tab hides it); kept open until the flow ends (audit #2).
let launchTabId = null;
function openApp() {
  chrome.tabs.create({ url: "callbrain://pair", active: true }, (tab) => { launchTabId = tab?.id ?? null; });
}
function closeLaunchTab() {
  if (launchTabId != null) { chrome.tabs.remove(launchTabId).catch(() => {}); launchTabId = null; }
}

// ── the one-click flow ───────────────────────────────────────────────────────
async function pair() {
  busy(true);
  setOrb("busy");
  status("Looking for Recap…");
  try {
    // 0) Hardened path — get the token over Chrome's authenticated native-messaging channel. Needs no
    //    open pairing window (the app installs the host on launch), so it also succeeds when the loopback
    //    window is closed. Only short-circuit if the token actually VERIFIES — a stale bridge (old token
    //    after a crash/rebind) must fall THROUGH to the loopback/deep-link flow, not strand the user.
    const nm = await tryNativeMessaging();
    if (nm && (await verifyToken(nm.token, nm.port))) return await pairedOK(nm.token, nm.port);

    // 1) Fast path — app already running with a window open.
    let got = await probeOnce();
    if (got && got !== "closed") return await succeed(got);

    // 2) Launch / focus the app + open its pairing window.
    status(got === "closed" ? "Connecting to Recap…" : "Opening Recap…");
    openApp();

    // 3) Poll for a bounded ~18s while the app comes up and opens the window.
    for (let i = 0; i < 60; i++) {   // ~30s — room for Chrome's first-run "Open Recap?" prompt
      await sleep(500);
      got = await probeOnce();
      if (got && got !== "closed") return await succeed(got);
      if (i === 6 && got === null) status("Waiting for Recap to open…");
    }

    setOrb("bad");
    status(
      got === "closed"
        ? "Recap is open but didn’t confirm — try Pair again."
        : "Couldn’t reach Recap. Make sure it’s installed, then try again.",
      "bad"
    );
  } finally {
    closeLaunchTab();
    busy(false);
  }
}

async function succeed({ token, port }) {
  if (!(await verifyToken(token, port))) {
    setOrb("bad");
    status("Reached something on the port, but it isn’t Recap. Make sure the app is running.", "bad");
    return;
  }
  await pairedOK(token, port);
}

// Store a VERIFIED pairing and show success. Shared by the native + loopback paths.
async function pairedOK(token, port) {
  await storePairing(token, port);
  setOrb("ok");
  status("Paired ✓  You’re all set — open a Meet call.", "ok");
}

// ── manual fallback ───────────────────────────────────────────────────────────
function readForm() {
  return { token: el("token").value.trim(), port: parseInt(el("port").value, 10) || 8422 };
}
async function save() {
  const { token, port } = readForm();
  if (!token) return status("Enter a pairing token first.", "bad");
  await chrome.storage.local.set({ token, port });
  setOrb("ok"); status("Saved ✓", "ok");
}
async function test() {
  const { token, port } = readForm();
  if (!token) return status("Pair first, or enter a token.", "bad");
  status("Testing…");
  try {
    const r = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${token}` } });
    if (r.ok) { setOrb("ok"); status("Connected to Recap ✓", "ok"); }
    else if (r.status === 401) { setOrb("bad"); status("Wrong token — re-pair.", "bad"); }
    else { setOrb("bad"); status(`App responded with ${r.status}.`, "bad"); }
  } catch {
    setOrb("bad"); status("Couldn’t reach the app. Is Recap running?", "bad");
  }
}

el("pair").addEventListener("click", pair);
el("save").addEventListener("click", save);
el("test").addEventListener("click", test);

(async () => {
  const s = await restore();
  if (s.token) { setOrb("ok"); status("Already paired ✓ — re-pair any time.", "ok"); }
})();
