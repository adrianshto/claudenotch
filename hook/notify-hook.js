#!/usr/bin/env node
'use strict';

/*
 * Claude Notch — Claude Code hook.
 *
 * Wired to the Notification hook (agent needs you) and the Stop hook (agent
 * finished). Reads the hook event JSON from stdin, computes this process's
 * ancestor PID chain (so the Cursor extension can match it to the terminal
 * tab it fired from), and POSTs a compact event to the extension.
 *
 * It must never block or break Claude Code: any failure exits 0 silently.
 */

const http = require('http');
const { execSync } = require('child_process');

const EXT_HOST = '127.0.0.1';
const EXT_PORT = 39247;

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    try {
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (c) => (data += c));
      process.stdin.on('end', () => resolve(data));
    } catch {
      resolve(data);
    }
    // Don't hang if no stdin is delivered.
    setTimeout(() => resolve(data), 400);
  });
}

// Walk the process tree from this process up to PID 1. One ps call, in-memory.
function ancestorPidChain() {
  const chain = [];
  let table;
  try {
    const out = execSync('ps -Ao pid=,ppid=', { encoding: 'utf8' });
    table = new Map();
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^(\d+)\s+(\d+)$/);
      if (m) table.set(parseInt(m[1], 10), parseInt(m[2], 10));
    }
  } catch {
    return [process.pid];
  }
  let pid = process.pid;
  for (let i = 0; i < 40 && pid > 1; i++) {
    chain.push(pid);
    const ppid = table.get(pid);
    if (ppid === undefined || ppid <= 0) break;
    pid = ppid;
  }
  return chain;
}

(async () => {
  let payload = {};
  try {
    const raw = await readStdin();
    if (raw && raw.trim()) payload = JSON.parse(raw);
  } catch {
    /* empty or non-JSON stdin — proceed with defaults */
  }

  const hookEvent = payload.hook_event_name || '';
  const event = hookEvent === 'Notification' ? 'needs_attention' : 'done';

  const body = JSON.stringify({
    event,
    hookEvent,
    pidChain: ancestorPidChain(),
    cwd: payload.cwd || process.cwd(),
    sessionId: payload.session_id || '',
    message: payload.message || '',
  });

  const req = http.request(
    {
      host: EXT_HOST,
      port: EXT_PORT,
      path: '/event',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      timeout: 1000,
    },
    (res) => {
      res.resume();
      res.on('end', () => process.exit(0));
    }
  );
  req.on('error', () => process.exit(0));
  req.on('timeout', () => {
    req.destroy();
    process.exit(0);
  });
  req.write(body);
  req.end();
})();
