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

function log(line) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()}  ${line}\n`); } catch (_) {}
}

// sessionId -> { sessionId, name, state, window, folder, app, doneAt }
const roster = new Map();
const pingQueue = [];          // [{name,event,message,sessionId,window,focused,ts}]
let waiters = [];              // pending GET /pings responses

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

  const cwd = p.cwd || '';
  const folderName = path.basename(cwd) || 'agent';
  const name = (p.title && p.title.trim()) ? p.title.trim() : folderName;
  const appName = p.app || 'Terminal';

  const prev = roster.get(sessionId);
  const prevState = prev ? prev.state : null;

  if (hookEvent === 'SessionEnd') {
    roster.delete(sessionId);
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
      // Idle-nudge suppression: a Notification while already done is Claude Code's
      // repeated "waiting for you" nudge → stay done, no ping.
      if (prevState === 'done') { state = 'done'; queuePing = false; }
      else { state = 'needsYou'; queuePing = true; pingEvent = 'needs_attention'; }
      break;
    default:
      state = prevState || 'idle';
  }

  const entry = {
    sessionId, name, state,
    window: folderName, folder: cwd, app: appName,
    tty: p.tty || (prev && prev.tty) || null,
    doneAt: state === 'done' ? Date.now() : (prev && prev.doneAt) || undefined,
  };
  if (state !== 'done') delete entry.doneAt;
  roster.set(sessionId, entry);

  log(`${hookEvent} ${sessionId} state=${state} name="${name}" app=${appName} ping=${queuePing}`);

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
// the EXACT window + tab via AppleScript (real "click → land on the chat"). For
// anything else (e.g. the Claude desktop app, which has no per-chat focus API we
// can drive), we fall back to just activating the app.
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

function rosterArray() {
  const now = Date.now();
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

server.listen(PORT, HOST, () => log(`hub listening ${HOST}:${PORT} (DONE_PURPLE_MS=${DONE_PURPLE_MS})`));
