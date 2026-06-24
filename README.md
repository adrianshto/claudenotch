# Claude Notch

> **Agents:** read `CLAUDE.md` first — it's the canonical map (architecture, every
> file + system location, invariants, rebuild commands). This README is human setup.

Surfaces your Claude Code agents (running in **Cursor** terminals) on the MacBook
**notch**, two ways — both with the same DynamicNotchKit animation:

- **Pings** — a notch drop-down when an agent needs you or finishes a turn, labelled
  with the name **you** gave that terminal tab (right-click → Rename). Click → focus it.
- **Dashboard** — flick your cursor to the notch and a notch drops down listing **all**
  your agents with live state (running / done / needs-you). Click a row → focus that tab.

## When it pings

- 🔔 **Needs you** (`Notification` hook) and ✅ **finished a turn** (`Stop` hook) both ping.
- **Quiet the window I'm working in** (🔔 menu toggle, **on by default**): while you're
  focused on a Cursor window, *its* agents stay silent — done **and** needs-you, for every
  tab/pane in that window — because you're already looking at it. Agents in **other**
  windows still ping. Switch focus and it follows you. Turn the toggle **off** to ping for
  everything regardless of focus.
- Pings **never steal your keyboard focus** — they're delivered in the background, so a
  notch appearing (or being suppressed) won't knock you out of what you're typing.
- **Scope:** only agents tied to a **Cursor terminal tab** ping. Background or
  non-Cursor `claude` sessions match no tab and are ignored.

## The dashboard

Move your cursor up onto the **notch** → the dashboard drops down with all your
agents (status counts, then each agent by name + state). Click a row to focus that
tab; move your cursor away and it retracts. It's **summon-on-hover** (not always-on),
so the notch stays clean when you're not looking. It spans **all your Cursor windows**,
**grouped by project** (leader/follower under the hood). Clicking an agent in another
window **brings that window to the front — even on another desktop/Space or fullscreen**
— and reveals its terminal (via Cursor's own `--reuse-window`; you'll see a brief Cursor
icon flash in the dock as it does, which is harmless).

An agent that **just finished** (went done in the last ~2 min) shows up **purple** with a
"just done" label, so it's easy to spot the fresh finish among a stack of older (yellow)
`done` agents.

See `PROTOCOL.md` for the exact wire format. The shape:

```
Claude Code hook ─POST /event─▶ Cursor extension (leader, 39247)
 (in the terminal)               match tab → roster + queue ping, raise windows
                                 ◀── GET /pings  (app long-polls — pings, focus-safe)
   App (notch) ──────────────────◀── GET /roster (app pulls on hover)
                                 ──▶ POST /focus (click → raise window + reveal tab)
```

## What's already installed (done by setup)

- ✅ **Hook** — `~/.claude-notch/notify-hook.js`, wired into `~/.claude/settings.json`
  on 5 events (`Notification`, `Stop`, `SessionStart`, `UserPromptSubmit`,
  `SessionEnd`), async so it never delays an agent.
- ✅ **Extension** — installed in Cursor as `local.claude-notch` (v0.12.0).
- ✅ **Notch app** — installed at `/Applications/ClaudeNotch.app` and **auto-starts at
  login** (LaunchAgent `com.casper.claudenotch`). Built from `app/` (no Xcode project needed).

## 1. The notch app

Already built by `app/build-app.sh` into `app/ClaudeNotch.app` — a menu-bar-only
(`LSUIElement`) SwiftUI app using **DynamicNotchKit 1.1.0** (MIT). The source is a
plain Swift package (`app/Package.swift` + `app/Sources/ClaudeNotch/*.swift`),
verified to compile + link against the real library.

**It's already running and auto-starts at login** — a 🔔 in the menu bar, launched from
`/Applications/ClaudeNotch.app` by the LaunchAgent `com.casper.claudenotch`. Its menu has
**"Test notch ping"** to confirm the notch renders + taps work. No system permissions
needed — window focusing is delegated to Cursor's CLI via the extension.

**Rebuild after code edits:** `cd app && ./build-app.sh` (Xcode toolchain for the SwiftUI
macros DynamicNotchKit needs; signs with a stable identity if set up, else ad-hoc). Since
it's installed, this **auto-redeploys to /Applications** + re-registers the URL handler.
Then restart the running copy: `launchctl kickstart -k gui/$(id -u)/com.casper.claudenotch`.

**Fresh install on a new machine (or a clean clone): just run `./install.sh`** from the
repo root. It sets up everything — copies the hook + wires it into `~/.claude/settings.json`
(non-clobbering), builds + deploys the app to /Applications, loads the Login Item, and
packages + installs the Cursor extension — then **restart Cursor**. Idempotent; needs full
Xcode, Node, and Cursor. (The app shows under System Settings → General → Login Items →
"Allow in the Background".)

**Prefer Xcode?** Open `app/Package.swift` in Xcode and Run — package + Info.plist are set up.

## 2. Extension (installed)

`local.claude-notch`. After install, **Reload Cursor** (⌘⇧P → "Developer: Reload
Window") or restart so it activates. Debug: ⌘⇧P → **"Claude Notch: Show Status"** →
the "Claude Notch" output channel logs matches. Rebuild after edits:
`cd extension && npx @vscode/vsce package --allow-missing-repository --no-dependencies`
then re-run the install command.

## 3. Hook (installed)

`~/.claude-notch/notify-hook.js`, wired in `~/.claude/settings.json`. Manage via `/hooks`.

## Test

1. **Reload Cursor** (⌘⇧P → "Developer: Reload Window") so the extension + hooks are live.
2. **Pings:** rename a terminal tab (right-click → Rename → e.g. `frontend`), run
   `claude` in it; trigger a permission prompt, or switch away and let it finish a turn.
   The notch drops down labelled `frontend`; click it → that window comes to the front
   (even from another desktop) on that tab.
3. **Dashboard:** with at least one `claude` session running, **hover the notch** → it
   drops down listing your agents + live state. Click a row → focuses that tab.
   (`curl -s http://127.0.0.1:39247/roster` shows the raw roster.)

## Troubleshooting

- **Nothing happens:** "Claude Notch: Show Status" should log `listening
  127.0.0.1:39247`. Check `/hooks` lists the 5 hooks (Notification, Stop, SessionStart,
  UserPromptSubmit, SessionEnd).
- **Dashboard empty / agent missing:** the roster fills from lifecycle events, so a
  session shows after its first event — send it a prompt. `curl http://127.0.0.1:39247/roster`
  to inspect. Multi-window works (leader/follower); if a window's agents are missing, that
  window's extension may be a stale version — reload it (see below).
- **No ping at all for a Cursor agent:** the extension "Show Status" channel logs `ping
  "…"` when it queues one; if it says `no tab matched`, make sure `claude` runs *directly*
  in that Cursor terminal (not via a wrapper / ssh / tmux). The app log (`~/.claude-notch/
  app.log`) shows `ping suppressed — focus-mute on…` when it's hidden by the toggle.
- **Ping didn't show:** expected if you were **focused on that agent's window** and the
  "Quiet the window I'm working in" toggle is on. Switch to another window/app, or turn the
  toggle off (🔔 menu), and it pings.
- **No notch even from another window:** the app isn't running. It auto-starts at login;
  if needed, launch `/Applications/ClaudeNotch.app` and use 🔔 → "Test Notch Ping".
- **Click doesn't focus / wrong window:** focusing runs `cursor --reuse-window <folder>`
  via the extension. Make sure **every** Cursor window runs the same extension version
  (⌘⇧P → "Developer: Reload Window" on any stale one) — the leader needs each window's
  folder to raise it. A brief second Cursor icon flashing in the dock on focus is normal.
- **Multiple Cursor windows:** fully supported (leader/follower). Clicking an agent
  raises its window across desktops/Spaces.

## Uninstall

- Extension: `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --uninstall-extension local.claude-notch`
- Hook: remove the `"hooks"` block from `~/.claude/settings.json` (or use `/hooks`).
- App + auto-start:
  ```
  launchctl bootout gui/$(id -u)/com.casper.claudenotch
  rm ~/Library/LaunchAgents/com.casper.claudenotch.plist
  rm -rf /Applications/ClaudeNotch.app
  ```
- `rm -rf ~/.claude-notch`
