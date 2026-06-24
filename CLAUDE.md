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
Claude Code hook ──POST /event──▶ Cursor extension (leader, 127.0.0.1:39247)
 (in the terminal)                 matches tab → updates roster, queues pings, raises windows
                                   ◀── GET /pings   (app long-polls; focus-SAFE ping delivery)
   App (notch) ───────────────────◀── GET /roster  (app pulls on hover → dashboard)
                                   ──▶ POST /focus  (app pushes on click → raise window + reveal tab)
```

**Why the app PULLS pings** (not `open claudenotch://`): launching the app via a URL
foregrounds it and steals key focus from whatever you're typing. So the app long-polls
`GET /pings` instead — it's never launched/foregrounded, so a ping never yanks your cursor.

1. **Hook** (`hook/notify-hook.js`, Node) — wired to FIVE Claude Code events:
   `Notification`, `Stop`, `SessionStart`, `UserPromptSubmit`, `SessionEnd`. Computes
   its process-ancestor PID chain, POSTs `{event, hookEvent, pidChain, cwd, sessionId,
   message}` to the extension. Fails silently (exit 0) — never blocks an agent.
2. **Extension** (`extension/extension.js`, plain JS, installed `local.claude-notch`) —
   the brain, with a **leader/follower** model for multi-window:
   - The first window to bind `127.0.0.1:39247` is the **LEADER (hub)**. Every other
     window is a **FOLLOWER** that runs a tiny callback server on an ephemeral port and
     registers with the leader (heartbeat every 1.5s). If the leader dies, a follower
     promotes (election retry every 3s). A lone window is just a leader with no followers
     → identical to single-window behavior.
   - Leader endpoints: `POST /event` (hook; resolves the PID chain against its OWN
     terminals AND followers' registered terminals → updates the GLOBAL roster + queues a
     ping), `GET /pings` (app long-polls; returns queued pings, else holds ≤25s), `GET
     /roster` (app fetches on hover; returns all windows' agents), `POST /focus`
     (`{sessionId}` → **raises the owning window across Spaces** via `cursor
     --reuse-window <folder>`, then reveals the terminal locally OR routes the reveal to
     the owning follower's callback port), `POST /register` + `POST /deregister` (followers).
   - A queued ping is `{name, event, message, sessionId, window, focused, ts}` — `focused`
     = was that agent's window focused when it fired (the app uses it for the "quiet the
     focused window" toggle); `ts` = epoch-ms, so the app drops pings staler than 30s.
   - Each roster entry: `{sessionId, name, state, windowId, window, folder, pid, doneAt}` —
     `window` is the human label (project/folder name via `vscode.workspace.name`) the
     dashboard groups by; `folder` is the workspace's filesystem path, used to raise that
     exact window (see "Window raising" below); `doneAt` is the epoch-ms moment the agent
     entered `done` (omitted otherwise), so the dashboard can flag a *fresh* finish.
     Followers report their `folder` in `/register` so the leader can raise any window.
   - Logs role + focus decisions to `~/.claude-notch/ext.log`.
3. **App** (`app/`, SwiftUI menu-bar-only, built by `build-app.sh` → `ClaudeNotch.app`):
   - **Pings**: `AppDelegate.startPingPolling()` long-polls `GET /pings`; for each ping it
     applies the focus-mute toggle (below), then `NotchNotifier` shows a DynamicNotch
     (a non-key panel — `becomesKeyOnlyIfNeeded`, so it never steals your text cursor);
     tap → `Focus.request` (POST /focus). The app never touches windows itself.
   - **Menu** (`ClaudeNotchApp`): a 🔔 `MenuBarExtra` with a **"Quiet the window I'm
     working in"** toggle (`@AppStorage("focusMute")`, default ON), "Test Notch Ping", Quit.
   - **Dashboard**: `HoverDetector` (tiny panel over the notch) → on hover,
     `RosterFetcher` GETs /roster → `DashboardController` expands a DynamicNotch showing
     `RosterDashboardView`; retracts when the cursor leaves; row tap → `Focus.request`.
   - **No system permissions** (no Accessibility, no Screen Recording) — focusing is
     delegated to Cursor's own CLI via the extension.
   - Logs to `~/.claude-notch/app.log`.

## Window raising (how click-to-focus reaches the right window across desktops)

This is the non-obvious core. When a ping/row is clicked, the app POSTs `/focus
{sessionId}`; the leader's `focusSession` does two things:

1. **Raise the owning window** — `cursor --reuse-window <folder>` (the bundled Cursor
   CLI, `vscode.env.appRoot + /bin/cursor`). Cursor's own activation
   (`app.focus({steal:true})`) brings that window forward **across Spaces, fullscreen,
   and minimized** — the thing macOS gives no app-level API for.
2. **Reveal the terminal tab** inside it (`terminal.show()`, local or routed to the
   follower).

**Why this and not the WindowServer/AX route:** the obvious approach (AltTab-style
private APIs: `_SLPSSetFrontProcessWithOptions`, `_AXUIElementCreateWithRemoteToken`
brute force, `kAXRaiseAction`) was built and **fails on macOS 26 Tahoe** — the SLPS
front call returns success but no-ops, and the remote-token brute force yields only dead
element handles. Cursor's CLI sidesteps all of it by letting Cursor focus its own window.
Tradeoff: each focus spawns a brief throwaway Cursor "forwarder" process (dock flash)
that hands the request to the running instance and quits — inherent to Cursor's
single-instance-over-pipe model; harmless, only one real instance runs.

## Behavior rules (intentional — don't "fix" these)

- **Quiet the focused window** (`focusMute` toggle, default ON): a ping whose agent window
  was **focused** when it fired is **suppressed by the app** (you're working in that window
  — done AND needs-you go quiet, for *every* agent/pane in it). Other windows ping normally.
  Toggle OFF → everything pings regardless of focus. The extension stamps `focused` per
  ping (whole-window focus, not just the active tab); the app decides. NOTE: this replaced
  the old per-*tab* Stop suppression.
- **Idle-nudge suppression** (extension-side, always on): a `Notification` while the agent
  is already `done` is Claude Code's repeated idle "waiting for you" nudge → no ping
  queued (stays `done`). Detected via prior roster state, not message text.
- **Needs you** (`Notification`) vs **Finished** (`Stop`): both queue a ping; the app
  surfaces or suppresses it per the focus-mute toggle above.
- **Scope**: only agents matched to a Cursor terminal tab are tracked/pinged. Unmatched
  (background jobs, plain-terminal `claude`) are ignored.
- **Lifecycle → state**: `UserPromptSubmit`→running, `Stop`→done, `Notification`→needsYou
  (unless already `done` → stays `done`, no ping), `SessionStart`→idle, `SessionEnd`→removed.
- **Dashboard is summon-on-hover** (not always-on) — keeps the notch clean and sidesteps
  DynamicNotchKit's always-on window eating clicks across the top quarter of the screen.
- **Recently-done is visually distinct**: an agent that entered `done` within the last
  **2 minutes** (`Agent.doneRecently`, from `doneAt`) renders **purple** + label "just
  done"; older `done` stays yellow. Same position/grouping — just the hue — so a fresh
  finish is findable in a pile of `done` rows. Render-time only: `done` is still one state
  (no new `AgentState` case, counts unchanged); computed per-fetch against the clock.

## Files — IN-FOLDER SOURCE vs LIVE SYSTEM COPIES

This folder is the **source of truth**. Editing source does **NOT** change live behavior
until you rebuild/reinstall (commands below).

| Piece | Source | Live copy the OS/Cursor/Claude uses |
|---|---|---|
| Hook | `hook/notify-hook.js` | `~/.claude-notch/notify-hook.js` + `hooks` block in `~/.claude/settings.json` (5 events) |
| Extension | `extension/extension.js`, `package.json` | `~/.cursor/extensions/local.claude-notch-<ver>` (currently 0.12.0) |
| App | `app/Sources/ClaudeNotch/*.swift`, `app/Package.swift`, `app/Info.plist` | **runs from `/Applications/ClaudeNotch.app`** (auto-starts at login via LaunchAgent `~/Library/LaunchAgents/com.casper.claudenotch.plist`); built in `app/ClaudeNotch.app`, deployed there by `build-app.sh` |

App source files: `ClaudeNotchApp` (MenuBarExtra + focus-mute toggle), `AppDelegate`
(ping long-poll + focus-mute decision, hover wiring, retract watcher; clicks just call
`Focus.request`), `NotchNotifier`+`NotchContent` (pings),
`DashboardController`+`RosterDashboardView`+`HoverDetector`+`ScreenNotch`+`RosterFetcher`
(dashboard), `RosterStore` (Agent/AgentState model), `ClickCatcher` (AppKit tap target
that works in non-key notch panels), `Focus` (POST /focus), `Log`.

✅ The app is **installed**: it runs from `/Applications/ClaudeNotch.app` and auto-starts
at login (LaunchAgent `com.casper.claudenotch`). This `app/` folder is **source only** —
editing/rebuilding here is safe; `build-app.sh` redeploys the fresh build to /Applications
(see Rebuild). The Desktop copy is no longer the `claudenotch://` handler.

## Invariants (change in lockstep)

- **Port `39247`** (extension server): `/event`, `/focus`, `/roster`, `/pings`. Hardcoded in
  `hook/notify-hook.js` (`EXT_PORT`), `extension.js` (`PORT`), `RosterFetcher.swift`,
  `Focus.swift`, and `AppDelegate.fetchPings()` (the `/pings` long-poll URL).
- **URL scheme `claudenotch://`**: now only `dashboard` (dev toggle) — pings moved to the
  `/pings` long-poll (URL `open` foregrounded the app and stole focus). In `app/Info.plist`
  (`CFBundleURLTypes`), `AppDelegate.swift`.
- **Focus-mute** key: `focusMute` in `UserDefaults` (`@AppStorage` in `ClaudeNotchApp`,
  read in `AppDelegate.handlePing`), default registered `true`.
- **Hooks**: 5 events in `~/.claude/settings.json`, all running
  `/opt/homebrew/bin/node /Users/casper/.claude-notch/notify-hook.js` (absolute node path;
  hooks don't inherit the interactive PATH). `async:true` so they never delay an agent.
- **Lifecycle→state** strings must match `AgentState` raw values (`running`/`done`/`needsYou`/`idle`).
- **Bundle id** `com.casper.claudenotch`; **extension id** `local.claude-notch`.
- **Toolchain**: building the app needs **full Xcode** (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`),
  not the standalone CLT — DynamicNotchKit uses SwiftUI macros (`@Entry`/`#Preview`) that ship only with Xcode.

## Rebuild / reinstall after editing source

**Fresh setup from a clean clone (no prior context): `./install.sh`** — does all four
steps below (hook script + wire the 5 hooks into `~/.claude/settings.json` non-clobbering +
build/deploy the app + load the Login Item + package/install the extension), then **restart
Cursor**. Idempotent. Needs full Xcode, Node, Cursor. The per-component commands below are
for iterating on one piece after it's already installed:

- **Hook:** `cp hook/notify-hook.js ~/.claude-notch/notify-hook.js`
- **Extension:** `cd extension && npx @vscode/vsce package --allow-missing-repository --no-dependencies`,
  then `"/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --install-extension claude-notch-<ver>.vsix --force`,
  then **Reload Cursor** (⌘⇧P → Developer: Reload Window). Reload clears the in-memory
  roster — it repopulates as lifecycle events fire.
- **App:** `cd app && ./build-app.sh` (sets DEVELOPER_DIR, builds release, bundles, signs
  with the stable "ClaudeNotch Self-Signed" cert if present — see `setup-signing.sh` — else
  ad-hoc). Because a copy exists in /Applications, it **auto-redeploys there** + re-registers
  the URL handler; then restart the running app:
  `launchctl kickstart -k gui/$(id -u)/com.casper.claudenotch`. (First-time install on a new
  machine: `./build-app.sh --deploy`, then load the LaunchAgent — see README. The app needs
  no system permissions; signing is just a stable identity, optional.)

## Test / debug

- `curl -s http://127.0.0.1:39247/roster` — see the live roster JSON.
- `curl -s http://127.0.0.1:39247/pings` — drains the queued pings (the app's long-poll;
  may hold ~25s if none are pending).
- App log: `~/.claude-notch/app.log`; extension log: `~/.claude-notch/ext.log`.
- Extension output channel: ⌘⇧P → "Claude Notch: Show Status".
- Dev toggle the dashboard: `open "claudenotch://dashboard"`.
- Fire a test notch: 🔔 menu → "Test Notch Ping" (the `claudenotch://notify` URL path is
  gone — pings now flow via `/pings`).

## Status

- ✅ **Phase 1** — transient pings (Notification/Stop, scope + focus rules) + click-to-focus
  (cross-app: raises Cursor, reveals the tab). Verified end-to-end.
- ✅ **Phase 2a** — on-demand dashboard (DynamicNotchKit, summon-on-hover), real live roster
  via `GET /roster`, lifecycle-driven state, click-row-to-focus. Verified end-to-end,
  single window.
- ✅ **Phase 2b (Step 1)** — multi-window via leader/follower (above). Verified end-to-end:
  the dashboard aggregates agents from ALL windows, grouped by window (project label), and
  click-to-focus **routes into the owning follower window and reveals its terminal**.
- ✅ **Phase 2b (Step 2)** — raise the *specific* other window on focus, **across Spaces**:
  **DONE.** First attempt used the macOS private WindowServer/AX route (AltTab-style: SLPS
  front + remote-token AX brute force + `kAXRaiseAction`); it works on older macOS but
  **no-ops on macOS 26 Tahoe** (SLPS returns success yet does nothing; the remote-token brute
  force returns only dead element handles — both verified in `app.log`). Replaced with
  **Cursor's own CLI**: the extension runs `cursor --reuse-window <folder>` on focus, and
  Cursor's `app.focus({steal:true})` raises that window across Spaces/fullscreen/minimized.
  No Accessibility/Screen Recording needed. See "Window raising". Only wart: a brief
  throwaway Cursor forwarder process flashes in the dock per focus (Cursor's
  single-instance model) — harmless.
- ✅ **Phase 2c** — quiet-the-focused-window + focus-safe delivery: **DONE.** The agent
  window you're focused on stays silent (toggle in the 🔔 menu, default ON; whole window,
  not just the active tab). Crucially, pings no longer `open claudenotch://` — that
  foregrounded the app and **stole key focus from whatever you were typing**, even when the
  notch was suppressed. The app now **long-polls `GET /pings`** (extension queues; never
  launches the app), and the notch panel is non-key (`becomesKeyOnlyIfNeeded`). Result: a
  ping (shown or suppressed) never knocks you out of your editor. Verified end-to-end.
- ⛔ **Phase 3** — focus highlight (glow on the focused pane): **EXPLORED & DROPPED.** No native
  API outlines the focused split pane (VS Code rejected it, #210579); a real pane glow needs
  workbench CSS injection (patches Cursor's bundle, "corrupt install" banner, re-patch per
  update, work-machine risk). User decided the **native active-tab highlight is fine** and
  declined the CSS hack. Optional-if-asked: split a distinct "idle" state out of needsYou.

## Known limitations

- Cross-Space window raising works via `cursor --reuse-window` (see "Window raising"),
  but each focus flashes a throwaway Cursor forwarder process in the dock — inherent to
  Cursor's single-instance-over-pipe model on a local install; cosmetic, only one real
  instance runs. The bounce-free alternative (private WindowServer APIs) no-ops on macOS 26.
- All windows' extensions must be the **same version** — a stale one holding the port as a
  pre-leader/follower build breaks the model. After updating, reload every Cursor window.
- Dashboard populates from lifecycle events, so a brand-new session shows only after its
  first event (could seed known state immediately — minor TODO).
- Agent↔tab match needs `claude` running **directly** in the Cursor terminal (not via
  ssh/tmux/wrapper) so the shell PID is in the hook's PID chain.
- `terminal.name` rename-tracking is real but **undocumented** in the VS Code API.

See `README.md` for human setup/run/uninstall and `PROTOCOL.md` for the exact wire format.
