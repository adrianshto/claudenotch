#!/usr/bin/env bash
# Claude Notch — STANDALONE installer (no Cursor).
#
# Surfaces Claude Code agents (running in Terminal.app, iTerm2, or the Claude
# desktop app) on the MacBook notch — pings + a hover dashboard. Replaces the
# original's Cursor extension with a small always-on hub daemon.
#
# Sets up, idempotently:
#   1. hook + hub  → ~/.claude-notch/
#   2. terminal-notifier (banner fallback)        [Homebrew]
#   3. 5 Claude Code hooks → ~/.claude/settings.json  (non-clobbering)
#   4. builds + deploys the notch app → /Applications  [full Xcode]
#   5. LaunchAgents for hub + app (start at login, keep alive)
#
# Prereqs: Apple Silicon Mac, Homebrew, Node, and full Xcode (for the app build).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
NOTCH_DIR="$HOME/.claude-notch"
LA="$HOME/Library/LaunchAgents"
SETTINGS="$HOME/.claude/settings.json"
NODE="$(command -v node || true)"
[ -z "$NODE" ] && { echo "✗ Node not found — install Node first (brew install node)."; exit 1; }

echo "==> 1/5  hook + hub → $NOTCH_DIR"
mkdir -p "$NOTCH_DIR"
cp "$REPO/hook/notify-hook.js" "$NOTCH_DIR/notify-hook.js"
cp "$REPO/hub/hub.js"          "$NOTCH_DIR/hub.js"

echo "==> 2/5  terminal-notifier (banner fallback)"
if ! command -v terminal-notifier >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install terminal-notifier;
  else echo "    (skipped — install Homebrew + 'brew install terminal-notifier' for the banner fallback)"; fi
else echo "    already installed"; fi

echo "==> 3/5  wiring 5 hooks into $SETTINGS (non-clobbering)"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
"$NODE" -e '
const fs=require("fs"),p=process.argv[1],node=process.argv[2],hook=process.argv[3];
const s=JSON.parse(fs.readFileSync(p,"utf8"));
const cmd={type:"command",command:`${node} ${hook}`,async:true};
s.hooks=s.hooks||{};
for(const ev of ["Notification","Stop","SessionStart","UserPromptSubmit","SessionEnd"]) s.hooks[ev]=[{hooks:[cmd]}];
fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n");
console.log("    wired:",Object.keys(s.hooks).join(", "));
' "$SETTINGS" "$NODE" "$NOTCH_DIR/notify-hook.js"

echo "==> 4/5  building + deploying the notch app → /Applications"
if [ -d /Applications/Xcode.app ]; then
  ( cd "$REPO/app" && ./build-app.sh --deploy )
else
  echo "    ✗ full Xcode not found — the notch app needs it (DynamicNotchKit uses SwiftUI macros)."
  echo "      Install Xcode, then re-run. (Pings still work via terminal-notifier without the app.)"
fi

echo "==> 5/5  LaunchAgents (hub + app) — start at login, keep alive"
mkdir -p "$LA"
write_plist() { # label  program-args...
  local label="$1"; shift
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo "</dict></plist>"
  } > "$LA/$label.plist"
}
write_plist com.claudenotch.hub "$NODE" "$NOTCH_DIR/hub.js"
write_plist com.casper.claudenotch /Applications/ClaudeNotch.app/Contents/MacOS/ClaudeNotch
UID_=$(id -u)
for L in com.claudenotch.hub com.casper.claudenotch; do
  launchctl bootout "gui/$UID_/$L" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$LA/$L.plist" 2>/dev/null || true
done

echo
echo "✅ Done. Hub + notch app are running and auto-start at login."
echo "   Test: run 'claude' in a fresh Terminal.app tab, let it finish → the notch drops down."
echo "   Click a Terminal/iTerm ping or dashboard row → it jumps to that exact tab."
echo "   (Claude desktop app: click raises the app; per-chat jump is gated off by Anthropic — see README-STANDALONE.md.)"
