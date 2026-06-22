# Claude Notch — IPC contract

Three components, one job: when a Claude Code agent running in a Cursor terminal
needs attention, show a ping **in the notch** labelled with the name **you** gave
that terminal tab, and focus that tab when you click it.

```
Claude Code hook  ──POST /event──▶  Cursor extension  ──open claudenotch://──▶  Notch app
   (in terminal)                    (matches tab,                              (draws notch)
                                     reads its name)                                │
                                          ▲                                         │
                                          └──────────── POST /focus ◀───────────────┘
                                                        (on click)
```

## 1. Hook → Extension  `POST http://127.0.0.1:39247/event`

The hook fires inside the terminal, so it can hand us its process-ancestor PID
chain. One of those PIDs is the terminal's shell PID, which equals the Cursor
`Terminal.processId` — that's how the extension knows *which* tab fired.

```jsonc
{
  "event": "needs_attention" | "done",  // Notification hook vs Stop hook
  "hookEvent": "Notification",            // raw Claude Code hook_event_name
  "pidChain": [54321, 54300, 54210, 1],   // this process up to PID 1
  "cwd": "/Users/casper/Desktop/app",
  "sessionId": "b1f2…",                   // Claude Code session_id
  "message": "Claude needs permission to run npm install"
}
```

## 2. Extension → Notch app  `open "claudenotch://notify?…"`

No HTTP server in Swift — macOS routes the URL to the running app.

```
claudenotch://notify
  ?name=frontend                 // the tab name you set (URL-encoded)
  &event=needs_attention
  &message=Claude%20needs%20permission…
  &sessionId=b1f2…               // echoed back on click, to focus the tab
```

If `name` can't be resolved (no tab matched), the extension falls back to the
working-directory folder name, then `"agent"`.

## 3. Notch app → Extension  `POST http://127.0.0.1:39247/focus`  (on click)

```jsonc
{ "sessionId": "b1f2…" }
```

The extension looks up the terminal it matched for that session and calls
`terminal.show()` to reveal + focus the tab.

## Notes / known limits
- Port `39247` is fixed (loopback only). The extension owns it.
- Multi-window Cursor: only the window whose extension bound the port handles
  events; cross-window matching is out of scope for v1.
- Everything is local; nothing leaves the machine.
