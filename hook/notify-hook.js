#!/opt/homebrew/bin/node
// Claude Notch — hook (standalone, no Cursor).
//
// Wired to FIVE Claude Code events (Notification, Stop, SessionStart,
// UserPromptSubmit, SessionEnd). For each it:
//   1. resolves the chat title (ai-title) + the host app (Terminal / Claude / iTerm…)
//   2. POSTs the event to the hub (127.0.0.1:39247) → drives the notch + dashboard
//   3. if the hub is unreachable, falls back to a native terminal-notifier banner
//      (so you still get a ping even with the notch app/hub down)
//
// Best-effort, async, never blocks the agent. Always exits 0.

const http = require('http');
const { execFile, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const HUB_PORT = 39247;
const LOG = path.join(os.homedir(), '.claude-notch', 'events.log');
const TERMINAL_NOTIFIER = '/opt/homebrew/bin/terminal-notifier';

function log(line) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()}  ${line}\n`); } catch (_) {}
}

// --- chat title: last `ai-title` line Claude Code writes into the transcript ---
function chatTitle(transcriptPath) {
  try {
    if (!transcriptPath || !fs.existsSync(transcriptPath)) return null;
    const lines = fs.readFileSync(transcriptPath, 'utf8').split('\n');
    let title = null;
    for (const line of lines) {
      if (!line || line.indexOf('"ai-title"') === -1) continue;
      try {
        const o = JSON.parse(line);
        if (o.type === 'ai-title' && o.aiTitle) title = o.aiTitle;
      } catch (_) {}
    }
    return title;
  } catch (_) { return null; }
}

// --- host app: walk the process-ancestor chain, identify what's hosting `claude` ---
function hostApp() {
  try {
    let pid = process.ppid;
    for (let i = 0; i < 14 && pid && pid > 1; i++) {
      const out = execFileSync('/bin/ps', ['-o', 'ppid=,comm=', '-p', String(pid)], { encoding: 'utf8' }).trim();
      if (!out) break;
      const sp = out.indexOf(' ');
      const ppid = parseInt(out.slice(0, sp), 10);
      const comm = out.slice(sp + 1).trim().toLowerCase();
      if (comm.includes('claude.app')) return 'Claude';
      if (comm.includes('iterm')) return 'iTerm';
      if (comm.includes('cursor')) return 'Cursor';
      if (comm.includes('visual studio code') || comm.includes('code helper')) return 'Visual Studio Code';
      if (comm.includes('warp')) return 'Warp';
      if (comm.includes('ghostty')) return 'Ghostty';
      if (comm.includes('alacritty')) return 'Alacritty';
      if (comm.includes('/terminal.app/') || comm.endsWith('/terminal')) return 'Terminal';
      pid = ppid;
    }
  } catch (_) {}
  return 'Terminal';
}

// --- controlling TTY: lets the hub focus the exact Terminal/iTerm tab on click ---
function controllingTty() {
  try {
    const own = execFileSync('/bin/ps', ['-o', 'tty=', '-p', String(process.pid)], { encoding: 'utf8' }).trim();
    if (/^ttys/.test(own)) return `/dev/${own}`;
    let pid = process.ppid;
    for (let i = 0; i < 14 && pid > 1; i++) {
      const l = execFileSync('/bin/ps', ['-o', 'ppid=,tty=', '-p', String(pid)], { encoding: 'utf8' }).trim();
      if (!l) break;
      const sp = l.indexOf(' ');
      const ppid = parseInt(l.slice(0, sp), 10);
      const tty = l.slice(sp + 1).trim();
      if (/^ttys/.test(tty)) return `/dev/${tty}`;
      pid = ppid;
    }
  } catch (_) {}
  return null;
}

// --- fallback banner when the hub isn't answering ---
function notify(title, subtitle, message) {
  if (fs.existsSync(TERMINAL_NOTIFIER)) {
    execFile(TERMINAL_NOTIFIER,
      ['-title', title, '-subtitle', subtitle, '-message', message, '-sound', 'default'],
      (err) => { if (err) log(`terminal-notifier error: ${err.message}`); });
    return;
  }
  const script = `display notification ${JSON.stringify(message)} with title ${JSON.stringify(title)} subtitle ${JSON.stringify(subtitle)}`;
  execFile('/usr/bin/osascript', ['-e', script], () => {});
}

function fallbackBanner(hookEvent, label, message) {
  if (hookEvent === 'Stop') notify('Claude Notch', '✅ finished', label);
  else if (hookEvent === 'Notification') notify('Claude Notch', '🔔 needs you', `${label} — ${message || 'needs your input'}`);
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (raw += c));
process.stdin.on('end', () => {
  let p = {};
  try { p = JSON.parse(raw || '{}'); } catch (_) {}

  const hookEvent = p.hook_event_name || 'unknown';
  const cwd = p.cwd || process.cwd();
  const project = path.basename(cwd) || 'agent';
  const sessionId = p.session_id || '';
  const title = chatTitle(p.transcript_path);
  const label = title ? `${project} · ${title}` : project;
  const app = hostApp();
  const tty = controllingTty();

  log(`event=${hookEvent} app=${app} tty=${tty || '-'} label="${label}" session=${sessionId.slice(0, 8)}`);

  const payload = JSON.stringify({
    hookEvent, cwd, sessionId,
    title: title || project,
    message: p.message || '',
    app, tty,
  });

  // POST to the hub. On any connection failure, fall back to a banner.
  const req = http.request(
    { host: '127.0.0.1', port: HUB_PORT, path: '/event', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
      timeout: 1500 },
    (res) => { res.resume(); res.on('end', () => process.exit(0)); }
  );
  req.on('error', () => {
    log(`hub unreachable — fallback banner for ${hookEvent}`);
    fallbackBanner(hookEvent, label, p.message);
    setTimeout(() => process.exit(0), 1500);
  });
  req.on('timeout', () => { req.destroy(); });
  req.write(payload);
  req.end();
});

setTimeout(() => process.exit(0), 4000);
