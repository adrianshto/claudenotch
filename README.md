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

- 🔔 **Needs you** (`Notification` hook — permission / opinion / idle): **always** pings.
  The agent is blocked on you; you shouldn't miss it.
- ✅ **Finished a turn** (`Stop` hook): pings **only when you're not already looking at
  that tab** — i.e. another app is focused, or a different Cursor tab is active. If
  Cursor is focused *and* that agent's terminal is the active one, it stays quiet.
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

See `PROTOCOL.md` for the exact wire format. The shape:

```
Claude Code hook ─POST /event─▶ Cursor extension ─open claudenotch://notify─▶ App (pings)
 (in the terminal)              (39247: match tab,   ◀──POST /focus──  (click → reveal tab)
                                 name, live roster)   App (dashboard) ──GET /roster──▶ 39247
```

## What's already installed (done by setup)

- ✅ **Hook** — `~/.claude-notch/notify-hook.js`, wired into `~/.claude/settings.json`
  on 5 events (`Notification`, `Stop`, `SessionStart`, `UserPromptSubmit`,
  `SessionEnd`), async so it never delays an agent.
- ✅ **Extension** — installed in Cursor as `local.claude-notch` (v0.9.0).
- ✅ **Notch app** — built at `app/ClaudeNotch.app` (no Xcode project needed).

## 1. The notch app

Already built by `app/build-app.sh` into `app/ClaudeNotch.app` — a menu-bar-only
(`LSUIElement`) SwiftUI app using **DynamicNotchKit 1.1.0** (MIT). The source is a
plain Swift package (`app/Package.swift` + `app/Sources/ClaudeNotch/*.swift`),
verified to compile + link against the real library.

**Run it:** `open ~/Desktop/ClaudeNotch/app/ClaudeNotch.app` → a 🔔 appears in the
menu bar. Its menu has **"Test notch ping"** to confirm the notch renders + taps work.

**Rebuild after code edits:** `cd app && ./build-app.sh` (uses the Xcode toolchain
for the SwiftUI macros DynamicNotchKit needs; signs with a stable self-signed identity
if set up, else ad-hoc; registers the URL scheme). The app needs **no system
permissions** — window focusing is delegated to Cursor's CLI via the extension.

**Daily use:** move `ClaudeNotch.app` to `/Applications` and add it to **Login Items**
(System Settings → General → Login Items) so it's always running and registered.

**Prefer Xcode?** (e.g. for Phase 2 work) Open `app/Package.swift` in Xcode and Run —
the package and Info.plist are already set up; no "new project + drag files" dance.

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
- **No ping at all for a Cursor agent:** "Show Status" output channel logs the
  decision per event — `ping name=…`, `suppressed — already viewing …`, or
  `no tab matched — ignored`. If it says *no tab matched*, make sure `claude` runs
  *directly* in that Cursor terminal (not via a wrapper / ssh / tmux).
- **End-of-turn ping didn't fire:** expected if that tab was active and Cursor was
  focused (the focus rule). Switch to another tab/app and it pings.
- **Toast instead of notch:** the app isn't running/registered. Launch
  `ClaudeNotch.app`; test via its menu. Re-run from Xcode to re-register the scheme.
- **Click doesn't focus / wrong window:** focusing runs `cursor --reuse-window <folder>`
  via the extension. Make sure **every** Cursor window runs the same extension version
  (⌘⇧P → "Developer: Reload Window" on any stale one) — the leader needs each window's
  folder to raise it. A brief second Cursor icon flashing in the dock on focus is normal.
- **Multiple Cursor windows:** fully supported (leader/follower). Clicking an agent
  raises its window across desktops/Spaces.

## Uninstall

- Extension: `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --uninstall-extension local.claude-notch`
- Hook: remove the `"hooks"` block from `~/.claude/settings.json` (or use `/hooks`).
- App: quit it, move `ClaudeNotch.app` to Trash.
- `rm -rf ~/.claude-notch`
