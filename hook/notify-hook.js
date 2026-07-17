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

const NOTCH_DIR = path.join(os.homedir(), '.claude-notch');
const HUB_PORT = 39247;
const LOG = path.join(NOTCH_DIR, 'events.log');
const PAUSED_FLAG = path.join(NOTCH_DIR, 'paused');       // `claudenotch stop` = truly silent
const BANNER_STATE = path.join(NOTCH_DIR, '.banner-times.json');
const BANNER_COOLDOWN_MS = 60_000;   // max one fallback banner per (event,label) per minute
const TERMINAL_NOTIFIER = '/opt/homebrew/bin/terminal-notifier';

function log(line) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()}  ${line}\n`); } catch (_) {}
}

// --- chat title, two sources ---
// 1. Terminal CLI chats: the last `ai-title` line in the transcript (classic).
// 2. Claude desktop chats: the app stopped writing ai-title into transcripts
//    (~2026-07-13) — its auto-title lives ONLY in the app's own session store,
//    claude-code-sessions/<org>/<proj>/local_*.json ({cliSessionId, title}).
//    Scan newest-first and stop at the first match: the active chat's file was
//    just touched, so this is typically a handful of reads, not all ~240.
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

function desktopTitle(cliSessionId) {
  if (!cliSessionId) return null;
  try {
    const root = path.join(os.homedir(), 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
    const files = [];
    for (const org of fs.readdirSync(root)) {
      const orgDir = path.join(root, org);
      let projs; try { projs = fs.readdirSync(orgDir); } catch (_) { continue; }
      for (const proj of projs) {
        const projDir = path.join(orgDir, proj);
        let names; try { names = fs.readdirSync(projDir); } catch (_) { continue; }
        for (const f of names) {
          if (!f.startsWith('local_') || !f.endsWith('.json')) continue;
          const full = path.join(projDir, f);
          try { files.push({ full, mtime: fs.statSync(full).mtimeMs }); } catch (_) {}
        }
      }
    }
    files.sort((a, b) => b.mtime - a.mtime);
    for (const { full } of files) {
      try {
        const j = JSON.parse(fs.readFileSync(full, 'utf8'));
        if (j.cliSessionId === cliSessionId) {
          return (j.title && String(j.title).trim()) ? String(j.title).trim() : null;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return null;
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

// --- headless detection: is the owning claude process a `claude -p/--print` one-shot? ---
// Walk the ancestor chain to the first process whose argv is the `claude` CLI itself
// (not merely a path containing "claude"), then check for print/one-shot flags.
// Bot traffic (launchd agents, scripted loops) runs headless; humans don't.
function headlessClaude() {
  try {
    let pid = process.ppid;
    for (let i = 0; i < 8 && pid && pid > 1; i++) {
      const out = execFileSync('/bin/ps', ['-o', 'ppid=,args=', '-p', String(pid)], { encoding: 'utf8' }).trim();
      if (!out) break;
      const sp = out.indexOf(' ');
      const ppid = parseInt(out.slice(0, sp), 10);
      const args = out.slice(sp + 1).trim();
      if (/(^|[/\s])claude(\s|$)/.test(args)) return /\s(-p|--print)(\s|$)/.test(args);
      pid = ppid;
    }
  } catch (_) {}
  return false;
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

// Per-(event,label) cooldown so a hub outage doesn't turn event storms into banner
// storms — the exact failure the notch was built to avoid. State survives across
// hook invocations via a tiny json file (best-effort; a lost race just means one
// extra banner).
function bannerAllowed(key) {
  let m = {};
  try { m = JSON.parse(fs.readFileSync(BANNER_STATE, 'utf8')) || {}; } catch (_) {}
  const now = Date.now();
  if (now - (m[key] || 0) < BANNER_COOLDOWN_MS) return false;
  m[key] = now;
  for (const k of Object.keys(m)) if (now - m[k] > 3_600_000) delete m[k];
  try { fs.writeFileSync(BANNER_STATE, JSON.stringify(m)); } catch (_) {}
  return true;
}

function fallbackBanner(hookEvent, label, message) {
  if (hookEvent !== 'Stop' && hookEvent !== 'Notification') return;
  if (!bannerAllowed(`${hookEvent}|${label}`)) { log(`banner cooldown — skipped ${hookEvent} "${label}"`); return; }
  if (hookEvent === 'Stop') notify('Claude Notch', '✅ finished', label);
  else notify('Claude Notch', '🔔 needs you', `${label} — ${message || 'needs your input'}`);
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (raw += c));
process.stdin.on('end', () => {
  let p = {};
  try { p = JSON.parse(raw || '{}'); } catch (_) {}

  // `claudenotch stop` touches this flag: the whole tool is OFF — no hub post, no
  // fallback banner, no log spam. `claudenotch start` removes it.
  if (fs.existsSync(PAUSED_FLAG)) { process.exit(0); }

  const hookEvent = p.hook_event_name || 'unknown';
  const cwd = p.cwd || process.cwd();
  const project = path.basename(cwd) || 'agent';
  const sessionId = p.session_id || '';
  const title = chatTitle(p.transcript_path) || desktopTitle(sessionId);
  const label = title ? `${project} · ${title}` : project;
  const app = hostApp();
  const tty = controllingTty();
  const headless = headlessClaude();

  log(`event=${hookEvent} app=${app} tty=${tty || '-'} headless=${headless} label="${label}" session=${sessionId.slice(0, 8)}`);

  const payload = JSON.stringify({
    hookEvent, cwd, sessionId,
    // Real ai-title or null — the hub falls back to the folder name for display,
    // but needs to KNOW it's untitled (untitled + short-lived = bot, no ping).
    title: title || null,
    message: p.message || '',
    app, tty, headless,
  });

  // POST to the hub. On any connection failure, fall back to a banner.
  const req = http.request(
    { host: '127.0.0.1', port: HUB_PORT, path: '/event', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
      timeout: 1500 },
    (res) => { res.resume(); res.on('end', () => process.exit(0)); }
  );
  req.on('error', () => {
    if (headless) { process.exit(0); }   // bot traffic never banners
    log(`hub unreachable — fallback banner for ${hookEvent}`);
    fallbackBanner(hookEvent, label, p.message);
    setTimeout(() => process.exit(0), 1500);
  });
  req.on('timeout', () => { req.destroy(); });
  req.write(payload);
  req.end();
});

setTimeout(() => process.exit(0), 4000);
