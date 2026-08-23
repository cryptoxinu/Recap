// Recap adapter — Zoom WEB client only (app.zoom.us/wc, *.zoom.us/wc). Loaded AFTER core.js.
//
// ⚠️ FOUNDER VERIFICATION REQUIRED (live call): Zoom's caption/transcript DOM is NOT reliably documented
// publicly and cannot be live-inspected from here. The selectors below are a BEST-KNOWN fast path guarded
// by core.js's GENERIC aria/heuristic fallback, so the adapter degrades gracefully when Zoom churns its
// classes. Before shipping, open a real Zoom web call, turn on captions + "View Full Transcript", and
// snapshot `[class*='transcription'],[class*='caption'],[class*='transcript'],[aria-live]` to confirm /
// tighten the fast-path selectors. Safety net regardless: if scraping fails, the Mac app still captures
// the call via system-audio + FluidAudio diarization (diarized "Speaker N", no scraped names).
(() => {
  "use strict";

  const {
    cleanText,
    isVisibleElement,
    isInteractive,
    isNameLike,
    isPlausibleCaptionText,
    uniqueRows,
    parseCaptionRow,
    elementLabelText,
    MAX_SCAN_ELEMENTS,
  } = globalThis.__recapCore;

  // Preferred fast path: the "View Full Transcript" side panel (per-speaker items). BEST-GUESS selectors.
  const ZOOM_TRANSCRIPT_PANEL_SELECTORS = [
    "[class*='full-transcript']",
    "[class*='transcript'][class*='panel']",
    "[aria-label*='ranscript' i]",
    "[class*='transcript']",
  ];
  // Per-speaker item within the transcript panel. BEST-GUESS selectors.
  const ZOOM_TRANSCRIPT_ITEM_SELECTORS = [
    "[class*='transcript-item']",
    "[class*='transcript'][class*='item']",
    "[class*='caption-item']",
    "[role='listitem']",
  ];
  const ZOOM_ITEM_NAME_SELECTORS =
    "[class*='display-name'],[class*='speaker'],[class*='author'],[class*='name']";
  const ZOOM_ITEM_TEXT_SELECTORS =
    "[class*='text'],[class*='content'],[class*='body'],[class*='message']";
  // Fallback: the aria-live single-line caption overlay (parsed generically by core). BEST-GUESS selectors.
  const ZOOM_CAPTION_OVERLAY_SELECTORS = [
    "[class*='live-transcription']",
    "[class*='closed-caption']",
    "[class*='caption'][aria-live]",
    "[aria-live='polite'][class*='caption']",
  ];
  // The caption/transcript enable control's accessible label appears only while captions are OFF.
  const ZOOM_CAPTIONS_ON_LABEL_RE = /\b(show|turn on) (captions|subtitles?)|live transcript\b/i;
  const ZOOM_CAPTIONS_OFF_LABEL_RE = /\b(hide|turn off) (captions|subtitles?)\b/i;

  // Parse one region into per-speaker rows via the structured transcript-item fast path. Returns [] when
  // it can't parse structured items, letting core's generic extractCaptionRows handle a caption overlay.
  const zoomRowsFrom = (region) => {
    if (!region || !isVisibleElement(region)) {
      return [];
    }

    let items = [];
    for (const selector of ZOOM_TRANSCRIPT_ITEM_SELECTORS) {
      try {
        items = Array.from(region.querySelectorAll(selector));
      } catch {
        items = [];
      }
      if (items.length > 0) {
        break;
      }
    }

    const rows = [];
    for (const item of items.slice(0, MAX_SCAN_ELEMENTS)) {
      if (!isVisibleElement(item) || isInteractive(item)) {
        continue;
      }

      const nameEl = item.querySelector(ZOOM_ITEM_NAME_SELECTORS);
      const textEl = item.querySelector(ZOOM_ITEM_TEXT_SELECTORS);
      let speaker = nameEl ? cleanText(nameEl.textContent) : "";
      let text = textEl ? cleanText(textEl.textContent) : "";

      // If the name/text sub-elements don't resolve (class churn), fall back to core's generic name+text
      // split within this single item so a differently-shaped item still yields a row.
      if (!speaker || !text) {
        const parsed = parseCaptionRow(item);
        if (parsed) {
          speaker = parsed.speaker;
          text = parsed.text;
        }
      }

      if (isNameLike(speaker) && isPlausibleCaptionText(speaker, text)) {
        rows.push({ speaker, text });
      }
    }

    return uniqueRows(rows);
  };

  const zoomLocateCaptionRegion = () => {
    // Preferred: the full-transcript side panel (only accept a region that actually yields rows).
    for (const selector of ZOOM_TRANSCRIPT_PANEL_SELECTORS) {
      let nodes;
      try {
        nodes = document.querySelectorAll(selector);
      } catch {
        continue;
      }
      for (const region of nodes) {
        if (isVisibleElement(region) && !isInteractive(region) && zoomRowsFrom(region).length > 0) {
          return region;
        }
      }
    }

    // Fallback: the aria-live caption overlay. Return it if it has text; core's generic extractCaptionRows
    // (via scanForRows) parses it since zoomRowsFrom won't match the overlay's structure.
    for (const selector of ZOOM_CAPTION_OVERLAY_SELECTORS) {
      let nodes;
      try {
        nodes = document.querySelectorAll(selector);
      } catch {
        continue;
      }
      for (const region of nodes) {
        if (isVisibleElement(region) && !isInteractive(region) && cleanText(region.textContent)) {
          return region;
        }
      }
    }

    return null; // let core's generic locateByAria / locateByHeuristic try
  };

  // Best-effort: click the caption/transcript enable control once per meeting when captions are OFF.
  const zoomCaptionsToggle = () => {
    try {
      const candidates = Array.from(
        document.querySelectorAll("button,[role='button'],[role='menuitem']")
      ).slice(0, MAX_SCAN_ELEMENTS);

      for (const candidate of candidates) {
        const button = candidate.matches?.("button,[role='button'],[role='menuitem']")
          ? candidate
          : candidate.closest?.("button,[role='button'],[role='menuitem']");
        if (!button || !isVisibleElement(button)) {
          continue;
        }

        const label = `${elementLabelText(button)} ${cleanText(button.textContent || "")}`;
        if (ZOOM_CAPTIONS_ON_LABEL_RE.test(label)) {
          return { button, off: true }; // "show/turn on captions" only shows while captions are OFF
        }
        if (ZOOM_CAPTIONS_OFF_LABEL_RE.test(label)) {
          return { button, off: false }; // already on — mark done without clicking
        }
      }
    } catch {
      // Never throw into the Zoom page; a later attempt can recover.
    }

    return null;
  };

  // The Zoom web meeting URL path is a stable per-meeting identity (e.g. /wc/<id>/...).
  const zoomMeetingId = () => {
    try {
      return location.pathname || "";
    } catch {
      return "";
    }
  };

  // Mic detection intentionally omitted → core's generic label/attribute scoring tries. Zoom's mute button
  // isn't reliably labelled "microphone", so mic state may be unavailable; the recorder does not depend on
  // it (system-audio capture records the call regardless).
  const ZoomAdapter = {
    id: "zoom",
    locateCaptionRegion: zoomLocateCaptionRegion,
    rowsFrom: zoomRowsFrom,
    captionsToggle: zoomCaptionsToggle,
    meetingId: zoomMeetingId,
  };

  globalThis.__recapRun(ZoomAdapter);
})();
