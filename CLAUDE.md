# Claude Notch — agent context

Auto-loaded context for any agent working on this project. Read this first.

## What this is

A local macOS system, built in-house (no third-party notch app; local-only, no
telemetry), that surfaces Claude Code agents running in **Cursor integrated
terminals**, on/around the MacBook **notch**. Two surfaces, both rendered with the
**same engine (DynamicNotchKit 1.1.0)** so they animate identically:

1. **Transient pings** — a notch drop-down when an agent **needs you** (permission/
   question) or **finishes a turn**, labelled with the tab's name; click → focus that tab.
2. **On-demand dashboard** — flick the cursor to the notch and a notch drops down
   listing **all** your agents with live state (running / done / needs-you); click a
   row → focus that tab. Retracts when you move away.

Both label by the **name you give the terminal tab** (right-click → Rename), which the
extension reads live via `terminal.name`.

## Architecture

```
Claude Code hook ──POST /event──▶ Cursor extension ──open claudenotch://notify──▶ App (pings)
 (in the terminal)                (39247: matches tab,    ◀─POST /focus── (click → reveal tab)
                                   reads name, keeps        App (dashboard) ──GET /roster──▶ 39247
                                   the live roster)         (hover → fetch → show → click → /focus)
```

1. **Hook** (`hook/notify-hook.js`, Node) — wired to FIVE Claude Code events:
   `Notification`, `Stop`, `SessionStart`, `UserPromptSubmit`, `SessionEnd`. Computes
   its process-ancestor PID chain, POSTs `{event, hookEvent, pidChain, cwd, sessionId,
   message}` to the extension. Fails silently (exit 0) — never blocks an agent.
2. **Extension** (`extension/extension.js`, plain JS, installed `local.claude-notch`) —
   the brain. HTTP server on `127.0.0.1:39247`:
   - `POST /event`: match PID chain → `Terminal.processId`, read `terminal.name`, update
     the **roster** (sessionId → {name, state}), and fire a ping for Notification/Stop.
   - `GET /roster`: returns the live roster JSON (the app fetches this on hover).
   - `POST /focus`: `{sessionId}` → `terminal.show()` reveals + focuses that tab.
   - Logs focus decisions to `~/.claude-notch/ext.log`.
3. **App** (`app/`, SwiftUI menu-bar-only, built by `build-app.sh` → `ClaudeNotch.app`):
   - **Pings**: `NotchNotifier` shows a DynamicNotch on `claudenotch://notify`; tap →
     `Focus.request` (POST /focus) + raise Cursor.
   - **Dashboard**: `HoverDetector` (tiny panel over the notch) → on hover,
     `RosterFetcher` GETs /roster → `DashboardController` expands a DynamicNotch showing
     `RosterDashboardView`; retracts when the cursor leaves; row tap → focus.
   - Logs to `~/.claude-notch/app.log`.

## Behavior rules (intentional — don't "fix" these)

- **Needs you** (`Notification`): ping **always** fires (agent is blocked on you).
- **Finished** (`Stop`): ping fires **only if you're not already looking at that tab**
  (suppressed when `window.state.focused && activeTerminal === thatTerminal`).
- **Scope**: only agents matched to a Cursor terminal tab are tracked/pinged. Unmatched
  (background jobs, plain-terminal `claude`) are ignored.
- **Lifecycle → state**: `UserPromptSubmit`→running, `Stop`→done, `Notification`→needsYou,
  `SessionStart`→idle, `SessionEnd`→removed.
- **Dashboard is summon-on-hover** (not always-on) — keeps the notch clean and sidesteps
  DynamicNotchKit's always-on window eating clicks across the top quarter of the screen.

## Files — IN-FOLDER SOURCE vs LIVE SYSTEM COPIES

This folder is the **source of truth**. Editing source does **NOT** change live behavior
until you rebuild/reinstall (commands below).

| Piece | Source | Live copy the OS/Cursor/Claude uses |
|---|---|---|
| Hook | `hook/notify-hook.js` | `~/.claude-notch/notify-hook.js` + `hooks` block in `~/.claude/settings.json` (5 events) |
| Extension | `extension/extension.js`, `package.json` | `~/.cursor/extensions/local.claude-notch-<ver>` (currently 0.4.0) |
| App | `app/Sources/ClaudeNotch/*.swift`, `app/Package.swift`, `app/Info.plist` | runs from `app/ClaudeNotch.app` (NOT yet in /Applications) |

App source files: `ClaudeNotchApp` (MenuBarExtra), `AppDelegate` (URL handling, hover
wiring, raiseCursor, retract watcher), `NotchNotifier`+`NotchContent` (pings),
`DashboardController`+`RosterDashboardView`+`HoverDetector`+`ScreenNotch`+`RosterFetcher`
(dashboard), `RosterStore` (Agent/AgentState model), `ClickCatcher` (AppKit tap target
that works in non-key notch panels), `Focus` (POST /focus), `Log`.

⚠️ The app runs from this folder — moving/deleting it breaks `claudenotch://` until
rebuilt. Decouple later via /Applications + Login Item (deferred until iteration settles).

## Invariants (change in lockstep)

- **Port `39247`** (extension server): `/event`, `/focus`, `/roster`. Hardcoded in
  `hook/notify-hook.js` (`EXT_PORT`), `extension.js` (`PORT`), `RosterFetcher.swift`, `Focus.swift`.
- **URL scheme `claudenotch://`**: `notify` (ping) + `dashboard` (dev toggle). In
  `extension.js`, `app/Info.plist` (`CFBundleURLTypes`), `AppDelegate.swift`.
- **Hooks**: 5 events in `~/.claude/settings.json`, all running
  `/opt/homebrew/bin/node /Users/casper/.claude-notch/notify-hook.js` (absolute node path;
  hooks don't inherit the interactive PATH). `async:true` so they never delay an agent.
- **Lifecycle→state** strings must match `AgentState` raw values (`running`/`done`/`needsYou`/`idle`).
- **Bundle id** `com.casper.claudenotch`; **extension id** `local.claude-notch`.
- **Toolchain**: building the app needs **full Xcode** (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`),
  not the standalone CLT — DynamicNotchKit uses SwiftUI macros (`@Entry`/`#Preview`) that ship only with Xcode.

## Rebuild / reinstall after editing source

- **Hook:** `cp hook/notify-hook.js ~/.claude-notch/notify-hook.js`
- **Extension:** `cd extension && npx @vscode/vsce package --allow-missing-repository --no-dependencies`,
  then `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --install-extension claude-notch-<ver>.vsix --force`,
  then **Reload Cursor** (⌘⇧P → Developer: Reload Window). Reload clears the in-memory
  roster — it repopulates as lifecycle events fire.
- **App:** `cd app && ./build-app.sh` (sets DEVELOPER_DIR, builds release, bundles,
  ad-hoc signs, registers the URL scheme), then relaunch `ClaudeNotch.app`.

## Test / debug

- `curl -s http://127.0.0.1:39247/roster` — see the live roster JSON.
- App log: `~/.claude-notch/app.log`; extension log: `~/.claude-notch/ext.log`.
- Extension output channel: ⌘⇧P → "Claude Notch: Show Status".
- Dev toggle the dashboard: `open "claudenotch://dashboard"`.
- Fire a ping: `open "claudenotch://notify?name=demo&event=needs_attention&message=hi&sessionId=x"`.

## Status

- ✅ **Phase 1** — transient pings (Notification/Stop, scope + focus rules) + click-to-focus
  (cross-app: raises Cursor, reveals the tab). Verified end-to-end.
- ✅ **Phase 2a** — on-demand dashboard (DynamicNotchKit, summon-on-hover), real live roster
  via `GET /roster`, lifecycle-driven state, click-row-to-focus. Verified end-to-end,
  single window.
- ⬜ **Phase 2b** — multi-window. Today only the ONE Cursor window that binds port 39247 is
  tracked. Needs an app-as-hub refactor: app owns the inbound port; each window's extension
  registers + reports its terminals + has a focus callback; app aggregates a global roster
  and routes focus to the right window. (User runs several windows at once — this matters.)
- ⬜ **Phase 3** — focus highlight: when the user clicks/focuses a terminal, make it visually
  obvious which one is active (purple glow / tab tint) so side-by-side terminals are
  distinguishable. See task notes; extensions can't style the terminal DOM (sandbox) — likely
  tab-color via API, or workbench CSS injection (unsupported; security cost on a work machine).

## Known limitations

- Single window (port 39247 owner) only — see Phase 2b.
- Dashboard populates from lifecycle events, so a brand-new session shows only after its
  first event (could seed known state immediately — minor TODO).
- Agent↔tab match needs `claude` running **directly** in the Cursor terminal (not via
  ssh/tmux/wrapper) so the shell PID is in the hook's PID chain.
- `terminal.name` rename-tracking is real but **undocumented** in the VS Code API.

See `README.md` for human setup/run/uninstall and `PROTOCOL.md` for the exact wire format.
