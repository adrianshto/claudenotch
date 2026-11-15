#!/opt/homebrew/bin/node
// Claude Notch — standalone hub (replaces the Cursor extension).
//
// Speaks the exact protocol ClaudeNotch.app already expects:
//   POST /event   ← hook posts lifecycle events
//   GET  /pings   → app long-polls (≤25s) for transient pings
//   GET  /roster  → app pulls on hover for the dashboard
//   POST /focus   ← app posts {sessionId} on click → activate the host app
//
// No Cursor: agents are keyed by Claude Code sessionId (not terminal tabs), named
// by the chat's ai-title, and "focus" best-effort activates the host app
// (Terminal / Claude desktop / iTerm) since there's no per-tab API outside Cursor.
//
// Runs always-on via LaunchAgent com.claudenotch.hub. Loopback only.

const http = require('http');
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = 39247;
const HOST = '127.0.0.1';
const LOG = path.join(os.homedir(), '.claude-notch', 'hub.log');
const PING_HOLD_MS = 25_000;   // long-poll hold
const DONE_PURPLE_MS = 120_000;
// Auto-expiry — the roster used to grow unbounded because entries only left on a
// clean SessionEnd (which often never fires: closed tab, crash, kill). Now we sweep:
//   • idle  = "opened but never used" → drop after IDLE_EXPIRE_MS of no events.
//   • done  = finished a while ago    → drop after DONE_EXPIRE_MS (you've seen it).
// running / needsYou never expire — they're live and actionable.
const IDLE_EXPIRE_MS  = 20 * 60_000;        // 20 min
const DONE_EXPIRE_MS  = 60 * 60_000;        // 60 min
const STALE_EXPIRE_MS = 12 * 60 * 60_000;   // 12h catch-all for ANY state — clears
                                            // orphaned running/needsYou entries whose
                                            // session crashed/closed without SessionEnd.
const PRUNE_EVERY_MS  = 60_000;             // sweep cadence
// Ping-noise controls (2026-07-17): background automations (launchd bots, headless
// `claude -p` loops) fire REAL Stop events every few seconds — 1000+ "finished"
// pings in a night, none of them human-relevant. Three filters:
//   • headless sessions (claude -p / --print, flagged by the hook) never roster or ping.
//   • an untitled session that lived < UNTITLED_MIN_LIFE_MS gets no done-ping —
//     one-shot automation; interactive chats either get an ai-title or live longer.
//   • global flood gate: > FLOOD_MAX pings in any rolling minute = a storm no matter
//     what it is → suppress the overflow.
// NO per-chat/per-project cooldown (removed 2026-07-17 after trying both): real
// chats ping on every turn-end, exactly like the original behavior the user liked.
const UNTITLED_MIN_LIFE_MS = 45_000;
const FLOOD_MAX_PER_MIN    = 8;
const ROSTER_FILE = path.join(os.homedir(), '.claude-notch', 'roster.json');

function log(line) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()}  ${line}\n`); } catch (_) {}
}

// sessionId -> { sessionId, name, state, window, folder, app, doneAt }
const roster = new Map();
const pingQueue = [];          // [{name,event,message,sessionId,window,focused,ts}]
let waiters = [];              // pending GET /pings responses
let recentPings = [];          // ts of pings that fired (global flood gate)

// Persist the roster across hub restarts. Without this every kickstart/rebuild
// wiped it: the dashboard went blank AND startedAt reset for live sessions, so
// the untitled<45s bot filter wrongly ate the next real "finished" ping.
let saveTimer = null;
function saveRoster() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try { fs.writeFileSync(ROSTER_FILE, JSON.stringify([...roster.values()])); } catch (_) {}
  }, 1000);
}
function loadRoster() {
  try {
    const arr = JSON.parse(fs.readFileSync(ROSTER_FILE, 'utf8'));
    const now = Date.now();
    for (const e of arr) {
      if (e && e.sessionId && now - (e.ts || 0) < STALE_EXPIRE_MS) roster.set(e.sessionId, e);
    }
    if (roster.size) log(`restored ${roster.size} roster entr${roster.size === 1 ? 'y' : 'ies'} from disk`);
  } catch (_) {}
}

function flushWaiters() {
  if (!pingQueue.length || !waiters.length) return;
  const batch = pingQueue.splice(0, pingQueue.length);
  const current = waiters;
  waiters = [];
  for (const res of current) sendJSON(res, batch);
}

function sendJSON(res, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(body);
}

// hookEvent → roster state + whether it queues a ping (mirrors the original contract).
function applyEvent(p) {
  const hookEvent = p.hookEvent || '';
  const sessionId = p.sessionId || '';
  if (!sessionId) return;

  // Bot traffic: headless one-shots (claude -p) never roster and never ping —
  // they'd churn the dashboard with 10-second "running" flashes and ping storms.
  if (p.headless) { log(`${hookEvent} ${sessionId} headless — ignored`); return; }

  const cwd = p.cwd || '';
  const folderName = path.basename(cwd) || 'agent';
  const name = (p.title && p.title.trim()) ? p.title.trim() : folderName;
  const appName = p.app || 'Terminal';

  const prev = roster.get(sessionId);
  const prevState = prev ? prev.state : null;
  const titled = !!(p.title && String(p.title).trim());
  const startedAt = (prev && prev.startedAt) || Date.now();

  if (hookEvent === 'SessionEnd') {
    roster.delete(sessionId);
    saveRoster();
    log(`SessionEnd ${sessionId} removed`);
    return;
  }

  let state = prevState || 'idle';
  let queuePing = false;
  let pingEvent = 'done';

  switch (hookEvent) {
    case 'UserPromptSubmit': state = 'running'; break;
    case 'SessionStart':     state = 'idle'; break;
    case 'Stop':
      state = 'done';
      queuePing = true;
      pingEvent = 'done';
      break;
    case 'Notification':
      // Idle-nudge suppression: Claude Code RE-FIRES "waiting for you" nudges while
      // a session sits done — or still needsYou. Either way you were already told;
      // only the transition INTO needsYou pings.
      if (prevState === 'done') { state = 'done'; queuePing = false; }
      else if (prevState === 'needsYou') { state = 'needsYou'; queuePing = false; }
      else { state = 'needsYou'; queuePing = true; pingEvent = 'needs_attention'; }
      break;
    default:
      state = prevState || 'idle';
  }

  // doneAt = when it FIRST entered `done`, preserved across later done-state events.
  // CRITICAL: Claude Code re-fires "waiting for you" Notification nudges while a
  // session sits done. If we restamped doneAt on each, the done-expiry sweep (and the
  // "just done" highlight) would never settle — only a fresh transition INTO done
  // (re)stamps it.
  const doneAt = state === 'done'
    ? ((prevState === 'done' && prev && prev.doneAt) ? prev.doneAt : Date.now())
    : undefined;

  const entry = {
    sessionId, name, state,
    window: folderName, folder: cwd, app: appName,
    tty: p.tty || (prev && prev.tty) || null,
    // Claude desktop chat id (`local_…`, resolved by the hook) → click opens that chat.
    localSessionId: p.localSessionId || (prev && prev.localSessionId) || null,
    ts: Date.now(),   // last-event time — drives idle/stale expiry
    startedAt,        // first-seen time — untitled short-lived = bot-like, no ping
    doneAt,
  };
  if (state !== 'done') delete entry.doneAt;
  roster.set(sessionId, entry);
  saveRoster();

  // Ping-noise filters — see UNTITLED_MIN_LIFE_MS / PING_COOLDOWN_MS notes above.
  let suppressed = null;
  if (queuePing) {
    const now = Date.now();
    recentPings = recentPings.filter((t) => now - t < 60_000);
    if (pingEvent === 'done' && !titled && now - startedAt < UNTITLED_MIN_LIFE_MS) {
      suppressed = 'untitled short-lived (bot-like)';
    } else if (recentPings.length >= FLOOD_MAX_PER_MIN) {
      suppressed = `flood gate (${FLOOD_MAX_PER_MIN}/min)`;
    } else {
      recentPings.push(now);
    }
    if (suppressed) queuePing = false;
  }

  log(`${hookEvent} ${sessionId} state=${state} name="${name}" app=${appName} ping=${queuePing}${suppressed ? ` (suppressed: ${suppressed})` : ''}`);

  if (queuePing) {
    pingQueue.push({
      name,
      event: pingEvent,
      message: p.message || '',
      sessionId,
      window: folderName,
      focused: false,          // v1: no per-window focus signal → always deliver
      ts: Date.now(),
    });
    flushWaiters();
  }
}

// Focus the chat. For Terminal/iTerm we know the session's TTY, so we can select
// the EXACT window + tab via AppleScript (real "click → land on the chat"). For the
// Claude desktop app we open its per-chat deep link. Anything else falls back to
// just activating the app.
function runOsa(script, tag, sessionId) {
  execFile('/usr/bin/osascript', ['-e', script], (err) => {
    if (err) log(`focus ${tag} error for ${sessionId}: ${err.message}`);
    else log(`focus ${tag} → ${sessionId}`);
  });
}

function focusSession(sessionId) {
  const entry = roster.get(sessionId);
  const appName = (entry && entry.app) || 'Terminal';
  const tty = entry && entry.tty;
  const localId = entry && entry.localSessionId;

  // Claude desktop: open the EXACT chat. `claude://code/continue?session=<local_…>`
  // is the app's own "continue this Code session" entry point — it raises the
  // window and navigates to that chat (verified 2026-11-16 on Claude 5.11492.5:
  // main.log shows LocalSessions.setFocusedSession → that id). The older
  // `claude://code/<bridge session_…>` form is silently dropped, so don't use it.
  // localId comes from the hook (desktopSession()); if it's missing we fall
  // through to the plain app raise below.
  if (appName === 'Claude' && localId && /^local_[A-Za-z0-9-]+$/.test(localId)) {
    const link = `claude://code/continue?session=${localId}`;
    execFile('/usr/bin/open', [link], (err) => {
      if (err) log(`focus claude-chat error for ${sessionId}: ${err.message}`);
      else log(`focus claude-chat → ${localId} (${sessionId})`);
    });
    return;
  }

  if (appName === 'Terminal' && tty) {
    // try-guard each window: Terminal can have non-terminal windows (Settings,
    // inspectors) that have no `tabs` and throw -1728, aborting the whole script.
    runOsa(
      `tell application "Terminal"
         repeat with w in windows
           try
             repeat with t in tabs of w
               if (tty of t) is "${tty}" then
                 set selected of t to true
                 set index of w to 1
                 activate
                 return
               end if
             end repeat
           end try
         end repeat
         activate
       end tell`, 'Terminal-tab', sessionId);
    return;
  }

  if (appName === 'iTerm' && tty) {
    runOsa(
      `tell application "iTerm"
         repeat with w in windows
           try
             repeat with t in tabs of w
               repeat with s in sessions of t
                 if (tty of s) is "${tty}" then
                   select s
                   select t
                   set index of w to 1
                   activate
                   return
                 end if
               end repeat
             end repeat
           end try
         end repeat
         activate
       end tell`, 'iTerm-tab', sessionId);
    return;
  }

  // Fallback: bring the host app forward (best we can do without a per-chat API).
  execFile('/usr/bin/open', ['-a', appName], (err) => {
    if (err) log(`focus open -a "${appName}" error: ${err.message}`);
    else log(`focus → activated "${appName}" for ${sessionId} (app-level)`);
  });
}

// Sweep stale entries so the roster (and the notch) stays bounded. See the
// IDLE_EXPIRE_MS / DONE_EXPIRE_MS notes above.
function prune() {
  const now = Date.now();
  let removed = 0;
  for (const [id, e] of roster) {
    const idleStale  = e.state === 'idle' && now - (e.ts || 0) > IDLE_EXPIRE_MS;
    const doneStale  = e.state === 'done' && now - (e.doneAt || e.ts || 0) > DONE_EXPIRE_MS;
    // Catch-all: even a "live" running/needsYou entry is abandoned if nothing has
    // touched it in 12h — its session is long gone. This is the backstop that keeps
    // the roster bounded when SessionEnd never fires.
    const stale      = now - (e.ts || 0) > STALE_EXPIRE_MS;
    if (idleStale || doneStale || stale) { roster.delete(id); removed++; }
  }
  if (removed) {
    saveRoster();
    log(`prune removed ${removed} stale (idle>${IDLE_EXPIRE_MS / 60000}m, done>${DONE_EXPIRE_MS / 60000}m, any>${STALE_EXPIRE_MS / 3600000}h) → ${roster.size} left`);
  }
}

// Drop finished/idle sessions on demand (the dashboard's "Clear finished" button
// and `claudenotch clear`). Keeps running + needsYou — those are still live.
function clearInactive(all) {
  let removed = 0;
  for (const [id, e] of roster) {
    if (all || e.state === 'done' || e.state === 'idle') { roster.delete(id); removed++; }
  }
  saveRoster();
  log(`clear removed ${removed} (all=${!!all}) → ${roster.size} left`);
  return removed;
}

function rosterArray() {
  return [...roster.values()].map((e) => {
    const out = {
      sessionId: e.sessionId, name: e.name, state: e.state, window: e.window,
    };
    if (e.state === 'done' && e.doneAt) out.doneAt = e.doneAt;
    return out;
  });
}

function readBody(req, cb) {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    try { cb(JSON.parse(raw || '{}')); } catch (_) { cb({}); }
  });
}

const server = http.createServer((req, res) => {
  const url = req.url || '';

  if (req.method === 'POST' && url === '/event') {
    readBody(req, (p) => { applyEvent(p); res.writeHead(204); res.end(); });
    return;
  }

  if (req.method === 'GET' && url === '/pings') {
    if (pingQueue.length) {
      const batch = pingQueue.splice(0, pingQueue.length);
      sendJSON(res, batch);
      return;
    }
    waiters.push(res);
    const timer = setTimeout(() => {
      waiters = waiters.filter((r) => r !== res);
      sendJSON(res, []);
    }, PING_HOLD_MS);
    req.on('close', () => {
      clearTimeout(timer);
      waiters = waiters.filter((r) => r !== res);
    });
    return;
  }

  if (req.method === 'GET' && url === '/roster') {
    sendJSON(res, rosterArray());
    return;
  }

  if (req.method === 'POST' && url === '/clear') {
    readBody(req, (p) => {
      const removed = clearInactive(p && p.all === true);
      // Return the authoritative post-clear roster so the app can refresh the live
      // dashboard from this response — no second round-trip, no blank-on-failure.
      sendJSON(res, { removed, roster: rosterArray() });
    });
    return;
  }

  if (req.method === 'POST' && url === '/focus') {
    readBody(req, (p) => {
      if (p.sessionId) focusSession(p.sessionId);
      res.writeHead(204); res.end();
    });
    return;
  }

  res.writeHead(404); res.end();
});

server.on('error', (err) => {
  // Most likely EADDRINUSE — another hub already owns the port. Exit quietly.
  log(`server error: ${err.message}`);
  process.exit(1);
});

loadRoster();
server.listen(PORT, HOST, () => log(`hub listening ${HOST}:${PORT} (DONE_PURPLE_MS=${DONE_PURPLE_MS}, idle_expire=${IDLE_EXPIRE_MS / 60000}m, done_expire=${DONE_EXPIRE_MS / 60000}m)`));

// Periodic sweep of stale entries (idle/done). unref() so it never holds the
// process open on its own — the HTTP server is what keeps us alive.
setInterval(prune, PRUNE_EVERY_MS).unref();
