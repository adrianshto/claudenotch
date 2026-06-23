# Claude Notch — IPC contract

Three components. The **leader** window's extension owns a loopback HTTP server on
`127.0.0.1:39247` (`/event`, `/pings`, `/roster`, `/focus`, `/register`, `/deregister`).
The app **pulls** from it (long-poll pings + roster) and POSTs focus — it is never
launched via a URL (that stole focus). Multi-window via leader/follower — see §6.

```
Claude Code hook ──POST /event──▶ Cursor extension (leader, 127.0.0.1:39247)
 (in the terminal)                 match tab → roster + queue ping, raise windows
                                   ◀── GET /pings   (app long-polls — focus-safe delivery)
   App (notch) ───────────────────◀── GET /roster  (app pulls on hover → dashboard)
                                   ──▶ POST /focus  (app pushes on click → raise + reveal)
```

## 1. Hook → Extension  `POST http://127.0.0.1:39247/event`

The hook fires inside the terminal, so it hands us its process-ancestor PID chain;
one of those PIDs is the shell PID == the Cursor `Terminal.processId`, which is how
the extension knows *which* tab fired. Wired to FIVE Claude Code hook events.

```jsonc
{
  "event": "needs_attention" | "done",   // derived: Notification → needs_attention, else done
  "hookEvent": "Notification",            // raw hook_event_name — the source of truth for state
  "pidChain": [54321, 54300, 54210, 1],   // this process up to PID 1
  "cwd": "/Users/casper/Desktop/app",
  "sessionId": "b1f2…",                   // Claude Code session_id
  "message": "Claude needs permission to run npm install"
}
```

`hookEvent` → roster state:

| hookEvent          | state      | queues a ping?                              |
|--------------------|------------|---------------------------------------------|
| `UserPromptSubmit` | `running`  | no                                          |
| `Stop`             | `done`     | yes                                         |
| `Notification`     | `needsYou` | yes (unless already `done` → idle nudge, skipped) |
| `SessionStart`     | `idle`     | no                                          |
| `SessionEnd`       | (removed)  | no                                          |

A queued ping carries `focused` (was the agent's window focused when it fired). The app
decides whether to actually show it — see §2 (the "quiet the focused window" toggle).

## 2. Extension → App, pings  `GET http://127.0.0.1:39247/pings` (long-poll)

The app **pulls** pings; it is never launched via a URL (an `open claudenotch://` would
foreground the app and steal key focus from whatever you're typing). The app loops on
this GET; the leader returns queued pings at once, else holds the request up to ~25s and
responds the instant a ping fires (so delivery feels instant, with no busy polling).

Response: an array (often empty on the 25s timeout) of pings:

```jsonc
[
  { "name": "frontend", "event": "needs_attention", "message": "…",
    "sessionId": "b1f2…", "window": "code-project", "focused": false, "ts": 1782189000000 }
]
```

- `focused` — was that agent's Cursor window focused when it fired. If the **"Quiet the
  window I'm working in"** toggle is ON (default) and `focused` is true, the app **drops**
  the ping (you're working in that window). OFF → always shown.
- `ts` — epoch-ms; the app ignores pings staler than 30s (e.g. queued while it was down).
- `name` = the tab name (falls back to cwd folder, then `"agent"`). On click → POST
  `/focus {sessionId}` (§3), which raises the window (by roster `folder`) + reveals the tab.

## 3. App → Extension, focus  `POST http://127.0.0.1:39247/focus`

Sent when a ping or a dashboard row is clicked.

```jsonc
{ "sessionId": "b1f2…" }
```

The leader looks up the session's roster entry and:
1. **Raises the owning window** — runs `cursor --reuse-window <entry.folder>` (the bundled
   Cursor CLI). Cursor activates that window itself, crossing Spaces/fullscreen/minimized.
2. **Reveals the terminal** — `terminal.show()` locally, or routes it to the owning
   follower (§6).

The app itself does nothing to windows (no `NSRunningApplication.activate`, no
permissions). A brief throwaway Cursor forwarder process appears per focus (Cursor's
single-instance model) — harmless.

## 4. App → Extension, dashboard roster  `GET http://127.0.0.1:39247/roster`

The app fetches this when the dashboard is summoned (hover the notch). It's the
GLOBAL roster across all windows (see §6).

```jsonc
[
  { "sessionId": "b1f2…", "name": "frontend",   "state": "running",  "windowId": "64095-ixxrla", "window": "code-project",    "folder": "/Users/casper/code-project",    "pid": 33263 },
  { "sessionId": "c3d4…", "name": "db-migrate", "state": "done",     "windowId": "64491-rlwv9d", "window": "writing-project", "folder": "/Users/casper/writing-project", "pid": 64731, "doneAt": 1782189000000 }
]
```

`windowId` = internal per-window id (focus routing); `window` = human label (the
window's project/folder name) the dashboard groups by; `folder` = the workspace's
filesystem path, passed to `cursor --reuse-window` to raise that exact window (§3);
`doneAt` = epoch-ms when the agent entered `done` (present only for `done` entries) — the
dashboard renders a finish within the last 2 min in purple to set it apart from old ones.

## 5. Dev/demo trigger  `open "claudenotch://dashboard"`

Toggles the dashboard (fetches /roster first). For testing without hovering.

## 6. Multi-window: leader/follower (extension ↔ extension)

The first window to bind `39247` is the **leader/hub**; others are **followers**.

- **Follower → Leader** `POST /register` (heartbeat ~1.5s) and `POST /deregister`:
  ```jsonc
  { "windowId": "64491-rlwv9d", "callbackPort": 51328, "label": "writing-project",
    "folder": "/Users/casper/writing-project",
    "terminals": [ { "pid": 64731, "name": "claudius" } ],
    "focused": false, "activeTerminalPid": 64731 }
  ```
  (`folder` lets the leader raise this window via `cursor --reuse-window`.)
  The leader resolves a hook's PID chain against its OWN terminals AND every
  follower's registered `terminals`, so the global roster + pings span all windows.
- **Leader → Follower** `POST http://127.0.0.1:<callbackPort>/focus` `{ "pid": 64731 }`:
  the follower finds its terminal with that `processId` and calls `terminal.show()`.
- **Election**: a follower retries binding `39247` every ~3s; if the leader dies it
  promotes. The leader prunes followers not seen for >5s.

## Notes / known limits
- Port `39247` is fixed (loopback only); the current leader owns it.
- Cross-window focus raises the specific window across Spaces via `cursor
  --reuse-window <folder>` (§3). Each focus flashes a throwaway Cursor forwarder process
  (Cursor's single-instance model) — cosmetic. The private-WindowServer alternative
  (no flash) no-ops on macOS 26 Tahoe.
- Everything is local; nothing leaves the machine.
