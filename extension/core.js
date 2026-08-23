// Recap content-script CORE — site-agnostic caption/mic engine shared by every meeting platform.
//
// This file contains ONLY code that is not specific to any one video service: config/storage,
// postCaption/postMicState, the generic caption parsing (cleanText / isNameLike / parseCaptionRow /
// boundedUtterance / childTextFragments), the generic locators (locateByAria / locateByHeuristic),
// the MutationObserver locate→observe→finalize loop, mic scoring, and the auto-captions ticker skeleton.
//
// It is loaded FIRST (before a per-host adapter) via a per-host content_scripts entry, so Zoom code
// never runs on Meet and vice-versa. Core exposes two globals for the adapter that loads after it:
//   • globalThis.__recapCore — the shared DOM helpers an adapter needs to parse rows.
//   • globalThis.__recapRun(adapter) — the single entry point; the adapter calls it to start the engine.
//
// ── Adapter contract ─────────────────────────────────────────────────────────────────────────────
//   {
//     id,                                  // string: "meet" | "zoom" | "teams" — stamped as `source`
//     matches(loc)?,                       // optional: return false to NOT run in this frame/URL
//     locateCaptionRegion(),               // return the caption container element, or null
//     rowsFrom(region) -> [{speaker,text}],// parse one region into per-speaker rows
//     locateMicButton?(),                  // optional: return the mic-toggle element (else core's generic)
//     micMuted?(btn),                      // optional: true|false|null for a mic button (else core's generic)
//     captionsToggle?() -> {button, off},  // optional: the CC toggle + whether captions are currently off
//     meetingId(),                         // string identity for this meeting (per-meeting auto-CC + T4)
//   }
// core.js drives locate→observe→rowsFrom→finalize/dedupe→postCaption. It stamps `ts` (Date.now()) and
// the T4 fields (source/tab/meetingId) onto every /live and /mic-state POST. The generic fallback
// (locateByAria → locateByHeuristic, and extractCaptionRows) stays available to every adapter: when an
// adapter's locateCaptionRegion()/rowsFrom() come up empty, core falls back to the generic path.
(() => {
  "use strict";

  const DEFAULT_PORT = 8422;
  const LOCATE_INTERVAL_MS = 2000;
  const MUTATION_DEBOUNCE_MS = 400;
  const MIC_LOCATE_INTERVAL_MS = 2000;
  const MIC_STATE_DEBOUNCE_MS = 150;
  const CAPTIONS_INACTIVE_MS = 8000;
  const AUTO_CAPTIONS_RETRY_MS = 1500; // active cadence while we still need to enable captions
  const AUTO_CAPTIONS_IDLE_MS = 5000; // slow watch once done — just to catch an SPA meeting change
  const MAX_SCAN_ELEMENTS = 1500;
  const MAX_TEXT_LENGTH = 5000;
  const CAPTION_LABEL_RE = /\b(caption|captions|subtitle|subtitles|transcript)\b/i;
  const MIC_LABEL_RE = /\bmicrophone\b/i;
  const MIC_MUTED_LABEL_RE = /\b(turn on microphone|unmute microphone|microphone (?:is )?off|muted)\b/i;
  const MIC_UNMUTED_LABEL_RE = /\b(turn off microphone|mute microphone|microphone (?:is )?on|unmuted)\b/i;
  const MIC_STATE_ATTRIBUTES = ["aria-label", "data-is-muted", "aria-pressed", "title", "aria-labelledby"];
  // NOTE: this is a substring test applied to utterance text too, so it must contain only phrases that
  // never occur in normal speech. Roster/People chrome is excluded STRUCTURALLY (region scoping +
  // interactive/name-only rejection), not by blocklisting the bare word "people" (which would drop a
  // real line like "Most people agreed").
  const NON_CONTENT_TEXT_RE =
    /\b(turn on captions|turn off captions|captions? are off|closed captions|live captions?|caption settings|jump to bottom|more options)\b/i;
  const INTERACTIVE_SELECTOR =
    "button,a,input,select,textarea,[role='button'],[role='link'],[role='menuitem'],[contenteditable='true']";

  let adapter = null; // set once by __recapRun(adapter); every driver function closes over it
  let cachedTabId = null; // T4: the owning tab id, fetched once from background.js at start

  let config = { port: null, token: null };
  let captionsContainer = null;
  let observer = null;
  let locateTimer = null;
  let debounceTimer = null;
  let inactiveTimer = null;
  let micButton = null;
  let micObserver = null;
  let micLocateTimer = null;
  let micDebounceTimer = null;
  let captionsActiveState = null;
  let micButtonWasFound = false;
  let autoCaptionsEnabled = true; // config-controlled; default on (founder asked for auto-CC)
  let captionsAutoDone = false; // once-per-MEETING: never fight a later manual off
  let autoCaptionsMeetingId = null; // re-arms auto-CC when the meeting URL changes (SPA meeting switch)
  let autoCaptionsTimer = null;
  let lastMicMutedSent = null;
  let lastSent = new Map();
  let lastFinalized = new Map();
  let lastVisibleRows = [];

  const cleanText = (value) =>
    String(value || "")
      .replace(/\s+/g, " ")
      .trim();

  const visibleElementChildren = (element) =>
    Array.from(element.children).filter((child) => isVisibleElement(child));

  const safeRuntimeError = () => {
    try {
      return chrome.runtime?.lastError;
    } catch {
      return null;
    }
  };

  const readStorage = (keys) =>
    new Promise((resolve) => {
      try {
        chrome.storage.local.get(keys, (items) => {
          if (safeRuntimeError()) {
            resolve({});
            return;
          }
          resolve(items || {});
        });
      } catch {
        resolve({});
      }
    });

  const writeStorage = (items) => {
    try {
      chrome.storage.local.set(items, () => {
        void safeRuntimeError();
      });
    } catch {
      // Storage can be unavailable during extension reloads.
    }
  };

  const normalizePort = (value) => {
    const raw = value === undefined || value === null || value === "" ? DEFAULT_PORT : value;
    const parsed = Number(raw);

    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
      return null;
    }

    return parsed;
  };

  const normalizeConfig = (items) => {
    const port = normalizePort(items.port);
    const token = typeof items.token === "string" && items.token.trim() ? items.token.trim() : null;

    return { port, token };
  };

  const refreshConfig = async () => {
    const items = await readStorage(["port", "token", "autoCaptions"]);
    config = normalizeConfig(items);
    autoCaptionsEnabled = items.autoCaptions !== false; // default ON unless explicitly disabled
  };

  const setCaptionsActive = (active) => {
    if (captionsActiveState === active) {
      return;
    }

    captionsActiveState = active;
    writeStorage({ captionsActive: active });
  };

  const scheduleCaptionsInactive = () => {
    window.clearTimeout(inactiveTimer);
    inactiveTimer = window.setTimeout(() => {
      setCaptionsActive(false);
    }, CAPTIONS_INACTIVE_MS);
  };

  const markCaptionsFlowing = () => {
    setCaptionsActive(true);
    scheduleCaptionsInactive();
  };

  const hasUsableConfig = () => Boolean(config.port && config.token);

  // T4: the owning tab id + adapter identity + meeting id + a client timestamp, stamped onto every POST.
  // The Swift side treats all four as OPTIONAL (back-compat with a legacy nil-tab payload), so this never
  // breaks an older app; it lets a newer app bind captions to the tab that produced them.
  const stampFields = () => ({
    source: adapter ? adapter.id : null,
    tab: cachedTabId,
    meetingId: adapter && adapter.meetingId ? adapter.meetingId() : "",
    ts: Date.now(),
  });

  const postCaption = async ({ speaker, text, final }) => {
    if (!hasUsableConfig() || !speaker || !text) {
      return;
    }

    try {
      await fetch(`http://127.0.0.1:${config.port}/live`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${config.token}`
        },
        body: JSON.stringify({ speaker, text, final, ...stampFields() })
      });
    } catch {
      // The Mac app may be closed or on a different port. The side panel reports pairing state.
    }
  };

  const postMicState = async (muted, { keepalive = false } = {}) => {
    if (!hasUsableConfig()) {
      return;
    }

    try {
      await fetch(`http://127.0.0.1:${config.port}/mic-state`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${config.token}`
        },
        body: JSON.stringify({ muted, ...stampFields() }),
        keepalive
      });
    } catch {
      // The Mac app may be closed; mute state will be sent again on the next observed change.
    }
  };

  const sendUpdateIfChanged = (row) => {
    const previousText = lastSent.get(row.speaker);
    if (previousText === row.text) {
      return;
    }

    lastSent = new Map(lastSent).set(row.speaker, row.text);
    void postCaption({ speaker: row.speaker, text: row.text, final: false });
  };

  const sendFinalIfNeeded = (row) => {
    if (!row.speaker || !row.text) {
      return;
    }

    const alreadyFinalized = lastFinalized.get(row.speaker) === row.text;
    if (alreadyFinalized) {
      return;
    }

    lastFinalized = new Map(lastFinalized).set(row.speaker, row.text);
    void postCaption({ speaker: row.speaker, text: row.text, final: true });
  };

  const isElementNode = (node) => node?.nodeType === Node.ELEMENT_NODE;

  const isVisibleElement = (element) => {
    if (!isElementNode(element) || element.closest("[hidden],[aria-hidden='true']")) {
      return false;
    }

    const style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) {
      return false;
    }

    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  const isInteractive = (element) => {
    try {
      return Boolean(element.closest(INTERACTIVE_SELECTOR));
    } catch {
      return false;
    }
  };

  const elementLabelText = (element) => {
    const parts = [
      element.getAttribute("aria-label"),
      element.getAttribute("title"),
      element.getAttribute("data-tooltip")
    ];
    const labelledBy = element.getAttribute("aria-labelledby");

    if (labelledBy) {
      for (const id of labelledBy.split(/\s+/)) {
        const labelElement = id ? document.getElementById(id) : null;
        if (labelElement) {
          parts.push(labelElement.textContent);
        }
      }
    }

    return cleanText(parts.filter(Boolean).join(" "));
  };

  const isCaptionLabelled = (element) => CAPTION_LABEL_RE.test(elementLabelText(element));

  const isPotentialCaptionSurface = (element) => {
    if (!isVisibleElement(element) || isInteractive(element)) {
      return false;
    }

    const role = cleanText(element.getAttribute("role")).toLowerCase();
    return (
      role === "region" ||
      role === "log" ||
      role === "status" ||
      role === "list" ||
      Boolean(element.getAttribute("aria-live")) ||
      isCaptionLabelled(element)
    );
  };

  const textLeafFragments = (root) => {
    const fragments = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || !isVisibleElement(parent) || isInteractive(parent)) {
          return NodeFilter.FILTER_REJECT;
        }

        const text = cleanText(node.nodeValue);
        if (!text || NON_CONTENT_TEXT_RE.test(text)) {
          return NodeFilter.FILTER_REJECT;
        }

        return NodeFilter.FILTER_ACCEPT;
      }
    });

    while (fragments.length < 80) {
      const node = walker.nextNode();
      if (!node) {
        break;
      }

      const text = cleanText(node.nodeValue);
      if (text && fragments[fragments.length - 1] !== text) {
        fragments.push(text);
      }
    }

    return fragments;
  };

  const childTextFragments = (root) => {
    const children = visibleElementChildren(root)
      .filter((child) => !isInteractive(child))
      .map((child) => cleanText(child.textContent))
      .filter((text) => text && !NON_CONTENT_TEXT_RE.test(text));

    if (children.length >= 2) {
      return children;
    }

    return textLeafFragments(root);
  };

  const isNameLike = (text) => {
    if (!text || text.length > 64 || text.split(/\s+/).length > 5) {
      return false;
    }

    if (/[.!?]$/.test(text) || NON_CONTENT_TEXT_RE.test(text)) {
      return false;
    }

    return /[\p{L}\p{N}]/u.test(text);
  };

  const isPlausibleCaptionText = (speaker, text) => {
    if (!speaker || !text || speaker === text) {
      return false;
    }

    if (text.length > MAX_TEXT_LENGTH || NON_CONTENT_TEXT_RE.test(text)) {
      return false;
    }

    return /[\p{L}\p{N}]/u.test(text);
  };

  const parseCaptionRow = (element) => {
    if (!isVisibleElement(element) || isInteractive(element)) {
      return null;
    }

    const fragments = childTextFragments(element);
    if (fragments.length < 2) {
      return null;
    }

    const maxSpeakerIndex = Math.min(2, fragments.length - 1);
    for (let index = 0; index <= maxSpeakerIndex; index += 1) {
      const speaker = cleanText(fragments[index]);
      const text = cleanText(boundedUtterance(fragments.slice(index + 1)));

      if (isNameLike(speaker) && isPlausibleCaptionText(speaker, text)) {
        return { speaker, text };
      }
    }

    return null;
  };

  // Bound a generic (non-Meet) utterance at the next speaker boundary: a name-like fragment AFTER the
  // first utterance fragment means another turn (or the participant roster) leaked into this surface, so
  // stop before it instead of concatenating everyone's words into one merged wall (the bug this targets).
  // rest[0] is ALWAYS kept, so short single-fragment captions ("Yes", "Sounds good") survive.
  const boundedUtterance = (rest) => {
    const stop = rest.findIndex((fragment, index) => index >= 1 && isNameLike(fragment));
    const bounded = stop === -1 ? rest : rest.slice(0, stop);
    return bounded.join(" ");
  };

  const uniqueRows = (rows) => {
    const seen = new Set();
    const unique = [];

    for (const row of rows) {
      const speaker = cleanText(row.speaker);
      const text = cleanText(row.text);
      const key = `${speaker}\u0000${text}`;

      if (speaker && text && !seen.has(key)) {
        seen.add(key);
        unique.push({ speaker, text });
      }
    }

    return unique;
  };

  const rowCandidatesFromSurface = (surface) => {
    const roleRows = Array.from(surface.querySelectorAll("[role='listitem'],[role='row']"));
    if (roleRows.length > 0) {
      return roleRows.filter((element) => isVisibleElement(element) && !isInteractive(element));
    }

    const children = visibleElementChildren(surface).filter((element) => !isInteractive(element));
    const candidates = [];

    for (const child of children) {
      candidates.push(child);

      for (const grandchild of visibleElementChildren(child)) {
        if (!isInteractive(grandchild)) {
          candidates.push(grandchild);
        }
      }
    }

    return candidates;
  };

  const extractCaptionRows = (surface) => {
    if (!surface || !isVisibleElement(surface)) {
      return [];
    }

    const candidateRows = rowCandidatesFromSurface(surface);
    const parsedRows = candidateRows.map(parseCaptionRow).filter(Boolean);

    if (parsedRows.length > 0) {
      return uniqueRows(parsedRows);
    }

    const parsedSurface = parseCaptionRow(surface);
    return parsedSurface ? [parsedSurface] : [];
  };

  const scanForRows = (surface) => {
    // Prefer the adapter's structured per-entry parse (e.g. Meet avatar-anchored → one row per speaker
    // turn). This is what prevents the whole-region-flattened "merged wall"; the generic extract is the
    // fallback for layouts the adapter can't parse.
    const adapterRows = adapter.rowsFrom(surface);
    if (adapterRows.length > 0) {
      return adapterRows;
    }

    const rows = extractCaptionRows(surface);
    if (rows.length > 0) {
      return rows;
    }

    const descendants = Array.from(surface.querySelectorAll("div,section,[role='list'],[role='region'],[aria-live]"));
    const limitedDescendants = descendants.slice(0, MAX_SCAN_ELEMENTS);
    const nestedRows = [];

    for (const descendant of limitedDescendants) {
      if (!isVisibleElement(descendant) || isInteractive(descendant)) {
        continue;
      }

      nestedRows.push(...extractCaptionRows(descendant));
      if (nestedRows.length >= 4) {
        break;
      }
    }

    return uniqueRows(nestedRows);
  };

  const chooseBestContainerAround = (anchor) => {
    let current = anchor;
    let steps = 0;
    let fallback = null;

    while (current && current !== document.body && steps < 5) {
      if (isVisibleElement(current) && !isInteractive(current)) {
        const rows = scanForRows(current);
        if (rows.length > 0) {
          return current;
        }

        if (!fallback && isPotentialCaptionSurface(current)) {
          fallback = current;
        }
      }

      current = current.parentElement;
      steps += 1;
    }

    return fallback;
  };

  const locateByAria = () => {
    const candidates = Array.from(
      document.querySelectorAll("[aria-label],[aria-labelledby],[title],[role='region'],[role='log'],[role='status'],[aria-live]")
    ).filter((element) => {
      if (!isVisibleElement(element) || isInteractive(element)) {
        return false;
      }

      return isCaptionLabelled(element) || (isPotentialCaptionSurface(element) && CAPTION_LABEL_RE.test(cleanText(element.textContent)));
    });

    for (const candidate of candidates) {
      const container = chooseBestContainerAround(candidate);
      if (container) {
        return container;
      }
    }

    return null;
  };

  const isLowerScreenSurface = (element) => {
    const rect = element.getBoundingClientRect();
    if (!Number.isFinite(rect.top) || window.innerHeight <= 0) {
      return false;
    }

    return rect.top + rect.height / 2 > window.innerHeight * 0.35;
  };

  const booleanAttribute = (element, attribute) => {
    const raw =
      element.getAttribute(attribute) ||
      element.querySelector(`[${attribute}]`)?.getAttribute(attribute);
    const value = cleanText(raw).toLowerCase();

    if (value === "true") {
      return true;
    }
    if (value === "false") {
      return false;
    }

    return null;
  };

  const micMutedFromButton = (button) => {
    const label = elementLabelText(button);

    // Meet DOM assumption: the mic toggle's accessible label describes the action, not the state.
    // "Turn on microphone" means the user is muted; "Turn off microphone" means currently unmuted.
    if (MIC_MUTED_LABEL_RE.test(label)) {
      return true;
    }
    if (MIC_UNMUTED_LABEL_RE.test(label)) {
      return false;
    }

    const dataMuted = booleanAttribute(button, "data-is-muted");
    if (dataMuted !== null) {
      return dataMuted;
    }

    // Fallback assumption: Meet marks the pressed mic toggle as the muted/off state.
    return booleanAttribute(button, "aria-pressed");
  };

  const isMicCandidate = (element) => {
    const button = element.matches?.("button,[role='button']")
      ? element
      : element.closest?.("button,[role='button']");

    if (!button || !isVisibleElement(button)) {
      return null;
    }

    const label = elementLabelText(button);
    const hasMicLabel = MIC_LABEL_RE.test(label);
    const hasMuteData =
      button.hasAttribute("data-is-muted") || Boolean(button.querySelector("[data-is-muted]"));
    const hasPressedState =
      button.hasAttribute("aria-pressed") || Boolean(button.querySelector("[aria-pressed]"));
    if (!hasMicLabel && !hasMuteData) {
      return null;
    }

    const muted = micMutedFromButton(button);
    let score = hasMicLabel ? 30 : 0;
    score += muted === null ? 0 : 20;
    score += hasMuteData ? 10 : 0;
    score += hasPressedState ? 4 : 0;
    score += isLowerScreenSurface(button) ? 3 : 0;

    return { button, score };
  };

  const locateMicButton = () => {
    try {
      const candidates = Array.from(
        document.querySelectorAll("button,[role='button'],[data-is-muted]")
      ).slice(0, MAX_SCAN_ELEMENTS);
      const seen = new Set();
      let best = null;

      for (const candidate of candidates) {
        const scored = isMicCandidate(candidate);
        if (!scored || seen.has(scored.button)) {
          continue;
        }

        seen.add(scored.button);
        if (!best || scored.score > best.score) {
          best = scored;
        }
      }

      return best?.button || null;
    } catch {
      return null;
    }
  };

  // Adapter-aware mic seams: prefer an adapter-provided locator/reader (e.g. Teams data-tid selectors),
  // else fall back to core's generic label/attribute scoring above.
  const adapterLocateMicButton = () =>
    adapter && adapter.locateMicButton ? adapter.locateMicButton() : locateMicButton();
  const adapterMicMuted = (button) =>
    adapter && adapter.micMuted ? adapter.micMuted(button) : micMutedFromButton(button);

  const hasConnectedMicButton = () =>
    Boolean(micButton && document.documentElement.contains(micButton) && isVisibleElement(micButton));

  const sendMicStateIfChanged = (muted, options = {}) => {
    if (lastMicMutedSent === muted || !hasUsableConfig()) {
      return;
    }

    lastMicMutedSent = muted;
    void postMicState(muted, options);
  };

  const disconnectMicObserver = () => {
    if (micObserver) {
      micObserver.disconnect();
      micObserver = null;
    }
  };

  const markMicButtonMissing = (options = {}) => {
    if (micButtonWasFound || lastMicMutedSent === true) {
      sendMicStateIfChanged(false, options);
    }

    micButtonWasFound = false;
    micButton = null;
    disconnectMicObserver();
  };

  const readCurrentMicState = () => {
    try {
      if (!hasConnectedMicButton()) {
        markMicButtonMissing();
        scheduleMicLocate(0);
        return;
      }

      const muted = adapterMicMuted(micButton);
      if (typeof muted === "boolean") {
        sendMicStateIfChanged(muted);
      }
    } catch {
      // Never throw into the page; a later locate pass can recover.
    }
  };

  const scheduleMicRead = () => {
    window.clearTimeout(micDebounceTimer);
    micDebounceTimer = window.setTimeout(readCurrentMicState, MIC_STATE_DEBOUNCE_MS);
  };

  const observeMicButton = (button) => {
    if (button === micButton && micObserver) {
      return;
    }

    disconnectMicObserver();
    micButton = button;
    micButtonWasFound = true;
    kickAutoCaptions(); // in-call: the captions toggle mounts alongside the mic toggle

    try {
      micObserver = new MutationObserver(scheduleMicRead);
      micObserver.observe(button, {
        attributes: true,
        attributeFilter: MIC_STATE_ATTRIBUTES
      });

      const toolbar = button.closest("[role='toolbar']") || button.parentElement;
      if (toolbar && toolbar !== button) {
        micObserver.observe(toolbar, {
          attributes: true,
          attributeFilter: MIC_STATE_ATTRIBUTES,
          childList: true,
          subtree: true
        });
      }

      scheduleMicRead();
      scheduleMicLocate(MIC_LOCATE_INTERVAL_MS);
    } catch {
      markMicButtonMissing();
      scheduleMicLocate(MIC_LOCATE_INTERVAL_MS);
    }
  };

  const locateAndObserveMic = () => {
    try {
      if (hasConnectedMicButton()) {
        scheduleMicLocate(MIC_LOCATE_INTERVAL_MS);
        return;
      }

      const button = adapterLocateMicButton();
      if (button) {
        observeMicButton(button);
        return;
      }

      markMicButtonMissing();
      scheduleMicLocate(MIC_LOCATE_INTERVAL_MS);
    } catch {
      scheduleMicLocate(MIC_LOCATE_INTERVAL_MS);
    }
  };

  const scheduleMicLocate = (delay = MIC_LOCATE_INTERVAL_MS) => {
    window.clearTimeout(micLocateTimer);
    micLocateTimer = window.setTimeout(locateAndObserveMic, delay);
  };

  // ── Auto-enable captions ───────────────────────────────────────────────────────────────────────
  // The founder shouldn't have to turn on CC manually for the relay to work. When Recap is paired and the
  // adapter can find the in-call captions toggle, click it once if captions are OFF. We act at most once
  // per meeting so we never fight a user who deliberately turns captions back off. The platform-specific
  // toggle detection lives in the adapter (captionsToggle); this is only the generic ticker skeleton.
  const autoCaptionsTick = () => {
    try {
      const meetingId = adapter && adapter.meetingId ? adapter.meetingId() : "";
      if (meetingId !== autoCaptionsMeetingId) {
        autoCaptionsMeetingId = meetingId;
        captionsAutoDone = false; // new meeting — enable captions again (but only once for it)
      }

      if (!captionsAutoDone && autoCaptionsEnabled && hasUsableConfig() && adapter && adapter.captionsToggle) {
        const toggle = adapter.captionsToggle();
        if (toggle) {
          if (toggle.off) {
            toggle.button.click();
          }
          // Already on OR just enabled — done for THIS meeting; respect any later manual off.
          captionsAutoDone = true;
        }
      }
    } catch {
      // never throw into the page
    }

    scheduleAutoCaptions(captionsAutoDone ? AUTO_CAPTIONS_IDLE_MS : AUTO_CAPTIONS_RETRY_MS);
  };

  const scheduleAutoCaptions = (delay = AUTO_CAPTIONS_RETRY_MS) => {
    window.clearTimeout(autoCaptionsTimer);
    autoCaptionsTimer = window.setTimeout(autoCaptionsTick, delay);
  };

  // Check now (responsiveness) on a fresh in-call / pairing signal; the ticker keeps itself alive.
  const kickAutoCaptions = () => scheduleAutoCaptions(0);

  const locateByHeuristic = () => {
    const candidates = Array.from(
      document.querySelectorAll("div,section,[role='region'],[role='log'],[role='status'],[aria-live]")
    ).slice(0, MAX_SCAN_ELEMENTS);
    let best = null;

    for (const candidate of candidates) {
      if (!isVisibleElement(candidate) || isInteractive(candidate)) {
        continue;
      }

      const text = cleanText(candidate.textContent);
      if (!text || text.length > MAX_TEXT_LENGTH) {
        continue;
      }

      // Adapter-aware even in the deepest fallback: if the region selectors have all drifted but the
      // adapter can still recover structured rows (e.g. Meet avatar-anchored entries), use them; otherwise
      // the generic extract.
      let rows = candidate.querySelector("img") ? adapter.rowsFrom(candidate) : [];
      if (rows.length === 0) {
        rows = extractCaptionRows(candidate);
      }
      if (rows.length === 0) {
        continue;
      }

      const rect = candidate.getBoundingClientRect();
      const compactness = Math.max(0, 800 - text.length) / 100;
      const lowerScreenBonus = isLowerScreenSurface(candidate) ? 4 : 0;
      const roleBonus = isPotentialCaptionSurface(candidate) ? 2 : 0;
      const score = rows.length * 10 + lowerScreenBonus + roleBonus + compactness - rect.width / 2000;

      if (!best || score > best.score) {
        best = { element: candidate, score };
      }
    }

    return best?.element || null;
  };

  // Prefer the adapter's real caption region (tight, excludes roster + chrome) so we observe the right
  // subtree; then the generic aria/heuristic locators as universal fallbacks for every adapter.
  const locateCaptionsContainer = () =>
    adapter.locateCaptionRegion() || locateByAria() || locateByHeuristic();

  const hasConnectedCaptionContainer = () =>
    Boolean(
      captionsContainer &&
        document.documentElement.contains(captionsContainer) &&
        isVisibleElement(captionsContainer)
    );

  const disconnectObserver = () => {
    if (observer) {
      observer.disconnect();
      observer = null;
    }
  };

  const handleRows = (rows) => {
    if (rows.length === 0) {
      scheduleCaptionsInactive();
      return;
    }

    markCaptionsFlowing();

    for (const previousRow of lastVisibleRows) {
      const stillVisible = rows.some(
        (row) => row.speaker === previousRow.speaker && row.text === previousRow.text
      );

      if (!stillVisible) {
        sendFinalIfNeeded(previousRow);
      }
    }

    for (const row of rows) {
      sendUpdateIfChanged(row);
    }

    lastVisibleRows = rows;
  };

  const readCurrentCaptions = () => {
    try {
      if (!captionsContainer || !document.documentElement.contains(captionsContainer)) {
        captionsContainer = null;
        disconnectObserver();
        scheduleLocate(0);
        scheduleCaptionsInactive();
        return;
      }

      handleRows(scanForRows(captionsContainer));
    } catch {
      scheduleCaptionsInactive();
    }
  };

  const scheduleRead = () => {
    window.clearTimeout(debounceTimer);
    debounceTimer = window.setTimeout(readCurrentCaptions, MUTATION_DEBOUNCE_MS);
  };

  const observeContainer = (container) => {
    if (container === captionsContainer && observer) {
      return;
    }

    disconnectObserver();
    captionsContainer = container;

    try {
      observer = new MutationObserver(scheduleRead);
      observer.observe(captionsContainer, {
        childList: true,
        subtree: true,
        characterData: true
      });
      scheduleRead();
      scheduleLocate(LOCATE_INTERVAL_MS);
    } catch {
      disconnectObserver();
      captionsContainer = null;
      scheduleCaptionsInactive();
    }
  };

  const locateAndObserve = () => {
    try {
      if (hasConnectedCaptionContainer()) {
        scheduleLocate(LOCATE_INTERVAL_MS);
        return;
      }

      const container = locateCaptionsContainer();
      if (container) {
        observeContainer(container);
        return;
      }

      captionsContainer = null;
      disconnectObserver();
      scheduleCaptionsInactive();
      scheduleLocate(LOCATE_INTERVAL_MS);
    } catch {
      scheduleCaptionsInactive();
      scheduleLocate(LOCATE_INTERVAL_MS);
    }
  };

  const scheduleLocate = (delay = LOCATE_INTERVAL_MS) => {
    window.clearTimeout(locateTimer);
    locateTimer = window.setTimeout(locateAndObserve, delay);
  };

  const resetForConfigChange = () => {
    lastSent = new Map();
    lastFinalized = new Map();
    lastMicMutedSent = null;
    scheduleRead();
    scheduleMicRead();
    scheduleMicLocate(0);
    kickAutoCaptions(); // a fresh pairing should enable captions if we're already in the call
  };

  const installStorageListener = () => {
    try {
      chrome.storage.onChanged.addListener((changes, areaName) => {
        if (areaName !== "local") {
          return;
        }

        if (changes.autoCaptions) {
          autoCaptionsEnabled = changes.autoCaptions.newValue !== false;
          if (autoCaptionsEnabled) {
            kickAutoCaptions();
          }
        }

        if (!changes.port && !changes.token) {
          return;
        }

        config = normalizeConfig({
          port: changes.port ? changes.port.newValue : config.port,
          token: changes.token ? changes.token.newValue : config.token
        });
        resetForConfigChange();
      });
    } catch {
      // Content scripts can outlive an extension reload.
    }
  };

  // T4: ask background.js for THIS content script's owning tab id (sender.tab.id). Cached once at start
  // and stamped onto every /live + /mic-state POST so the app can bind captions to the right meeting tab.
  const fetchTabId = () =>
    new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "recap-tab-id" }, (resp) => {
          if (safeRuntimeError()) {
            resolve(null);
            return;
          }
          resolve(resp && Number.isInteger(resp.tabId) ? resp.tabId : null);
        });
      } catch {
        resolve(null);
      }
    });

  const shutdown = () => {
    markMicButtonMissing({ keepalive: true });
    window.clearTimeout(locateTimer);
    window.clearTimeout(debounceTimer);
    window.clearTimeout(inactiveTimer);
    window.clearTimeout(micLocateTimer);
    window.clearTimeout(micDebounceTimer);
    window.clearTimeout(autoCaptionsTimer);
    disconnectObserver();
    disconnectMicObserver();
  };

  const start = async () => {
    installStorageListener();
    await refreshConfig();
    cachedTabId = await fetchTabId(); // T4: resolve the owning tab once before we start posting
    scheduleCaptionsInactive();
    scheduleLocate(0);
    scheduleMicLocate(0);
    kickAutoCaptions();
  };

  // Shared DOM helpers exposed to the per-host adapter that loads after this file. An adapter's rowsFrom /
  // locateCaptionRegion / captionsToggle reuse these instead of re-implementing them.
  globalThis.__recapCore = {
    cleanText,
    isVisibleElement,
    isInteractive,
    isNameLike,
    isPlausibleCaptionText,
    childTextFragments,
    visibleElementChildren,
    uniqueRows,
    parseCaptionRow,
    elementLabelText,
    isCaptionLabelled,
    isPotentialCaptionSurface,
    MAX_SCAN_ELEMENTS,
    MAX_TEXT_LENGTH,
  };

  // The single entry point. The per-host adapter calls this with its adapter object to start the engine.
  // Runs at most once per frame; honours an optional adapter.matches(location) guard.
  globalThis.__recapRun = (nextAdapter) => {
    if (adapter || !nextAdapter) {
      return;
    }
    if (typeof nextAdapter.matches === "function" && !nextAdapter.matches(location)) {
      return;
    }
    adapter = nextAdapter;
    window.addEventListener("pagehide", shutdown, { once: true });
    void start();
  };
})();
