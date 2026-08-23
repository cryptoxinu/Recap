// Recap adapter — Google Meet (meet.google.com). Loaded AFTER core.js by the per-host content_scripts
// entry. Every function below is relocated UNCHANGED from the original single-file content.js so Meet
// behaviour stays byte-for-byte identical; the only new code is (a) destructuring core's shared helpers
// so the bare names still resolve, (b) the MeetAdapter object, and (c) the __recapRun(MeetAdapter) call.
(() => {
  "use strict";

  // Shared DOM helpers provided by core.js (loaded first). Destructured so the moved Meet functions can
  // keep referencing the bare names exactly as they did in content.js.
  const {
    cleanText,
    isVisibleElement,
    isInteractive,
    isNameLike,
    isPlausibleCaptionText,
    childTextFragments,
    uniqueRows,
    elementLabelText,
    MAX_SCAN_ELEMENTS,
  } = globalThis.__recapCore;

  const CAPTIONS_ACTION_LABEL_RE = /\bturn (?:on|off) captions\b/i; // the explicit CC toggle action label
  const CAPTIONS_OFF_LABEL_RE = /\bturn on captions\b/i; // Meet shows this label only when captions are OFF
  const CAPTIONS_ICON_RE = /\bclosed_caption(_off)?\b/;  // Material Symbols ligature on icon-only CC buttons
  const CAPTIONS_LOOKALIKE_RE = /summar|translat|language|setting|option/i; // NEVER click these CC look-alikes

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

  // The Meet adapter. Mic detection is intentionally omitted so core's generic label/attribute scoring
  // (the exact path the original content.js used on Meet) drives the mic indicator — unchanged behaviour.
  const MeetAdapter = {
    id: "meet",
    locateCaptionRegion: locateMeetCaptionRegion,
    rowsFrom: meetRowsFrom,
    captionsToggle: locateCaptionsToggle,
    meetingId: meetingIdFromLocation,
  };

  globalThis.__recapRun(MeetAdapter);
})();
