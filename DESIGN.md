# Agent Monitor — Design

Two parts: **visual design** (how it looks and feels) and **architecture** (how it is built).
Behaviour and data sources are specified in `GUIDE.md`.

---

# Part 1 — Visual design

## 1.1 Principles

- **Glanceable**: state is read from colour alone; detail is one hover away.
- **Calm**: every state uses the same intensity — no blinking, no badges, no alarms. "Needs you"
  red is toned down to sit at the same saturation/lightness as yellow and green.
- **Glass on dark**: translucent, blurred, blue-tinted surfaces; crisp text on top.
- **Stable layout**: icons never reorder or resize while a session lives; the card never jumps or closes on updates.
- **Compact**: square icon pills the height of the strip; one fixed-width card.

## 1.2 Palette

Base ("Event Horizon" — deep navy):

| Token        | Value      | Use |
|--------------|------------|-----|
| `crust`      | `#060a14`  | darkest backdrop |
| `base`       | `#0a1020`  | pill fill (at 38 % alpha) |
| `surface`    | `#162038`  | hover fill (at 60 % alpha) |
| `overlay`    | `#22304f`  | — |
| `muted`      | `#56688f`  | captions, hint, separators |
| `subtext`    | `#9db0d3`  | secondary text, model/effort, timers |
| `text`       | `#e1e9f7`  | primary text, numbers |
| `accent`     | `#2b5cff`  | fills (context bar <50 %), hover border (22 %) |
| `accent-hi`  | `#7d98ff`  | accent-coloured icons/text on dark glass |
| `cyan`       | `#56d4f5`  | small highlights ("tokens read" arrow) |

State colours:

| State     | Colour    |
|-----------|-----------|
| `working` | `#f5c97a` (warm yellow) |
| `input`   | `#ec6a7d` (soft red)    |
| `done`    | `#5fe0b8` (mint green)  |
| `ready`   | `#9db0d3` (= `subtext`, grey-blue) |

Glass:

| Surface        | Value |
|----------------|-------|
| Card background | `rgba(#17223f, 0.70)` + background blur of whatever is behind |
| Card border     | 1 px `rgba(#7d98ff, 0.16)` |
| Hairline        | `rgba(255,255,255,0.07)` |
| Subtle surface  | `rgba(255,255,255,0.045)` |

Use a **flat** colour for the card background (no gradient) so partial redraws stay clean.

## 1.3 Typography

- UI font: **Inter**, base 13 px, weight 600. Icon glyphs from a monospaced icon font
  (or native symbol set) at the sizes given below.
- All numbers that tick (timers, token counts, percentages) use **tabular figures** so they don't jitter.

| Element                 | Size | Weight | Colour |
|-------------------------|------|--------|--------|
| Card title              | 14   | 700    | `text` |
| Directory               | 12   | 600    | `text` |
| Model                   | 12   | 600    | `subtext` |
| `·` separator           | 12   | —      | `muted` |
| Effort                  | 12   | 500    | `subtext` |
| State text              | 12   | 700    | state colour |
| "for 3m"                | 11   | 600    | `subtext`, tabular |
| Captions (`context`, `tokens written`, `tokens read`) | 10 | 700 | `muted` |
| Context value           | 11   | 600    | `subtext`, tabular |
| Token numbers           | 15   | 700    | `text`, tabular |
| Hint                    | 10   | 500    | `muted` |

## 1.4 Agent icons

- Use each vendor's **official mark**, recoloured to a **single solid fill in the state colour**:
  - **Claude**: the Anthropic starburst path, filled.
  - **Codex**: the cloud silhouette filled with the state colour; the `>_` glyph inside is
    **punched out** (transparent), not white. Trim transparent margins so it fills the square.
  - **Copilot**: the mascot path only — drop the white disc behind it; crop to the mascot so it
    fills the icon like the others.
- Rendered at **16 × 16** inside the pill. Provide one variant per state (or tint at runtime).

## 1.5 The strip

```
 ┌────┐ ┌────┐ ┌────┐
 │ ✳  │ │ ☁  │ │ ◉  │      ← 32×32 square pills, 6 px apart
 └────┘ └────┘ └────┘
```

| Property            | Value |
|---------------------|-------|
| Pill size           | 32 × 32 (30 px content + 1 px border each side) |
| Gap between pills   | 6 px |
| Corner radius       | 11 px |
| Fill                | `rgba(base, 0.38)` |
| Border              | 1 px `rgba(255,255,255,0.06)`; per state: `rgba(<state colour>, 0.20)` (`ready` keeps the neutral border) |
| Hover               | fill `rgba(surface, 0.6)`, border `rgba(accent, 0.22)` |
| Transitions         | background + border colour, 240 ms, ease `cubic-bezier(0.16, 1, 0.3, 1)` (expo-out) |
| Empty               | strip fully collapsed (no width, no gap) |

## 1.6 The hover card

```
╭──────────────────────────────────────────╮
│        Refactor the auth middleware       │  title
│                                           │
│   ▭ my-project          ◈ opus 4.6 · high │  where / what
│                                           │
│ ┌───────────────────────────────────────┐ │
│ │ ● needs you · permission      for 2m  │ │  state chip
│ └───────────────────────────────────────┘ │
│ context                 84k / 200k · 42%  │
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │  6 px bar
│ ┌─────────────────┐ ┌─────────────────┐   │
│ │ ↑ 12k           │ │ ↓ 1.4M          │   │  token tiles
│ │ tokens written  │ │ tokens read     │   │
│ └─────────────────┘ └─────────────────┘   │
│        click to go to this window         │
╰──────────────────────────────────────────╯
```

| Property               | Value |
|------------------------|-------|
| Outer width            | 314 px (fixed); content width 288 px |
| Height                 | fits content |
| Padding                | 14 top · 12 right · 10 bottom · 12 left |
| Corner radius          | 16 px |
| Vertical rhythm        | 12 px between sections; 9 px between title and where-row |
| Position               | 4 px below the strip; horizontally centred on the hovered icon; ≥ 8 px from screen edges |
| Show / hide            | instant on hover enter / leave (no tooltip delay). An optional ≤120 ms fade is fine; no slide. |
| Shadow                 | none or very soft; the border + blur define the edge |

Sections:

- **Title** — centred, single line, ellipsized at the card width; never widens the card.
- **Where row** — padding 7 × 12, 4 px extra space below. Left group: folder icon (13 px,
  `accent-hi`) + directory (ellipsized, takes remaining width). Right group: chip/model icon (13 px,
  `accent-hi`) + model `·` effort. 7 px within a group, 12 px between groups. No box/border.
- **State chip** — padding 5 × 10, radius 8, background = state colour at 12 % (`ready`: white at 5 %).
  `●` dot (8 px) + state text in the state colour; "for …" right-aligned.
- **Context** — caption left, value right; 5 px gap; bar 288 × 6, radius 6, track
  `rgba(255,255,255,0.08)`. Fill: `accent` <50 %, `working` yellow 50–79 %, `input` red ≥80 %.
  Animate width changes with the standard easing.
- **Token tiles** — two equal columns, 8 px gap, padding 7 × 10, radius 10, fill
  `rgba(255,255,255,0.045)`, border 1 px `rgba(255,255,255,0.07)`. Arrow icon (13 px): up-arrow
  `accent-hi` for written, down-arrow `cyan` for read; number 15/700; caption below.
- **Hint** — centred, muted.

## 1.7 Motion

- One easing everywhere: `cubic-bezier(0.16, 1, 0.3, 1)`.
- Colour changes (state transitions, hover): 240 ms.
- Icons appearing/disappearing: quick fade/scale-in (~200 ms); remaining icons slide into place.
- No motion on ticking values — just swap the text.

---

# Part 2 — Architecture

## 2.1 Overview

```
 ┌──────────────── Collector (1 Hz) ────────────────┐
 │  ClaudeProvider   CodexProvider   CopilotProvider │  each: discover → read incrementally → Session[]
 └──────────────┬───────────────────────────────────┘
                │  merge, isolate errors
                ▼
        SessionStore  { id → Session }
                │
     ┌──────────┴──────────┐
     ▼                     ▼
  idList (ordered)     cardModels { id → CardModel }   ← formatted strings, percentages
  changes only on       changes on any detail
  start / exit
     │                     │
     ▼                     ▼
  Strip view            Hover card view  ── click → TerminalLocator.focus(session)
```

## 2.2 Components

**Provider** (one per agent) — interface:

```text
protocol AgentProvider {
  sessions(now) -> [Session]      // never throws; returns [] on failure
}
```

Each provider owns:
- **Discovery** of live processes / state files (see GUIDE §4).
- A cache of **incremental readers** keyed by pid (transcript/event-log path + byte offset +
  partial-line buffer + accumulated counters). Evict when the session disappears; reset when the
  file path changes or the file shrinks.
- Small mtime-keyed caches for rarely changing files (settings, name index).

**Session** (raw model):

```text
id        "<kind>-<pid>"
kind      claude | codex | copilot
pid, cwd, title, model, effort
state     working | input | done | ready
waiting   "" | permission | question
since, started            epoch seconds
active                    seconds spent in turns
ctx, ctxmax, tin, tout    token counts
windowRef                 opaque handle for focusing (resolved lazily, cached)
```

**CardModel** (view model; pure function of `Session` + `now`): `title`, `proj`, `model`,
`effort`, `state`, `statetext`, `since` (human), `ctx`/`ctxmax` (human), `ctxpct`, `ctxlevel`
(`lo`/`mid`/`hi`), `tin`/`tout` (human), `age`, `active`, `actpct`. Keep all formatting here so the
views stay dumb and the logic is unit-testable.

**SessionStore** — publishes two separate observable values:
1. `idList` — ordered by `started`; only emits when the set/order of ids changes.
2. `cardModels` — emits when any card model changed (compare serialised value to skip no-ops).

Splitting these is essential: the strip re-lays out only on start/exit, so an open hover card is
never destroyed by a token or timer update.

**TerminalLocator** — resolves and focuses the hosting terminal window (GUIDE §5); results cached per pid.

**Hook helper** (Codex only) — a separate tiny executable registered in Codex's hooks config.
Reads one JSON event on stdin, writes a state file atomically (temp file + rename), exits 0
silently. The app should offer to install/uninstall these hook entries without clobbering
existing user hooks.

## 2.3 Threading & performance

- Collection runs on a background queue on a 1 s timer; publish to the UI on the main thread.
- Only read appended bytes; substring-filter lines before JSON decoding.
- Database access: read-only, short busy timeout, connection opened per tick (the agent owns the DB).
- Process inspection (alive, has controlling terminal, executable name, argv, cwd, start time,
  parent pid) via the platform's process APIs — avoid spawning shell commands per tick.
- Target: negligible CPU when idle; no growth in memory over long uptimes.

## 2.4 Error handling

- Each provider call is wrapped; a failure logs once and yields `[]` for that provider this tick.
- Malformed JSON lines are skipped; partial trailing lines are buffered, not parsed.
- Missing fields fall back to defaults documented in GUIDE §3/§4.

## 2.5 Testing

- Provider tests with fixture directories (sample session JSON, transcripts, event logs, SQLite DB)
  covering: state mapping, priority (input > working > done > ready), incremental reads across
  partial lines, file truncation, dedup of Claude message ids, Copilot 2-second turn-end rule,
  Codex thread-to-process matching and hook-vs-rollout precedence.
- Pure formatting tests for tokens, durations, model names, context levels.
- A `dump` command printing the current `cardModels` as JSON for manual verification.

## 2.6 Extending

Adding an agent = one new Provider + one icon set. Nothing in the store or views is agent-specific
beyond the `kind` → icon mapping.
