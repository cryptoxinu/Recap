// Recap adapter — Microsoft Teams WEB only (teams.microsoft.com, teams.live.com). Loaded AFTER core.js.
//
// Teams uses stable `data-tid` hooks for its live-caption renderer, so per-speaker turns are cleaner than
// Meet's obfuscated classes. Selectors below are the known-stable set (renderer / message / author /
// text). Still: ⚠️ FOUNDER VERIFICATION REQUIRED on a live Teams web call — Teams periodically reshuffles
// its `fui-*` message classes and hides the captions toggle behind the More (…) menu, which this enables
// best-effort. Safety net regardless: if scraping fails, the Mac app still captures the call via
// system-audio + FluidAudio diarization (diarized "Speaker N", no scraped names). Also note MOST Teams
// users run the DESKTOP app (no browser DOM) — those calls fall back to system-audio capture entirely.
(() => {
  "use strict";

  const {
    cleanText,
    isVisibleElement,
    isPlausibleCaptionText,
    uniqueRows,
    elementLabelText,
    MAX_SCAN_ELEMENTS,
  } = globalThis.__recapCore;

  // Known-stable Teams caption selectors.
  const TEAMS_RENDERER_SELECTORS = [
    "[data-tid='closed-captions-renderer']",
    "[data-tid*='closed-caption']",
  ];
  const TEAMS_MESSAGE_SEL = ".fui-ChatMessageCompact";
  const TEAMS_AUTHOR_SEL = "[data-tid='author']";
  const TEAMS_TEXT_SEL = "[data-tid='closed-caption-text']";

  // Captions enable (best-effort via the More menu) + mic hint selectors.
  const TEAMS_MORE_BTN_SEL = "button[data-tid='more-button'], #callingButtons-showMoreBtn";
  const TEAMS_MIC_SEL = "[data-tid='toggle-mute'], [data-tid='microphone-button']";
  const TEAMS_CAPTIONS_ON_RE = /\b(turn on|show) (live )?(captions|subtitles?)\b/i;
  const TEAMS_CAPTIONS_OFF_RE = /\b(turn off|hide) (live )?(captions|subtitles?)\b/i;

  const teamsLocateCaptionRegion = () => {
    for (const selector of TEAMS_RENDERER_SELECTORS) {
      let nodes;
      try {
        nodes = document.querySelectorAll(selector);
      } catch {
        continue;
      }
      for (const region of nodes) {
        // Skip the text leaf itself (the wildcard selector also matches [data-tid='closed-caption-text']);
        // we want the renderer container that holds the per-speaker message rows.
        if (isVisibleElement(region) && region.getAttribute("data-tid") !== "closed-caption-text") {
          return region;
        }
      }
    }
    return null;
  };

  const teamsRowsFrom = (region) => {
    if (!region || !isVisibleElement(region)) {
      return [];
    }

    const rows = [];
    let messages;
    try {
      messages = Array.from(region.querySelectorAll(TEAMS_MESSAGE_SEL));
    } catch {
      messages = [];
    }

    if (messages.length > 0) {
      for (const message of messages.slice(0, MAX_SCAN_ELEMENTS)) {
        if (!isVisibleElement(message)) {
          continue;
        }
        const authorEl = message.querySelector(TEAMS_AUTHOR_SEL);
        const textEl = message.querySelector(TEAMS_TEXT_SEL);
        const speaker = authorEl ? cleanText(authorEl.innerText) : "";
        const text = textEl ? cleanText(textEl.innerText) : "";
        if (speaker && text && isPlausibleCaptionText(speaker, text)) {
          rows.push({ speaker, text });
        }
      }
    } else {
      // Degraded fallback if the .fui message wrapper churns: pair each caption-text node with the author
      // in its nearest container.
      let texts;
      try {
        texts = Array.from(region.querySelectorAll(TEAMS_TEXT_SEL));
      } catch {
        texts = [];
      }
      for (const textEl of texts.slice(0, MAX_SCAN_ELEMENTS)) {
        if (!isVisibleElement(textEl)) {
          continue;
        }
        const container = textEl.closest(TEAMS_MESSAGE_SEL) || textEl.parentElement;
        const authorEl = container ? container.querySelector(TEAMS_AUTHOR_SEL) : null;
        const speaker = authorEl ? cleanText(authorEl.innerText) : "";
        const text = cleanText(textEl.innerText);
        if (speaker && text && isPlausibleCaptionText(speaker, text)) {
          rows.push({ speaker, text });
        }
      }
    }

    return uniqueRows(rows);
  };

  // Best-effort captions enable. If a captions menu item is already visible, act on it; otherwise open the
  // More (…) menu ONCE so the item mounts, then the next tick finds it. Conservative (opens More at most
  // once) so we never thrash the menu; a nested submenu may still require the founder to enable manually.
  const teamsFindCaptionsMenuItem = () => {
    const items = Array.from(
      document.querySelectorAll("[role='menuitem'],[role='menuitemcheckbox'],button,[data-tid*='caption']")
    ).slice(0, MAX_SCAN_ELEMENTS);
    for (const item of items) {
      if (!isVisibleElement(item)) {
        continue;
      }
      const label = `${elementLabelText(item)} ${cleanText(item.textContent || "")}`;
      if (TEAMS_CAPTIONS_ON_RE.test(label)) {
        return { button: item, off: true };
      }
      if (TEAMS_CAPTIONS_OFF_RE.test(label)) {
        return { button: item, off: false };
      }
    }
    return null;
  };

  let teamsOpenedMore = false;
  const teamsCaptionsToggle = () => {
    try {
      const direct = teamsFindCaptionsMenuItem();
      if (direct) {
        teamsOpenedMore = false;
        return direct;
      }
      if (!teamsOpenedMore) {
        const more = document.querySelector(TEAMS_MORE_BTN_SEL);
        if (more && isVisibleElement(more)) {
          teamsOpenedMore = true;
          more.click(); // reveal the menu; the captions item is picked up on a later tick
        }
      }
    } catch {
      // Never throw into the Teams page.
    }
    return null; // not resolved this tick — the core ticker retries
  };

  const teamsLocateMicButton = () => {
    try {
      const nodes = document.querySelectorAll(TEAMS_MIC_SEL);
      for (const node of nodes) {
        const button = node.matches?.("button,[role='button']")
          ? node
          : node.closest?.("button,[role='button']") || node;
        if (button && isVisibleElement(button)) {
          return button;
        }
      }
    } catch {
      // fall through to null → core's generic mic scoring tries
    }
    return null;
  };

  const teamsMicMuted = (button) => {
    const label = elementLabelText(button);
    // Test "unmute" first: the action label describes what a click WOULD do, so "Unmute" ⇒ currently muted.
    if (/\bunmute\b/i.test(label)) {
      return true;
    }
    if (/\bmute\b/i.test(label)) {
      return false;
    }
    const pressed = button.getAttribute("aria-pressed");
    if (pressed === "true") {
      return true;
    }
    if (pressed === "false") {
      return false;
    }
    return null;
  };

  const teamsMeetingId = () => {
    try {
      return location.pathname || "";
    } catch {
      return "";
    }
  };

  const TeamsAdapter = {
    id: "teams",
    locateCaptionRegion: teamsLocateCaptionRegion,
    rowsFrom: teamsRowsFrom,
    locateMicButton: teamsLocateMicButton,
    micMuted: teamsMicMuted,
    captionsToggle: teamsCaptionsToggle,
    meetingId: teamsMeetingId,
  };

  globalThis.__recapRun(TeamsAdapter);
})();
