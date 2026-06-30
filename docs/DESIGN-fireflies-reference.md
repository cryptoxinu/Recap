# CallBrain UI — Fireflies-style Design Reference

> The founder wants CallBrain's Mac app to look and feel like **Fireflies.ai** (clean, calm, modern)
> with its **persistent "AskFred"-style chat**. This captures that target so the SwiftUI build matches it.
> Source: founder-provided Fireflies Home screenshot (2026-06-29). Build with `swift-macos-sme` +
> `native-mac-qa-sme` + the `picasso` design skill; this is **Path-B polish**, not a stock template.

## Layout (three columns — maps cleanly to `NavigationSplitView`)

```
┌──────────────┬─────────────────────────────────────────────┬───────────────────────────┐
│  SIDEBAR     │  TOP BAR: ⌘K global search · Import · status │                           │
│  (~230pt)    ├─────────────────────────────────────────────┤   ASK AI  (~340pt)        │
│  ◇ Home      │  Good Evening, Zade 🌙      [Assistant ⏻]    │  "Hi Zade! Ready for      │
│  ◇ Ask AI    │                                             │   your day"               │
│  ◇ Meetings  │  ┌────────┐ ┌────────┐ ┌────────┐            │                           │
│  ◇ Tasks     │  │ Daily  │ │Meeting │ │ Tasks  │  cards     │  ▸ Prep me for morning… │
│  ◇ People    │  │ Digest │ │ Prep   │ │ 7 days │            │  ▸ Action items from…     │
│  ◇ Partners  │  └────────┘ └────────┘ └────────┘            │  ▸ What's my day like?    │
│  ◇ Topics    │                                             │  ▸ Pending tasks across…  │
│  ◇ Import    │  [ Recent | Upcoming | AI Feed ]            │                           │
│  ◇ Settings  │  ● Ambient Internal Demos   Jun 26 · 12:31  │  ┌─────────────────────┐  │
│              │  ● Travis / Zade Quick Sync Jun 25 · 5:15   │  │ Ask anything across  │  │
│  [avatar]    │  ● zid-uzze-szs            Jun 25 · 7:13    │  │ your meetings…   ▸   │  │
└──────────────┴─────────────────────────────────────────────┴───────────────────────────┘
```

## Sidebar (NavigationSplitView sidebar)
Destinations (icon + label, soft hover, selected = tinted pill):
**Home · Ask AI · Meetings · Tasks · People · Partners · Topics · Import Queue · Settings.**
Bottom: account avatar + engine-status pill (Ollama ●, provider ● claude/codex). Collapsible (⌘\\ /
toolbar chevron). Use SF Symbols, not custom icons, for native feel.

## Top bar (`.toolbar`)
- **Global search** front-and-center: `⌘K` palette — "Search by title or keyword" → instant catalogue
  search (FTS) with type-ahead, scoped filters (person/company/date).
- Right: **Import** (drag-drop target + file picker), engine/storage status, notifications bell.

## Home (the dashboard)
- **Greeting** with time-of-day + 🌙/☀️ ("Good Evening, Zade").
- **Three assistant cards** (rounded, pastel icon tiles, generous padding):
  1. **Daily Digest** — "From your N recent calls".
  2. **Pre-Call Briefing** — next meeting + countdown ("in 13 hrs") *(uses Pre-Call Briefing mode)*.
  3. **Tasks** — open/overdue this week count *(date-gated, §7.5)*.
- **Recent calls list**: avatar/source glyph + title + "Jun 29 · 10:37 PM" + tags. Tabs Recent /
  Upcoming / AI Feed. Row → Meeting Detail.

## Ask AI panel (the "AskFred" equivalent) — the centerpiece
- Persistent right-hand panel **and** a full Ask AI screen (⌘⇧A). Friendly greeting header.
- **Suggested prompt chips** generated from the archive: "Prep me for morning sync", "Action items
  from Zade & team", "What's my day looking like?", "Pending tasks across all meetings".
- **"Ask anything across your meetings"** input (multiline, attach, ⏎ to send).
- **Streaming answer** with the citation contract: inline `[S#]` chips that, on click, open the
  Transcript Viewer at the cited line. Confirmed/Inferred sections rendered distinctly. Provider chip
  (claude/codex) + "answered from N calls". This is where our engine (AskEngine) already shines.

## Visual language (calm, premium — not "stock SwiftUI")
- **Light, airy**, lots of whitespace; rounded cards (~12–16pt radius), hairline separators.
- **One accent** (Fireflies uses violet) for primary actions (Import/Capture, send) + selected nav.
- Pastel tile backgrounds for the assistant-card icons.
- Native typography (system / rounded for headings); Dark + Light, semantic colors only (off-token
  colors are an instant `native-mac-qa-sme` reject).
- Motion: subtle, owed only — list insert, streaming token fade, panel slide. No gratuitous animation.

## Build order for the app target (Phase-1 UI then Path-B polish)
1. `NavigationSplitView` shell + sidebar + toolbar (⌘K, Import) + Dark/Light.
2. **Ask AI** screen/panel wired to `AskEngine` (streaming + `[S#]` citations) — the highest-value, most
   "Fireflies" surface; do it first.
3. **Meetings** list + **Meeting Detail** + **Transcript Viewer** (click `[S#]` → jump to line).
4. **Home** dashboard (greeting + assistant cards + recent calls + suggested chips).
5. Tasks · People · Partners · Topics, then drag-drop Import Queue, notifications, menu-bar (Path-B).

QA every build with `native-mac-qa-sme` (launch, drive, screenshot, critique) — bubbles must hug
content, buttons must be wired, empty states must teach, no raw markdown flash during streaming.
