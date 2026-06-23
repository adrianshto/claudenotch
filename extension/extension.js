'use strict';

/*
 * Claude Notch — Cursor / VS Code extension.
 *
 * MULTI-WINDOW via leader/follower:
 *  - The first window whose extension binds 127.0.0.1:39247 is the LEADER (hub).
 *    It serves /event (hook), /focus + /roster (app), and /register + /deregister
 *    (followers). It owns the GLOBAL roster across all windows and routes focus.
 *  - Every other window is a FOLLOWER: runs a tiny callback server, registers its
 *    terminals + focus state with the leader (heartbeat every 1.5s), and on the
 *    leader's request focuses one of its terminals. If the leader dies, a follower
 *    promotes itself (election retry every 3s).
 *
 * The app (notch) is unchanged — it still POSTs /focus and GETs /roster on 39247,
 * whichever window is currently the leader. A lone window is just a leader with
 * zero followers, so single-window behavior is identical to before.
 *
 * Plain JS: `vscode` is provided at runtime; everything else is a Node built-in.
 */

const vscode = require('vscode');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { exec } = require('child_process');

const HOST = '127.0.0.1';
const HUB_PORT = 39247;
const WINDOW_ID = `${process.pid}-${Math.random().toString(36).slice(2, 8)}`;

const LOG_FILE = path.join(os.homedir(), '.claude-notch', 'ext.log');
function flog(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()}  [${role}] ${msg}\n`);
  } catch (_) {
    /* logging must never break the extension */
  }
}

let output;
let role = 'starting';            // 'leader' | 'follower'
let server;                       // hub server (leader) OR callback server (follower)
let heartbeatTimer, electionTimer, pruneTimer;
let callbackPort = 0;

// Leader-only state
const roster = new Map();         // sessionId -> { sessionId, name, state, windowId, pid }
const followers = new Map();      // windowId  -> { callbackPort, terminals:[{pid,name}], focused, activeTerminalPid, lastSeen }
const localSessions = new Map();  // sessionId -> Terminal (this window's own)
let pendingPings = [];            // pings queued for the app to pull via GET /pings (long-poll)
let pingWaiter = null;            // { res, timer } when the app is parked waiting for a ping

function stateFromHook(h) {
  switch (h) {
    case 'UserPromptSubmit': return 'running';
    case 'Stop': return 'done';
    case 'Notification': return 'needsYou';
    case 'SessionStart': return 'idle';
    case 'SessionEnd': return 'gone';
    default: return null;
  }
}

function activate(context) {
  output = vscode.window.createOutputChannel('Claude Notch');
  context.subscriptions.push(output);

  init();

  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((closed) => {
      for (const [sid, t] of localSessions) {
        if (t === closed) { localSessions.delete(sid); roster.delete(sid); }
      }
    }),
    vscode.commands.registerCommand('claudeNotch.showStatus', () => {
      output.show();
      output.appendLine(
        `role=${role} window=${WINDOW_ID} | roster=${roster.size} followers=${followers.size} callbackPort=${callbackPort}`
      );
    }),
    { dispose: () => stopAll() }
  );
}

function deactivate() { stopAll(); }

function stopAll() {
  try { if (server) server.close(); } catch (_) {}
  clearInterval(heartbeatTimer);
  clearInterval(electionTimer);
  clearInterval(pruneTimer);
  if (role === 'follower') postJSON(HUB_PORT, '/deregister', { windowId: WINDOW_ID });
}

// ---- role bootstrap ----
function init() {
  const s = http.createServer(leaderHandler);
  s.once('error', (e) => {
    try { s.close(); } catch (_) {}
    if (e && e.code === 'EADDRINUSE') becomeFollower();
    else flog(`hub bind error: ${String(e)}`);
  });
  s.once('listening', () => { server = s; becomeLeader(); });
  s.listen(HUB_PORT, HOST);
}

function becomeLeader() {
  role = 'leader';
  flog(`became LEADER on ${HUB_PORT}`);
  if (output) output.appendLine(`Claude Notch: LEADER on ${HOST}:${HUB_PORT}`);
  clearInterval(pruneTimer);
  pruneTimer = setInterval(pruneFollowers, 2000);
}

function becomeFollower() {
  role = 'follower';
  const s = http.createServer(followerHandler);
  s.once('listening', () => {
    server = s;
    callbackPort = s.address().port;
    flog(`became FOLLOWER, callback port ${callbackPort}`);
    if (output) output.appendLine(`Claude Notch: FOLLOWER (hub elsewhere), callback ${callbackPort}`);
    registerWithLeader();
    clearInterval(heartbeatTimer); heartbeatTimer = setInterval(registerWithLeader, 1500);
    clearInterval(electionTimer); electionTimer = setInterval(tryPromote, 3000);
  });
  s.once('error', (e) => flog(`follower callback bind error: ${String(e)}`));
  s.listen(0, HOST); // ephemeral port
}

function tryPromote() {
  const s = http.createServer(leaderHandler);
  s.once('error', () => { try { s.close(); } catch (_) {} }); // leader still alive — retry later
  s.once('listening', () => {
    clearInterval(heartbeatTimer);
    clearInterval(electionTimer);
    try { if (server) server.close(); } catch (_) {} // close our callback server
    server = s;
    callbackPort = 0;
    becomeLeader();
  });
  s.listen(HUB_PORT, HOST);
}

// ---- leader request handling ----
function leaderHandler(req, res) {
  if (req.method === 'GET' && req.url === '/roster') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([...roster.values()]));
    return;
  }
  if (req.method === 'GET' && req.url === '/pings') { handlePingPoll(res); return; }
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }
  readBody(req).then((data) => {
    if (req.url === '/event') return handleEvent(data).then(() => ok(res));
    if (req.url === '/focus') { focusSession(data.sessionId); return ok(res); }
    if (req.url === '/register') { upsertFollower(data); return ok(res); }
    if (req.url === '/deregister') { removeFollower(data.windowId); return ok(res); }
    res.writeHead(404).end();
  }).catch((e) => { flog(`leader req error: ${String(e)}`); try { res.writeHead(400).end(); } catch (_) {} });
}

function ok(res) { res.writeHead(200).end('ok'); }

function upsertFollower(d) {
  if (!d || !d.windowId) return;
  followers.set(d.windowId, {
    callbackPort: d.callbackPort,
    label: d.label || 'window',
    folder: d.folder || '',
    terminals: Array.isArray(d.terminals) ? d.terminals : [],
    focused: !!d.focused,
    activeTerminalPid: d.activeTerminalPid,
    lastSeen: Date.now(),
  });
}

function removeFollower(windowId) {
  followers.delete(windowId);
  for (const [sid, e] of roster) if (e.windowId === windowId) roster.delete(sid);
}

function pruneFollowers() {
  const now = Date.now();
  for (const [wid, f] of followers) {
    if (now - f.lastSeen > 5000) { flog(`pruned stale follower ${wid}`); removeFollower(wid); }
  }
}

async function handleEvent(data) {
  const hookEvent = data.hookEvent || '';
  const pidChain = Array.isArray(data.pidChain) ? data.pidChain : [];
  const sessionId = data.sessionId || '';

  let windowId, name, pid, windowFocused, label, folder;
  const local = await findLocalTerminal(pidChain);
  if (local) {
    windowId = WINDOW_ID;
    label = windowLabel();
    folder = folderPath();
    name = (local.name && local.name.trim()) || folderOf(data.cwd) || 'agent';
    pid = await safePid(local);
    if (sessionId) localSessions.set(sessionId, local);
    // Is THIS agent's window the one you're looking at? (Whole window, not just the
    // active tab — so a window with several agents goes quiet while you work in it.)
    windowFocused = vscode.window.state.focused;
  } else {
    const f = resolveFollower(pidChain);
    if (!f) { output.appendLine(`[${hookEvent}] no tab matched (any window)`); return; }
    windowId = f.windowId; name = f.name; pid = f.pid;
    label = f.follower.label || 'window';
    folder = f.follower.folder || '';
    windowFocused = !!f.follower.focused;
  }

  // A Notification arriving while the agent is already `done` is just Claude
  // Code's repeated "waiting for you" idle nudge — keep it showing done, no ping.
  // (A Notification while running is a real permission/question prompt → pings.)
  const priorState = roster.get(sessionId) && roster.get(sessionId).state;
  if (hookEvent === 'Notification' && priorState === 'done') {
    output.appendLine(`[Notification] idle nudge for "${name}" — suppressed (already done)`);
    return;
  }

  const state = stateFromHook(hookEvent);
  if (sessionId && state) {
    if (state === 'gone') { roster.delete(sessionId); localSessions.delete(sessionId); }
    else {
      // Stamp the moment an agent ENTERS `done` (preserve it if it was already done),
      // so the dashboard can flag a freshly-finished agent distinctly from old ones.
      const prev = roster.get(sessionId);
      let doneAt;
      if (state === 'done') {
        doneAt = (prev && prev.state === 'done' && prev.doneAt) ? prev.doneAt : Date.now();
      }
      roster.set(sessionId, { sessionId, name, state, windowId, window: label, folder, pid, doneAt });
    }
  }

  if (hookEvent === 'Notification' || hookEvent === 'Stop') {
    const event = hookEvent === 'Notification' ? 'needs_attention' : 'done';
    // Always fire; the app decides whether to actually surface it, from its "quiet the
    // focused window" toggle + whether this agent's window was focused (sent below).
    output.appendLine(`[${event}] ping "${name}" window=${windowId} focused=${windowFocused} session=${sessionId}`);
    fireNotch({ name, event, message: data.message || '', sessionId, window: label, focused: windowFocused });
  } else {
    output.appendLine(`[${hookEvent}] roster "${name}" state=${state} window=${windowId}`);
  }
}

function resolveFollower(pidChain) {
  for (const [windowId, f] of followers) {
    for (const t of f.terminals) {
      if (t && pidChain.includes(t.pid)) return { windowId, name: t.name, pid: t.pid, follower: f };
    }
  }
  return null;
}

function focusSession(sessionId) {
  if (!sessionId) { flog('focus: empty sessionId'); return; }
  const entry = roster.get(sessionId);
  if (!entry) { flog(`focus: no roster entry for ${sessionId}`); return; }

  // Bring the owning Cursor window forward (across Spaces/fullscreen) via the CLI.
  raiseWindow(entry.folder);

  // Reveal the specific terminal tab within that window.
  if (entry.windowId === WINDOW_ID) {
    const t = localSessions.get(sessionId);
    if (t) { flog(`focus: local reveal "${entry.name}"`); t.show(false); }
    else flog(`focus: local terminal missing for ${sessionId}`);
  } else {
    const f = followers.get(entry.windowId);
    if (!f) { flog(`focus: follower ${entry.windowId} gone`); return; }
    flog(`focus: routing to follower ${entry.windowId} pid=${entry.pid}`);
    postJSON(f.callbackPort, '/focus', { pid: entry.pid });
  }
}

// ---- follower request handling ----
function followerHandler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }
  readBody(req).then(async (data) => {
    if (req.url === '/focus') { await focusLocalByPid(data.pid); return ok(res); }
    res.writeHead(404).end();
  }).catch(() => { try { res.writeHead(400).end(); } catch (_) {} });
}

async function focusLocalByPid(pid) {
  if (!pid) return;
  const terms = vscode.window.terminals;
  const pids = await Promise.all(terms.map(safePid));
  for (let i = 0; i < terms.length; i++) {
    if (pids[i] === pid) { flog(`focus: revealing local pid=${pid}`); terms[i].show(false); return; }
  }
  flog(`focus: no local terminal with pid=${pid}`);
}

async function registerWithLeader() {
  const terms = vscode.window.terminals;
  const pids = await Promise.all(terms.map(safePid));
  const terminals = [];
  for (let i = 0; i < terms.length; i++) {
    if (pids[i] !== undefined) {
      terminals.push({ pid: pids[i], name: (terms[i].name || '').trim() || 'agent' });
    }
  }
  const active = vscode.window.activeTerminal;
  const activeTerminalPid = active ? await safePid(active) : undefined;
  postJSON(HUB_PORT, '/register', {
    windowId: WINDOW_ID,
    callbackPort,
    label: windowLabel(),
    folder: folderPath(),
    terminals,
    focused: vscode.window.state.focused,
    activeTerminalPid,
  });
}

// ---- helpers ----
async function findLocalTerminal(pidChain) {
  if (!pidChain.length) return undefined;
  const terms = vscode.window.terminals;
  const pids = await Promise.all(terms.map(safePid));
  for (let i = 0; i < terms.length; i++) {
    if (pids[i] !== undefined && pidChain.includes(pids[i])) return terms[i];
  }
  return undefined;
}

function safePid(t) {
  return Promise.resolve(t.processId).then((p) => p, () => undefined);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => { try { resolve(JSON.parse(body || '{}')); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

function postJSON(port, urlPath, obj) {
  if (!port) return;
  const body = JSON.stringify(obj);
  const req = http.request(
    {
      host: HOST, port, path: urlPath, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 1000,
    },
    (res) => res.resume()
  );
  req.on('error', () => {});
  req.on('timeout', () => req.destroy());
  req.write(body);
  req.end();
}

function folderOf(cwd) {
  return cwd ? String(cwd).split('/').filter(Boolean).pop() : '';
}

// A human-readable label for THIS window — its project/folder name — so the
// dashboard can group agents by which Cursor window they're in.
function windowLabel() {
  if (vscode.workspace.name) return vscode.workspace.name;
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].name;
  return 'window';
}

// The filesystem path to reuse THIS window via `cursor --reuse-window <path>` —
// a .code-workspace file if there is one, else the first folder. This is how we
// raise the right window across Spaces (the private WindowServer APIs no-op on
// macOS 26; Cursor's own CLI activation crosses Spaces reliably).
function folderPath() {
  const wf = vscode.workspace.workspaceFile;
  if (wf && wf.scheme === 'file') return wf.fsPath;
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].uri.fsPath;
  return '';
}

// Ask Cursor to focus the window that has `folder` open. Runs the bundled CLI,
// which connects to the already-running instance and activates that window
// (app.focus({steal:true})) — bringing it forward even from another desktop.
function raiseWindow(folder) {
  if (!folder) return;
  const cli = require('path').join(vscode.env.appRoot, 'bin', 'cursor');
  exec(`${shellQuote(cli)} --reuse-window ${shellQuote(folder)}`, (err) => {
    if (err) flog(`raiseWindow(${folder}) failed: ${err.message}`);
    else flog(`raiseWindow: cursor --reuse-window ${folder}`);
  });
}

// Queue a ping for the app to pull. We deliberately do NOT `open` a URL: launching the
// app via a URL scheme foregrounds it and steals key focus from whatever you're typing.
// Instead the app long-polls GET /pings (below) and shows/suppresses the notch itself,
// without ever being brought to the front.
function fireNotch(p) {
  const ping = {
    name: p.name, event: p.event, message: p.message || '',
    sessionId: p.sessionId, window: p.window || '', focused: !!p.focused, ts: Date.now(),
  };
  if (pingWaiter) {
    // App is parked on a long-poll — hand it the ping immediately.
    clearTimeout(pingWaiter.timer);
    const w = pingWaiter; pingWaiter = null;
    try {
      w.res.writeHead(200, { 'Content-Type': 'application/json' });
      w.res.end(JSON.stringify([ping]));
      return;
    } catch (_) { /* connection gone — fall through and queue it */ }
  }
  pendingPings.push(ping);
  if (pendingPings.length > 20) pendingPings.shift();   // cap; drop oldest
}

// App long-poll: return queued pings at once, else hold the connection up to 25s so a
// ping arriving meanwhile is delivered instantly (no busy polling, no focus steal).
function handlePingPoll(res) {
  if (pendingPings.length) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(pendingPings));
    pendingPings = [];
    return;
  }
  if (pingWaiter) { try { pingWaiter.res.end('[]'); } catch (_) {} clearTimeout(pingWaiter.timer); }
  const timer = setTimeout(() => {
    pingWaiter = null;
    try { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('[]'); } catch (_) {}
  }, 25000);
  pingWaiter = { res, timer };
}

function shellQuote(s) { return `'${String(s).replace(/'/g, `'\\''`)}'`; }

module.exports = { activate, deactivate };
