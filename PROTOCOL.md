# Claude Notch — IPC contract

Three components. The **leader** window's extension owns a loopback HTTP server on
`127.0.0.1:39247` (`/event`, `/focus`, `/roster`, `/register`, `/deregister`); the app
is driven by the `claudenotch://` URL scheme. Multi-window via leader/follower — see §6.

```
Claude Code hook ──POST /event──▶ Cursor extension ──open claudenotch://notify──▶ App (pings)
 (in the terminal)                (39247: match tab,     ◀──POST /focus──  (click → reveal tab)
                                   read name, keep         App (dashboard) ──GET /roster──▶ 39247
                                   the live roster)        (hover → fetch → show → row → /focus)
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

| hookEvent          | state      | pings?                        |
|--------------------|------------|-------------------------------|
| `UserPromptSubmit` | `running`  | no                            |
| `Stop`             | `done`     | yes (unless viewing that tab) |
| `Notification`     | `needsYou` | yes (always)                  |
| `SessionStart`     | `idle`     | no                            |
| `SessionEnd`       | (removed)  | no                            |

## 2. Extension → App, pings  `open "claudenotch://notify?…"`

macOS routes the URL to the running app (launches it if needed).

```
claudenotch://notify?name=frontend&event=needs_attention&message=…&sessionId=b1f2…&window=code-project
```

`name` = the tab name you set (falls back to cwd folder, then `"agent"`). `sessionId`
is echoed back on click → POST `/focus`, where the leader raises the window (by its
roster `folder`) and reveals the tab. `window` is the human label (logging/context only;
the raise uses `folder` from the roster, not the URL).

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
