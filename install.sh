#!/usr/bin/env bash
#
# Claude Notch — one-shot installer. Clone the repo, run `./install.sh`, restart Cursor.
# Sets up all three components from the source in this folder:
#   1. Hook script    → ~/.claude-notch/notify-hook.js
#   2. Hook wiring     → 5 events in ~/.claude/settings.json (merged, non-clobbering)
#   3. Menu-bar app    → built + deployed to /Applications + Login Item (auto-start)
#   4. Cursor extension→ packaged + installed (needs a Cursor restart to activate)
#
# Re-runnable (idempotent). Requires: full Xcode (for the app build), Node, and Cursor.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Claude Notch installer"

NODE="$(command -v node || true)"; NODE="${NODE:-/opt/homebrew/bin/node}"
HOOK_DIR="$HOME/.claude-notch"
SETTINGS="$HOME/.claude/settings.json"
CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"

# 1. Hook script -----------------------------------------------------------------
mkdir -p "$HOOK_DIR"
cp hook/notify-hook.js "$HOOK_DIR/notify-hook.js"
echo "  [1/4] hook script → $HOOK_DIR/notify-hook.js"

# 2. Wire the 5 hooks into settings.json (merge: keep other settings + other hooks) --
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
NODE="$NODE" HOOK="$HOOK_DIR/notify-hook.js" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p, node, hook = os.environ['SETTINGS'], os.environ['NODE'], os.environ['HOOK']
d = json.load(open(p))
cmd = f"{node} {hook}"
entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5, "async": True}]}
d.setdefault("hooks", {})
for ev in ["Notification", "Stop", "SessionStart", "UserPromptSubmit", "SessionEnd"]:
    arr = d["hooks"].get(ev, [])
    # drop any prior claude-notch entry so re-runs don't duplicate; keep unrelated hooks
    arr = [g for g in arr if not any(h.get("command", "").endswith("notify-hook.js") for h in g.get("hooks", []))]
    arr.append(entry)
    d["hooks"][ev] = arr
json.dump(d, open(p, "w"), indent=2)
print("  [2/4] hooks wired into", p, "(Notification, Stop, SessionStart, UserPromptSubmit, SessionEnd)")
PY

# 3. Build + deploy the menu-bar app, then load the Login Item -------------------
( cd app && ./build-app.sh --deploy )
cp app/com.casper.claudenotch.plist "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)/com.casper.claudenotch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.casper.claudenotch.plist"
echo "  [3/4] app deployed to /Applications + Login Item loaded (auto-starts at login)"

# 4. Package + install the Cursor extension --------------------------------------
if [ -x "$CURSOR_CLI" ]; then
  ( cd extension && npx --yes @vscode/vsce package --allow-missing-repository --no-dependencies -o claude-notch.vsix )
  "$CURSOR_CLI" --install-extension extension/claude-notch.vsix --force
  echo "  [4/4] extension installed"
else
  echo "  [4/4] SKIPPED — Cursor CLI not found at $CURSOR_CLI; install the extension manually."
fi

echo ""
echo "==> Done. RESTART Cursor (Quit + reopen) so the extension loads in every window."
echo "    Then run a 'claude' session in a Cursor terminal — the 🔔 is in your menu bar."
