'use strict';

/*
 * Claude Notch — Cursor / VS Code extension (the "brain").
 *
 *  - Listens on 127.0.0.1:39247 for events from the Claude Code hook.
 *  - Matches the hook's PID chain to a terminal's processId, reads that tab's
 *    name (the name YOU set via right-click -> Rename), and fires the notch
 *    app via the claudenotch:// URL scheme.
 *  - On click, the app POSTs back to /focus and we reveal + focus that tab.
 *
 * Plain JS on purpose: `vscode` is provided by the host at runtime, and
 * everything else is a Node built-in, so there are no dependencies to install.
 */

const vscode = require('vscode');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { exec } = require('child_process');

const HOST = '127.0.0.1';
const PORT = 39247;

// Append-only file log (sibling to the app's ~/.claude-notch/app.log) so the
// focus path is observable from outside Cursor's output channel.
const LOG_FILE = path.join(os.homedir(), '.claude-notch', 'ext.log');
function flog(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()}  ${msg}\n`);
  } catch (_) {
    /* logging must never break the extension */
  }
}

/** sessionId -> the terminal we matched, so a click can focus the right tab. */
const sessionTerminals = new Map();

/** sessionId -> { sessionId, name, state } — the live roster the dashboard shows. */
const roster = new Map();

// Map a Claude Code lifecycle hook to the agent state shown in the dashboard.
function stateFromHook(hookEvent) {
  switch (hookEvent) {
    case 'UserPromptSubmit': return 'running';
    case 'Stop': return 'done';
    case 'Notification': return 'needsYou';
    case 'SessionStart': return 'idle';
    case 'SessionEnd': return 'gone';
    default: return null;
  }
}

let server;
let output;

function activate(context) {
  output = vscode.window.createOutputChannel('Claude Notch');
  context.subscriptions.push(output);

  startServer();

  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((closed) => {
      for (const [sid, term] of sessionTerminals) {
        if (term === closed) {
          sessionTerminals.delete(sid);
          roster.delete(sid);
        }
      }
    }),
    vscode.commands.registerCommand('claudeNotch.showStatus', () => {
      output.show();
      output.appendLine(
        `status: listening ${HOST}:${PORT} | tracked sessions: ${sessionTerminals.size} | open terminals: ${vscode.window.terminals.length}`
      );
    }),
    { dispose: () => server && server.close() }
  );

  output.appendLine(`Claude Notch active. Listening on ${HOST}:${PORT}.`);
}

function deactivate() {
  if (server) server.close();
}

function startServer() {
  server = http.createServer((req, res) => {
    // The app fetches the live roster on hover to render the dashboard.
    if (req.method === 'GET' && req.url === '/roster') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([...roster.values()]));
      return;
    }
    if (req.method !== 'POST') {
      res.writeHead(405).end();
      return;
    }
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', async () => {
      try {
        const data = JSON.parse(body || '{}');
        if (req.url === '/event') {
          await handleEvent(data);
        } else if (req.url === '/focus') {
          focusSession(data && data.sessionId);
        }
        res.writeHead(200).end('ok');
      } catch (e) {
        output.appendLine(`error handling ${req.url}: ${String(e)}`);
        res.writeHead(400).end('bad request');
      }
    });
  });
  server.on('error', (e) => {
    output.appendLine(
      `server error: ${String(e)} — another Cursor window may already own port ${PORT}.`
    );
  });
  server.listen(PORT, HOST);
}

async function handleEvent(data) {
  const hookEvent = data.hookEvent || '';
  const pidChain = Array.isArray(data.pidChain) ? data.pidChain : [];
  const terminal = await findTerminal(pidChain);

  // Scope: only track/ping agents tied to a Cursor terminal tab. Background and
  // non-Cursor sessions (a plain-terminal `claude`, the assistant's own session,
  // etc.) match no tab and are ignored here.
  if (!terminal) {
    output.appendLine(`[${hookEvent}] no tab matched — ignored (not a Cursor-tab agent)`);
    return;
  }

  const sessionId = data.sessionId || '';
  const name = (terminal.name && terminal.name.trim()) || folderOf(data.cwd) || 'agent';
  if (sessionId) sessionTerminals.set(sessionId, terminal);

  // Keep the dashboard roster in sync with this lifecycle event.
  const state = stateFromHook(hookEvent);
  if (sessionId && state) {
    if (state === 'gone') {
      roster.delete(sessionId);
      sessionTerminals.delete(sessionId);
    } else {
      roster.set(sessionId, { sessionId, name, state });
    }
  }

  // Pings: only the two attention events. needs_attention always fires; done
  // respects the focus rule (quiet while you're already looking at that tab).
  if (hookEvent === 'Notification' || hookEvent === 'Stop') {
    const event = hookEvent === 'Notification' ? 'needs_attention' : 'done';
    if (event === 'done') {
      const viewing =
        vscode.window.state.focused && vscode.window.activeTerminal === terminal;
      if (viewing) {
        output.appendLine(`[done] suppressed — already viewing "${name}"`);
        return;
      }
    }
    output.appendLine(`[${event}] ping name="${name}" session=${sessionId}`);
    fireNotch({ name, event, message: data.message || '', sessionId });
  } else {
    output.appendLine(`[${hookEvent}] roster: name="${name}" state=${state}`);
  }
}

function folderOf(cwd) {
  return cwd ? String(cwd).split('/').filter(Boolean).pop() : '';
}

async function findTerminal(pidChain) {
  if (!pidChain.length) return undefined;
  const terms = vscode.window.terminals;
  const pids = await Promise.all(
    terms.map((t) => Promise.resolve(t.processId).then((p) => p, () => undefined))
  );
  for (let i = 0; i < terms.length; i++) {
    if (pids[i] !== undefined && pidChain.includes(pids[i])) return terms[i];
  }
  return undefined;
}

function fireNotch(p) {
  const url =
    'claudenotch://notify' +
    `?name=${encodeURIComponent(p.name)}` +
    `&event=${encodeURIComponent(p.event)}` +
    `&message=${encodeURIComponent(p.message)}` +
    `&sessionId=${encodeURIComponent(p.sessionId)}`;

  exec(`open ${shellQuote(url)}`, (err) => {
    if (!err) return;
    // App not installed/registered yet — never lose a ping; show a toast.
    output.appendLine(`open failed (${err.message}); falling back to toast.`);
    const verb = p.event === 'done' ? 'finished' : 'needs you';
    vscode.window.showInformationMessage(`🔔 ${p.name} ${verb}`, 'Focus tab').then((choice) => {
      if (choice === 'Focus tab') focusSession(p.sessionId);
    });
  });
}

function focusSession(sessionId) {
  if (!sessionId) {
    flog('focus: empty sessionId');
    return;
  }
  const term = sessionTerminals.get(sessionId);
  if (!term) {
    flog(`focus: NO terminal mapped for session=${sessionId} (known sessions: ${sessionTerminals.size})`);
    return;
  }
  flog(`focus: revealing tab "${term.name}" for session=${sessionId}`);
  term.show(false); // reveal + focus the tab within the Cursor window
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

module.exports = { activate, deactivate };
