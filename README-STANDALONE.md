# Claude Notch — standalone (no Cursor)

A rebuild of [the original](./README.md) (which is hardwired to **Cursor**) for people who
run Claude Code in **Terminal.app**, **iTerm2**, or the **Claude desktop app**. Same two
surfaces on the MacBook notch:

- **Pings** — a notch drop-down when an agent **needs you** or **finishes a turn**,
  labelled with the chat's title.
- **Dashboard** — flick your cursor to the notch → a list of all your agents with live
  state. Click a row to jump to it.

## How it differs from the original

The original's **Cursor extension** was the hub *and* did tab-matching + window focusing
through Cursor's API. With no Cursor, that whole piece is replaced by a small **standalone
hub daemon** (`hub/hub.js`) that speaks the same HTTP protocol the app already expects.

```
Claude hook ──POST /event──▶  Hub daemon (127.0.0.1:39247)   [LaunchAgent, always-on]
(Terminal/iTerm/desktop)       roster + pings + focus
                              ◀── GET /pings   (notch app long-polls)
  ClaudeNotch.app ────────────◀── GET /roster  (dashboard on hover)
                              ──▶ POST /focus   (click → focus the chat)
```

- **Labels** come from the chat's `ai-title` (read from the transcript), not Cursor tab names.
- **Host detection**: the hook walks its process ancestry to tag each session with its app
  (Terminal / iTerm / Claude / …) and its controlling TTY.

## Click-to-focus — what works

| Environment | Click behavior |
|---|---|
| **Terminal.app** | Selects the **exact window + tab** (matched by TTY via AppleScript) ✅ |
| **iTerm2** | Same — exact tab ✅ |
| **Claude desktop app** | Opens the **exact chat** ✅ — see below |

**How the Claude desktop jump works (since 2026-11-16):** the hook looks up the chat's
desktop record (`claude-code-sessions/<org>/<proj>/local_*.json`, matched on
`cliSessionId`) and sends its `local_…` id to the hub. On click the hub opens
`claude://code/continue?session=<local_…>`, the app's own "continue this Code session"
entry point, which raises the window and navigates to that chat. (The older
`claude://code/<bridge session_…>` form is silently dropped by the app, so it isn't used.)
Rows recorded before this change pick up the id on their next event; until then a click
just raises the app.

## Install

Prereqs: Apple Silicon Mac, Homebrew, Node, and **full Xcode** (the app build needs the
SwiftUI macros DynamicNotchKit uses). Then:

```sh
./install-standalone.sh
```

Idempotent. It installs the hook + hub to `~/.claude-notch/`, wires 5 Claude Code hooks into
`~/.claude/settings.json` (non-clobbering), installs `terminal-notifier` (banner fallback),
builds + deploys `ClaudeNotch.app` to `/Applications`, and loads two LaunchAgents
(`com.claudenotch.hub`, `com.casper.claudenotch`) so the hub + app start at login.

### macOS notification settings (one-time)

System notifications are used as a fallback when the app/hub are down. If you run with a
**Focus / Do Not Disturb** mode, add **terminal-notifier** to that Focus's *Allowed
Notifications*, and make sure **terminal-notifier** is enabled under **System Settings →
Notifications** (it ships disabled).

## Components

| Piece | Source | Live location |
|---|---|---|
| Hook | `hook/notify-hook.js` | `~/.claude-notch/notify-hook.js` + `hooks` in `~/.claude/settings.json` |
| Hub | `hub/hub.js` | `~/.claude-notch/hub.js` (LaunchAgent `com.claudenotch.hub`) |
| App | `app/` (unchanged from original) | `/Applications/ClaudeNotch.app` (LaunchAgent `com.casper.claudenotch`) |

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.claudenotch.hub
launchctl bootout gui/$(id -u)/com.casper.claudenotch
rm ~/Library/LaunchAgents/com.claudenotch.hub.plist ~/Library/LaunchAgents/com.casper.claudenotch.plist
rm -rf /Applications/ClaudeNotch.app ~/.claude-notch
# then remove the "hooks" block from ~/.claude/settings.json
```

## Troubleshooting

- **No ping:** check the hub — `curl -s http://127.0.0.1:39247/roster`. Logs:
  `~/.claude-notch/hub.log` (hub), `~/.claude-notch/events.log` (hook).
- **Click doesn't focus a Terminal tab:** make sure `claude` runs **directly** in the tab
  (not via ssh/tmux/wrapper) so the hook captures that tab's TTY. First focus may trigger a
  one-time macOS **Automation** permission prompt (allow the hub to control Terminal).
- **Banner fallback invisible:** Focus mode and/or terminal-notifier disabled in System
  Settings → Notifications (see above).
