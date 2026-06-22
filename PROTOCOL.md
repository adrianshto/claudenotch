# Claude Notch — IPC contract

Three components. The extension owns a loopback HTTP server on `127.0.0.1:39247`
(`/event`, `/focus`, `/roster`); the app is driven by the `claudenotch://` URL scheme.

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
claudenotch://notify?name=frontend&event=needs_attention&message=…&sessionId=b1f2…
```

`name` = the tab name you set (falls back to cwd folder, then `"agent"`). `sessionId`
is echoed back on click to focus the tab.

## 3. App → Extension, focus  `POST http://127.0.0.1:39247/focus`

Sent when a ping or a dashboard row is clicked.

```jsonc
{ "sessionId": "b1f2…" }
```

Extension looks up the matched terminal and calls `terminal.show()` (reveal + focus).
The app separately raises Cursor to the front (`NSRunningApplication.activate`).

## 4. App → Extension, dashboard roster  `GET http://127.0.0.1:39247/roster`

The app fetches this when the dashboard is summoned (hover the notch).

```jsonc
[
  { "sessionId": "b1f2…", "name": "frontend",   "state": "running" },
  { "sessionId": "c3d4…", "name": "db-migrate", "state": "needsYou" }
]
```

## 5. Dev/demo trigger  `open "claudenotch://dashboard"`

Toggles the dashboard (fetches /roster first). For testing without hovering.

## Notes / known limits
- Port `39247` is fixed (loopback only); the extension owns it.
- **Multi-window**: only the Cursor window whose extension bound the port handles
  events / serves the roster. Cross-window aggregation is Phase 2b (app-as-hub).
- Everything is local; nothing leaves the machine.
