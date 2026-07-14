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
  const CAPTIONS_ACTION_LABEL_RE = /\bturn (?:on|off) captions\b/i; // the explicit CC toggle action label
  const CAPTIONS_OFF_LABEL_RE = /\bturn on captions\b/i; // Meet shows this label only when captions are OFF
  const CAPTIONS_ICON_RE = /\bclosed_caption(_off)?\b/;  // Material Symbols ligature on icon-only CC buttons
  const CAPTIONS_LOOKALIKE_RE = /summar|translat|language|setting|option/i; // NEVER click these CC look-alikes
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

  // Google Meet renders live captions as a scrollable region of per-speaker ENTRIES. Each entry
  // carries an avatar <img>, a short speaker-name node, and the spoken-text node as SEPARATE nodes.
  // Meet's obfuscated class/jsname values drift, so the durable anchor is that avatar <img>: one per
  // speaker turn. These region selectors are only a fast hint — refresh them from a live solo Meet
  // ("New meeting" → CC on → inspect) if Meet changes them; the avatar-anchored structural path below
  // is what actually keeps this working across DOM churn.
  // Ordered most-specific → most-general. Every match is still gated (visible, non-interactive, yields
  // parseable rows) in locateMeetCaptionRegion, so the broad aria-label matches can't grab the wrong
  // box. The role-agnostic `[aria-label*='aption' i]` future-proofs against Meet dropping/renaming the
  // ARIA role or churning its obfuscated jsname/class values (the durable signal is the a11y label).
  const MEET_CAPTION_REGION_SELECTORS = [
    "[role='region'][aria-label*='aption' i]",
    "[role='log'][aria-label*='aption' i]",   // Meet sometimes exposes captions as a live log
    "[aria-label*='aption' i]",               // any labelled element (row-gated below)
    "div[jsname='dsyhDe']",
    "div[jsname='YSxPC']",
    ".a4cQT"
  ];
  const MEET_ENTRY_CLIMB_LIMIT = 6;

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
  let autoCaptionsMeetingId = null; // re-arms auto-CC when the Meet URL changes (SPA meeting switch)
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
        body: JSON.stringify({ speaker, text, final })
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
        body: JSON.stringify({ muted }),
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

  // ── Meet-specific caption parsing (avatar-anchored, one row per speaker turn) ─────────────
  // This is the primary path for real Google Meet calls and the fix for the merged-wall bug:
  // instead of flattening a whole container, we find each caption ENTRY by its avatar <img>,
  // climb to the SMALLEST ancestor that forms a complete name+text entry, and read its distinct
  // name node vs text node separately.

  // Parse one Meet caption entry into { speaker, text }. The name is the first name-like fragment;
  // the utterance is the remaining fragments of THIS entry (one speaker turn) joined — an entry is
  // never bounded, so short lines ("Yes", "Sounds good") survive. A name-only row (participant roster)
  // yields empty text and is dropped.
  const parseMeetEntry = (entry) => {
    if (!isVisibleElement(entry) || isInteractive(entry)) {
      return null;
    }
    const fragments = childTextFragments(entry);
    if (fragments.length < 2) {
      return null;
    }
    const maxSpeakerIndex = Math.min(2, fragments.length - 1);
    for (let index = 0; index <= maxSpeakerIndex; index += 1) {
      const speaker = cleanText(fragments[index]);
      if (!isNameLike(speaker)) {
        continue;
      }
      const text = cleanText(
        fragments
          .slice(index + 1)
          .filter((fragment) => cleanText(fragment) !== speaker)
          .join(" ")
      );
      if (isPlausibleCaptionText(speaker, text)) {
        return { speaker, text };
      }
    }
    return null;
  };

  // Climb from an avatar image to the SMALLEST ancestor that parses as a complete caption entry — so we
  // never climb up into sibling chrome (a language strip, meeting title). Never crosses into an ancestor
  // that groups a SECOND avatar (a different speaker's turn); returns null for roster/non-caption avatars.
  const meetEntryFromAvatar = (img, region) => {
    let current = img.parentElement;
    let steps = 0;
    while (current && current !== region && region.contains(current) && steps <= MEET_ENTRY_CLIMB_LIMIT) {
      if (parseMeetEntry(current)) {
        return current;
      }
      const parent = current.parentElement;
      if (!parent || parent === region || !region.contains(parent)) {
        break;
      }
      let parentImgCount;
      try {
        parentImgCount = parent.querySelectorAll("img").length;
      } catch {
        break;
      }
      if (parentImgCount > 1) {
        break; // parent groups another speaker's avatar — don't merge turns
      }
      current = parent;
      steps += 1;
    }
    return null;
  };

  const meetCaptionEntries = (region) => {
    if (!region || !isVisibleElement(region)) {
      return [];
    }
    let imgs;
    try {
      imgs = Array.from(region.querySelectorAll("img"));
    } catch {
      return [];
    }
    const entries = [];
    const seen = new Set();
    for (const img of imgs) {
      if (!isVisibleElement(img)) {
        continue;
      }
      const entry = meetEntryFromAvatar(img, region);
      if (entry && !seen.has(entry)) {
        seen.add(entry);
        entries.push(entry);
      }
    }
    return entries;
  };

  // Avatar-less fallback for the current Google Meet caption UI (the "Summarize captions"-pill variant):
  // each turn renders as a speaker-name element + a text element with NO per-speaker avatar <img>, so the
  // avatar-anchored path above finds nothing. We instead locate the SMALLEST containers that parse as a
  // complete name+text entry. "Smallest" is the key to one-row-per-turn: if a descendant of a candidate
  // ALSO parses as an entry, this candidate spans more than one turn (or is the whole scroll region), so
  // we skip it — that's what prevents the two speakers' words merging into a single wall.
  const meetRowsWithoutAvatar = (region) => {
    if (!region || !isVisibleElement(region)) {
      return [];
    }
    let candidates;
    try {
      candidates = Array.from(region.querySelectorAll("div,li,section,p")).slice(0, MAX_SCAN_ELEMENTS);
    } catch {
      return [];
    }
    const minimalEntries = [];
    const seen = new Set();
    for (const candidate of candidates) {
      if (!isVisibleElement(candidate) || isInteractive(candidate) || !parseMeetEntry(candidate)) {
        continue;
      }
      let hasParsingDescendant = false;
      try {
        for (const inner of candidate.querySelectorAll("div,li,section,p")) {
          if (inner !== candidate && isVisibleElement(inner) && !isInteractive(inner) && parseMeetEntry(inner)) {
            hasParsingDescendant = true;
            break;
          }
        }
      } catch {
        // Treat as minimal if we can't inspect descendants.
      }
      if (hasParsingDescendant || seen.has(candidate)) {
        continue;
      }
      seen.add(candidate);
      minimalEntries.push(candidate);
    }
    return uniqueRows(minimalEntries.map(parseMeetEntry).filter(Boolean));
  };

  const meetRowsFrom = (root) => {
    // Primary: avatar-anchored entries (one <img> per speaker turn). Fallback: the avatar-less name+text
    // layout. Both keep turns separate; whichever yields rows wins so we never regress the avatar path.
    const entries = meetCaptionEntries(root);
    const avatarRows = uniqueRows(entries.map(parseMeetEntry).filter(Boolean));
    if (avatarRows.length > 0) {
      return avatarRows;
    }
    return meetRowsWithoutAvatar(root);
  };

  // Try Meet's real caption region first. Evaluate EVERY visible match of each selector (not just the
  // first) so a caption-settings region that matches earlier can't shadow the actual transcript region.
  const locateMeetCaptionRegion = () => {
    for (const selector of MEET_CAPTION_REGION_SELECTORS) {
      let nodes;
      try {
        nodes = document.querySelectorAll(selector);
      } catch {
        continue;
      }
      for (const region of nodes) {
        if (isVisibleElement(region) && !isInteractive(region) && meetRowsFrom(region).length > 0) {
          return region;
        }
      }
    }
    return null;
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
    // Prefer Meet's structured per-entry parse (avatar-anchored → one row per speaker turn). This is
    // what prevents the whole-region-flattened "merged wall"; the generic extract is the fallback for
    // non-Meet / avatar-less layouts.
    const meetRows = meetRowsFrom(surface);
    if (meetRows.length > 0) {
      return meetRows;
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

      const muted = micMutedFromButton(micButton);
      if (typeof muted === "boolean") {
        sendMicStateIfChanged(muted);
      }
    } catch {
      // Never throw into the Meet page; a later locate pass can recover.
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

      const button = locateMicButton();
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

  // ── Auto-enable Google Meet captions (A2) ─────────────────────────────────────────────────
  // The founder had to turn on CC manually for the relay to work. When Recap is paired and the
  // in-call captions toggle is present, click it once if captions are OFF. The button's accessible
  // label describes the ACTION: "Turn on captions" ⇒ currently off. We act at most once per meeting so
  // we never fight a user who deliberately turns captions back off.
  // Read the CC toggle's on/off state from a Material Symbols icon ligature ("closed_caption" /
  // "closed_caption_off") plus aria-pressed — for Meet builds whose CC button carries no text label.
  // Returns true (captions off), false (on), or null when this button isn't the captions toggle.
  const captionsIconOffState = (button) => {
    const iconText = Array.from(button.querySelectorAll("i,span"))
      .map((node) => cleanText(node.textContent || ""))
      .find((text) => CAPTIONS_ICON_RE.test(text));
    if (!iconText) return null;
    const pressed = button.getAttribute("aria-pressed");
    if (pressed === "true") return false;
    if (pressed === "false") return true;
    return /_off\b/.test(iconText); // no pressed state — the "_off" icon variant means captions are off
  };

  const locateCaptionsToggle = () => {
    try {
      const candidates = Array.from(
        document.querySelectorAll("button,[role='button']")
      ).slice(0, MAX_SCAN_ELEMENTS);

      let iconFallback = null;
      for (const candidate of candidates) {
        const button = candidate.matches?.("button,[role='button']")
          ? candidate
          : candidate.closest?.("button,[role='button']");
        if (!button || !isVisibleElement(button)) {
          continue;
        }

        const label = elementLabelText(button);
        // Highest confidence: the explicit "Turn on/off captions" action label wins outright.
        if (CAPTIONS_ACTION_LABEL_RE.test(label)) {
          return { button, off: CAPTIONS_OFF_LABEL_RE.test(label) };
        }
        // Fallback for icon-only CC buttons — remember the first, but keep scanning so a later
        // explicit-label button still wins. Skip Summarize/language/settings look-alikes — and test the
        // button's TEXT CONTENT too, not just the accessible label: a look-alike like "Summarize captions"
        // can derive its name from native child text that elementLabelText() doesn't read (Codex P2).
        if (!iconFallback) {
          const exclusionText = `${label} ${cleanText(button.textContent || "")}`;
          if (!CAPTIONS_LOOKALIKE_RE.test(exclusionText)) {
            const iconOff = captionsIconOffState(button);
            if (iconOff !== null) {
              iconFallback = { button, off: iconOff };
            }
          }
        }
      }
      return iconFallback;
    } catch {
      // Never throw into the Meet page; a later attempt can recover.
    }

    return null;
  };

  // Meet call URLs look like /abc-defg-hij; the whole pathname is a stable per-meeting identity.
  const meetingIdFromLocation = () => {
    try {
      return location.pathname || "";
    } catch {
      return "";
    }
  };

  // A single self-rescheduling ticker (never a give-up cap): it re-arms auto-CC when the meeting URL
  // changes (SPA switch to a new call), enables captions once when paired + the toggle appears (even if
  // the toolbar mounts long after join), then idles cheaply just to watch for the next meeting change.
  const autoCaptionsTick = () => {
    try {
      const meetingId = meetingIdFromLocation();
      if (meetingId !== autoCaptionsMeetingId) {
        autoCaptionsMeetingId = meetingId;
        captionsAutoDone = false; // new meeting — enable captions again (but only once for it)
      }

      if (!captionsAutoDone && autoCaptionsEnabled && hasUsableConfig()) {
        const toggle = locateCaptionsToggle();
        if (toggle) {
          if (toggle.off) {
            toggle.button.click();
          }
          // Already on OR just enabled — done for THIS meeting; respect any later manual off.
          captionsAutoDone = true;
        }
      }
    } catch {
      // never throw into the Meet page
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

      // Meet-aware even in the deepest fallback: if the region selectors have all drifted but avatar-
      // anchored entries still exist, recover via the structural path; otherwise the generic extract.
      let rows = candidate.querySelector("img") ? meetRowsFrom(candidate) : [];
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

  // Prefer Meet's real caption region (tight, excludes the roster + language chrome) so we observe
  // the right subtree and never sweep participant names / "Live captions" UI into the transcript.
  const locateCaptionsContainer = () => locateMeetCaptionRegion() || locateByAria() || locateByHeuristic();

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
    scheduleCaptionsInactive();
    scheduleLocate(0);
    scheduleMicLocate(0);
    kickAutoCaptions();
  };

  window.addEventListener("pagehide", shutdown, { once: true });
  void start();
})();
