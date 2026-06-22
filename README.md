# Claude Notch

> **Agents:** read `CLAUDE.md` first — it's the canonical map (architecture, every
> file + system location, invariants, rebuild commands). This README is human setup.

Notch notifications for Claude Code agents running in **Cursor** terminals. When an
agent needs your attention (or finishes a turn), you get a ping **in the MacBook
notch**, labelled with the name **you** gave that terminal tab (right-click → Rename).
Click the ping to jump straight to that tab.

## When it pings

- 🔔 **Needs you** (`Notification` hook — permission / opinion / idle): **always** pings.
  The agent is blocked on you; you shouldn't miss it.
- ✅ **Finished a turn** (`Stop` hook): pings **only when you're not already looking at
  that tab** — i.e. another app is focused, or a different Cursor tab is active. If
  Cursor is focused *and* that agent's terminal is the active one, it stays quiet.
- **Scope:** only agents tied to a **Cursor terminal tab** ping. Background or
  non-Cursor `claude` sessions match no tab and are ignored.

See `PROTOCOL.md` for the wire format between the three pieces:

```
Claude Code hook ──POST /event──▶ Cursor extension ──open claudenotch://──▶ Notch app
 (in the terminal)                (matches tab, reads                       (draws notch)
                                    its name)  ▲                                  │
                                               └────────── POST /focus ◀──────────┘
                                                            (on click)
```

## What's already installed (done by setup)

- ✅ **Hook** — `~/.claude-notch/notify-hook.js`, wired into `~/.claude/settings.json`
  (`Notification` + `Stop`, async so it never delays an agent). Tested.
- ✅ **Extension** — installed in Cursor as `local.claude-notch` (v0.2.0).
- ✅ **Notch app** — built at `app/ClaudeNotch.app` (no Xcode project needed).

## 1. The notch app

Already built by `app/build-app.sh` into `app/ClaudeNotch.app` — a menu-bar-only
(`LSUIElement`) SwiftUI app using **DynamicNotchKit 1.1.0** (MIT). The source is a
plain Swift package (`app/Package.swift` + `app/Sources/ClaudeNotch/*.swift`),
verified to compile + link against the real library.

**Run it:** `open ~/Desktop/ClaudeNotch/app/ClaudeNotch.app` → a 🔔 appears in the
menu bar. Its menu has **"Test notch ping"** to confirm the notch renders + taps work.

**Rebuild after code edits:** `cd app && ./build-app.sh` (uses the Xcode toolchain
for the SwiftUI macros DynamicNotchKit needs; ad-hoc signs; registers the URL scheme).

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

1. **Restart Cursor** — activates the extension and makes open sessions pick up the
   new global hooks.
2. **Brain test (no app needed):** rename a terminal tab (right-click → Rename →
   e.g. `frontend`), run `claude` in it, and trigger a permission prompt or let it
   finish. You should see a toast **"🔔 frontend needs you / finished"** with a
   **Focus tab** button — click it and the tab focuses. That proves matching + name +
   focus.
3. **Notch:** with `ClaudeNotch.app` running, the same triggers render in the notch.
   Click the notch → focuses the tab.

## Troubleshooting

- **Nothing happens:** "Claude Notch: Show Status" should log `listening
  127.0.0.1:39247`. Check `/hooks` lists the Notification + Stop hooks.
- **No ping at all for a Cursor agent:** "Show Status" output channel logs the
  decision per event — `ping name=…`, `suppressed — already viewing …`, or
  `no tab matched — ignored`. If it says *no tab matched*, make sure `claude` runs
  *directly* in that Cursor terminal (not via a wrapper / ssh / tmux).
- **End-of-turn ping didn't fire:** expected if that tab was active and Cursor was
  focused (the focus rule). Switch to another tab/app and it pings.
- **Toast instead of notch:** the app isn't running/registered. Launch
  `ClaudeNotch.app`; test via its menu. Re-run from Xcode to re-register the scheme.
- **Click doesn't focus:** if sandboxed, enable Outgoing Connections (Client).
- **Multiple Cursor windows:** only the window that grabbed port 39247 handles events
  (v1 limitation).

## Uninstall

- Extension: `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --uninstall-extension local.claude-notch`
- Hook: remove the `"hooks"` block from `~/.claude/settings.json` (or use `/hooks`).
- App: quit it, move `ClaudeNotch.app` to Trash.
- `rm -rf ~/.claude-notch`
