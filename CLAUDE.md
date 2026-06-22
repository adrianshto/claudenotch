# Claude Notch — agent context

Auto-loaded context for any agent working on this project. Read this first.

## What this is

A local macOS system that shows a **notch notification** when a Claude Code agent
running in a **Cursor integrated terminal** needs attention or finishes a turn. The
ping is labelled with the **name the user gave that terminal tab** (right-click →
Rename) and **clicking it focuses that exact tab**. Built in-house (no third-party
notch app) for a work machine — local-only, no telemetry, no data leaves the machine.

## Architecture (3 pieces + full wire format in `PROTOCOL.md`)

```
Claude Code hook ──POST /event──▶ Cursor extension ──open claudenotch://──▶ Notch app
 (in the terminal)                (match tab, read its                       (draw notch)
                                   name, apply rules) ▲                            │
                                              └────────── POST /focus ◀────────────┘
                                                           (on click)
```

1. **Hook** (Node) — fires on Claude Code `Notification` (needs you) + `Stop`
   (finished). Computes its process-ancestor PID chain, POSTs the event to the
   extension. Fails silently (exit 0) so it can never block or delay an agent.
2. **Extension** (Cursor/VS Code, plain JS) — the brain. Matches the PID chain to a
   terminal's `processId`, reads `terminal.name`, applies scope + focus rules, fires
   the app via the `claudenotch://` URL, and on click calls `terminal.show()`.
3. **Notch app** (Swift/SwiftUI, menu-bar-only) — registers `claudenotch://`, draws
   the notch via **DynamicNotchKit 1.1.0**, plays a sound, and POSTs `/focus` on tap.

## Behavior rules (intentional — don't "fix" these)

- **Needs you** (`Notification`): **always** pings (agent is blocked on the user).
- **Finished** (`Stop`): pings **only if the user isn't already looking at that tab** —
  suppressed when `window.state.focused && activeTerminal === thatTerminal`. This is
  what stops every-turn ping spam while actively working in a tab.
- **Scope:** only agents matched to a Cursor terminal tab ping. Unmatched (background
  jobs, plain-terminal `claude`, the main assistant's own session) are ignored.

## Files & locations — IN-FOLDER SOURCE vs LIVE SYSTEM COPIES

This folder is the **source of truth**. Editing source does **NOT** change live
behavior until you rebuild/reinstall (commands below). The live system uses copies
installed outside this folder:

| Piece | Source (this folder) | Live copy the OS/Cursor/Claude uses |
|---|---|---|
| Hook | `hook/notify-hook.js` | `~/.claude-notch/notify-hook.js` + a `hooks` block in `~/.claude/settings.json` |
| Extension | `extension/` (`extension.js`, `package.json`) | `~/.cursor/extensions/local.claude-notch-<ver>` |
| App | `app/Sources/ClaudeNotch/*.swift`, `app/Package.swift`, `app/Info.plist` | **runs from `app/ClaudeNotch.app`** (until moved to `/Applications`) |

⚠️ **The app currently runs from this folder.** If this folder is moved/renamed/deleted,
`claudenotch://` points at a dead path. To decouple: copy `app/ClaudeNotch.app` to
`/Applications` and add to Login Items.

## Invariants (other pieces depend on these — change in lockstep)

- **Loopback port `39247`** — extension's HTTP server. Hardcoded in `hook/notify-hook.js`
  (`EXT_PORT`) and `extension/extension.js` (`PORT`). Change → change both.
- **URL scheme `claudenotch://`** — in `extension.js` (`fireNotch`), `app/Info.plist`
  (`CFBundleURLTypes`), and `app/Sources/ClaudeNotch/AppDelegate.swift`.
- **Hook command** in `~/.claude/settings.json`:
  `/opt/homebrew/bin/node /Users/casper/.claude-notch/notify-hook.js` (absolute node
  path because hooks don't inherit the interactive shell PATH).
- **Bundle id** `com.casper.claudenotch`; **extension id** `local.claude-notch`.
- **Toolchain:** building the app needs **full Xcode** (`DEVELOPER_DIR=/Applications/
  Xcode.app/Contents/Developer`), not the standalone Command Line Tools — DynamicNotchKit
  uses SwiftUI macros (`@Entry`, `#Preview`) whose plugins ship only with Xcode.

## Rebuild / reinstall after editing source

- **Hook:** `cp hook/notify-hook.js ~/.claude-notch/notify-hook.js`
- **Extension:** `cd extension && npx @vscode/vsce package --allow-missing-repository --no-dependencies`
  then `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --install-extension claude-notch-<ver>.vsix --force`,
  then Reload Cursor (⌘⇧P → Developer: Reload Window).
- **App:** `cd app && ./build-app.sh` (build-app.sh sets DEVELOPER_DIR, builds release,
  bundles, ad-hoc signs, registers the URL scheme).

## Test / debug

- Extension decisions log to Cursor's **"Claude Notch"** output channel
  (⌘⇧P → "Claude Notch: Show Status"): `ping name=…` / `suppressed — already viewing …`
  / `no tab matched — ignored`.
- App: menu-bar 🔔 → "Test notch ping". Or fire a real one:
  `open "claudenotch://notify?name=demo&event=needs_attention&message=hi&sessionId=x"`
- Hook in isolation: `echo '{"hook_event_name":"Stop"}' | /opt/homebrew/bin/node ~/.claude-notch/notify-hook.js` (exit 0, silent when nothing is listening).

## Known limitations (v1)

- One Cursor window owns port 39247; other windows' agents won't be matched.
- Agent↔tab match needs `claude` running **directly** in the Cursor terminal (not via
  ssh/tmux/wrapper) so the shell PID matches `Terminal.processId`.
- `terminal.name` rename-tracking is real but **undocumented** in the VS Code API
  (verified against source); pin Cursor version expectations accordingly.

## Status

- ✅ Phase 1 complete: hook + extension (scope/focus rules, unit-tested) + notch app
  (compiles/links against real DynamicNotchKit, signed, URL scheme registered).
- ⬜ Phase 2 (planned): persistent minimalist notch **dashboard** — all active agents at
  a glance with live state (running / done / needs-you), hover for name, click to focus,
  visible from any app. Needs the extension to track per-session lifecycle
  (`SessionStart`/`UserPromptSubmit`/`Stop`/`Notification`/`SessionEnd`) and push a
  roster to the app, which renders a persistent compact notch view.

See `README.md` for human-oriented setup/run/uninstall steps.
```
