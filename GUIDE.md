# Agent Monitor — Functional Guide

Agent Monitor is a small always-visible status strip that shows every **interactive coding-agent
session** running on the machine, what state each one is in, and lets you jump straight to the
terminal it lives in. It answers one question at a glance: *"which of my agents needs me right now?"*

Supported agents:

| Agent              | Identifier | Notes                       |
|--------------------|------------|-----------------------------|
| Claude Code        | `claude`   | interactive sessions only   |
| OpenAI Codex       | `codex`    | the interactive TUI only    |
| GitHub Copilot CLI | `copilot`  | interactive sessions only   |

Non-interactive runs (one-shot prompt mode, servers, headless/exec modes, sub-agents) are never shown.

---

## 1. What the user sees

### 1.1 The strip

- One **square icon pill per live session**, ordered by session start time (oldest first, left to right).
- The icon is the agent's own logo, **tinted by state** (see §2).
- The strip is **hidden entirely when no sessions are running** — it must not leave an empty gap.
- Icons appear when a session starts and disappear when it exits. Nothing else reorders them.

### 1.2 The hover card

Hovering an icon shows a detail card **instantly** (no tooltip delay), positioned directly under
the icon and horizontally centred on it (clamped so it never goes off the screen edge).
Moving off the icon hides it. Only one card is visible at a time.

Card contents, top to bottom:

1. **Title** — the session's name (centred, single line, ellipsized).
2. **Where / what row** — folder icon + project name (left, ellipsized) ……… model icon + model name
   `·` reasoning effort (right; the `· effort` part is hidden when unknown).
3. **State chip** — coloured dot + state text (e.g. `needs you · permission`) on the left,
   `for 3m` (time in the current state) on the right.
4. **Context** — caption `context`, value `84k / 200k · 42%`, and a progress bar
   (colour changes with fullness: <50 % accent blue, 50–79 % yellow, ≥80 % red).
5. **Token tiles** — two equal tiles side by side:
   - `↑ <n>` **tokens written** (output tokens, whole session)
   - `↓ <n>` **tokens read** (input tokens incl. cache, whole session)
6. **Hint** — `click to go to this window`.

The card updates live while open (timers tick, tokens grow) **without flickering or closing**.

### 1.3 Click

Clicking an icon hides the card and **brings the terminal window running that session to the front**
(ideally the exact tab/pane, if the terminal supports it).

---

## 2. Session states

| State     | Label shown  | Colour  | Meaning |
|-----------|--------------|---------|---------|
| `working` | `working`    | yellow  | The agent is mid-turn: thinking, calling tools, writing. |
| `input`   | `needs you`  | red     | The agent is blocked on the user: a permission/approval prompt, a question it asked, or a dialog. Optionally suffixed with what it waits for: `· permission`, `· question`. |
| `done`    | `finished`   | green   | The last turn completed; the agent is idle and has run at least one turn. |
| `ready`   | `ready`      | grey    | Session is open but no turn has been run yet. |

Priority when signals conflict: **input > working > done > ready**. A pending approval always wins.

`since` is the moment the session entered its current state; the card shows the time elapsed since then.

---

## 3. Data shown per session

| Field      | Description | Format |
|------------|-------------|--------|
| `title`    | Session name → AI-generated title → first line of the first prompt (≤60 chars) → `new session` | text |
| `proj`     | Basename of the session's working directory; `~` for the home directory | text |
| `model`    | Prettified model name: `claude-opus-4-6-…` → `opus 4.6`; others shown as-is | text |
| `effort`   | Reasoning effort (`low`/`medium`/`high`/…); falls back to the agent's configured default | text |
| `state`, `statetext`, `since` | See §2 | — |
| `ctx` / `ctxmax` / `ctxpct` | Current context-window usage (last request's input + output) vs. the model's window | `84k / 200k · 42%` |
| `tout`     | Total output tokens over the session | human tokens |
| `tin`      | Total input tokens (incl. cache read + cache creation) over the session | human tokens |
| `started`  | Process start time (used for ordering) | — |
| `active`   | Cumulative time spent in turns (+ the running turn) | duration |

Formatting rules:

- **Tokens**: `<1000` as-is; `1.2k` below 10k, `84k` above; `1.5M` below 100M, `120M` above. Drop a trailing `.0`.
- **Durations**: `42s`, `17m`, `2h 05m`.
- **Context window fallback** when unknown: Claude 200k (1M for models/flags that support it, or
  whenever usage already exceeds 200k); Codex 272k; Copilot 200k.

---

## 4. How sessions are discovered and read

General principles:

- **Poll once per second.** All reads are cheap and incremental.
- **Transcripts / event logs are append-only JSONL**: remember the byte offset and only parse new
  complete lines; keep a trailing partial line buffered. If the file shrinks, reset and re-read.
- **Pre-filter lines by substring** before JSON-parsing — logs can be large.
- A session is only shown if its **process is alive, attached to a terminal, and is the expected
  executable**. Stale state files left by crashed processes must be ignored.
- **Each agent is read in isolation**: an error reading one agent must never break the others or the app.
- Paths below are relative to the user's home directory.

### 4.1 Claude Code

- **Discovery**: `~/.claude/sessions/<pid>.json`, one per running session. Fields: `pid`,
  `sessionId`, `cwd`, `kind` (only `interactive`), `status`, `statusUpdatedAt`, `startedAt` (ms),
  `waitingFor`.
- **State**: `status` `waiting` → `input`; `busy`/`shell` → `working`; otherwise `done` if any
  turn has run, else `ready`. `since` = `statusUpdatedAt`.
- **Transcript**: `~/.claude/projects/<cwd with every non-alphanumeric char replaced by '-'>/<sessionId>.jsonl`
  (fallback: search `~/.claude/projects/*/<sessionId>.jsonl`). From it:
  - `type: assistant` (non-sidechain) with `message.usage` → per-message-id tokens
    (input = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, output = `output_tokens`),
    deduplicated by message id; the latest one is the current context; `message.model` = model.
  - `type: api-request` → `params.output_config.effort`.
  - `type: ai-title` / `custom-title` → title. `type: last-prompt` → prompt fallback.
  - `type: system, subtype: turn_duration` → add `durationMs` to active time; count turns.
- **Effort default**: `~/.claude/settings.json` → `modelSettings[model].effortLevel`, else `effortLevel`.

### 4.2 Codex

- **Discovery**: find running `codex` processes attached to a terminal, excluding sub-commands
  (`app-server`, `exec`, `mcp-server`, `login`, `proto`) and processes whose parent is also
  `codex` (the launcher re-execs itself).
- **Thread matching**: query `~/.codex/state_5.sqlite` (read-only) table `threads` for rows with the
  same `cwd`, updated after process start − 5 s, not archived, empty `agent_role`, and from the TUI
  (`source = 'cli'`, or `originator = 'codex-tui'`: since 0.162 the TUI runs through the shared
  app-server daemon and records `source = 'vscode'`, the same source Codex Desktop uses); newest first.
  Assign processes in start order, each taking the first unclaimed thread.
- **Title**: `~/.codex/session_index.jsonl` `thread_name` → thread `title` → first user message.
- **Rollout** (`rollout_path` from the thread row), `event_msg` payloads:
  - `task_started` → `working` (also `model_context_window`); `task_complete` / `turn_aborted` →
    `done`, accumulate active time.
  - `token_count` → `info.total_token_usage` (session totals), `info.last_token_usage.total_tokens`
    (current context), `info.model_context_window`.
  - Any line matching `"effort":"…"` / `"reasoning_effort":"…"` → effort.
- **Approval prompts** are not in the rollout. Two sources, either is enough:
  1. **Lifecycle hooks** (`~/.codex/hooks.json`): register a tiny hook command for every event that
     writes `{state, event, ts}` to `<per-user runtime dir>/agents/codex/<session_id>.json` (atomic
     write, never blocks, prints nothing, always exits 0, deletes the file on `SessionEnd`). The registered
     command is `test -x <helper> && <helper> || true`, so it is a no-op if the app is moved or deleted
     (Codex runs hooks through a shell; a missing path would exit 127). Mapping:
     `SessionStart`→ready, `UserPromptSubmit`/`PostToolUse`/`SubagentStart`→working,
     `PreToolUse`→input if the tool is a question tool (`request_user_input`, `ask_user`,
     `AskUserQuestion`) else working, `PermissionRequest`→input, `Stop`/`Interrupt`→done.
     A hook record is used only if it is not older than the rollout's latest state (1 s tolerance).
  2. **Terminal title**: Codex sets its window/tab title to e.g. `Action Required | <thread> | <dir>`
     while waiting; matching `/action required|approval|needs? (your )?(input|approval)/i` forces `input`.
- **Defaults**: `~/.codex/config.toml` top-level `model`, `model_reasoning_effort`.

### 4.3 Copilot CLI

- **Discovery**: lock files `~/.copilot/session-state/<id>/inuse.<pid>.lock`. If one pid holds
  several, use the session whose `events.jsonl` is newest. Require the process to be `copilot`,
  attached to a terminal, and not started with `-p`/`--prompt`/`--acp`.
- **Title**: `workspace.yaml` `name:` → `summary:` → first prompt line.
- **Events** (`events.jsonl`, each line `{"type": …, "data": …, "timestamp": ISO-8601}`):
  - `user.message` / `assistant.turn_start` → begin a "busy" interaction; `turn_start` also starts a turn timer.
  - `assistant.turn_end` → stop the turn timer, record end time.
  - `abort` / `session.shutdown` → not busy, clear pending prompts.
  - `permission.requested` / `permission.completed` (matched by `requestId`) → pending permission.
  - `tool.execution_start` for `ask_user` / `exit_plan_mode` and the matching
    `tool.execution_complete` (by `toolCallId`) → pending question.
  - `session.usage_record` → add `usage.inputTokens` / `outputTokens` to totals; for top-level
    records (`initiator` user/agent, no `parentToolCallId`) also set current context,
    `maxPromptTokens` and `model`.
  - `session.model_change` → `newModel`, `reasoningEffort`.
    `session.compaction_complete` → context = `postCompactionTokens`.
- **State**: any pending permission/question → `input` (since = oldest pending; waiting-for =
  `permission` if any permission is pending, else `question`). Busy → `working`, **but** if the last
  `turn_end` came after the interaction began, no new turn has started, and more than 2 s have
  passed, the interaction is over → `done`. Otherwise `done` if ever prompted, else `ready`.
- **Defaults**: `~/.copilot/settings.json` (may contain `//` comment lines) `model`, `effortLevel`.

---

## 5. Locating the terminal (click-to-focus)

For each session, resolve the window that hosts it:

1. Terminal-provided environment variables in the agent process (window / tab / session id).
2. Otherwise walk up the process tree (max ~12 levels) to the first ancestor that owns a window
   (the terminal app), and focus that window.
3. Cache the result per pid. If nothing is found, clicking does nothing (no error).

---

## 6. Robustness requirements

- Never crash or freeze because of a missing, partial, corrupted, or locked file / database.
- Open the Codex database read-only with a short timeout.
- Drop per-session caches when the session disappears.
- Updating details (timers, tokens) must not rebuild the icon list — rebuilding would close an open
  hover card. Only rebuild the list when the **set of session ids** changes.
- Provide a **debug "dump" mode** that prints one JSON snapshot of all sessions and exits.

## 7. Out of scope

- Controlling agents (approving, sending prompts, killing). Monitoring + focusing only.
- Historical sessions / analytics.
