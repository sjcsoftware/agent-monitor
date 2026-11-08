#!/usr/bin/env bash
# Installs or updates Agent Monitor.
#   curl -fsSL https://raw.githubusercontent.com/sjcsoftware/agent-monitor/main/install.sh | bash
set -euo pipefail

REPO="sjcsoftware/agent-monitor"
URL="${AGENT_MONITOR_URL:-https://github.com/$REPO/releases/latest/download/AgentMonitor.zip}"
BG_LABEL="com.sjcsoftware.agent-monitor.background"
BG_PLIST="$HOME/Library/Application Support/AgentMonitor/$BG_LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; else B=""; D=""; R=""; fi
say() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Agent Monitor runs on macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "Agent Monitor needs macOS 14 Sonoma or later."

# Keep an existing install where it is; otherwise /Applications if writable, else ~/Applications.
if [ -n "${AGENT_MONITOR_APP_DIR:-}" ]; then APP_DIR="$AGENT_MONITOR_APP_DIR"
elif [ -d /Applications/AgentMonitor.app ]; then APP_DIR=/Applications
elif [ -d "$HOME/Applications/AgentMonitor.app" ]; then APP_DIR="$HOME/Applications"
elif [ -w /Applications ]; then APP_DIR=/Applications
else APP_DIR="$HOME/Applications"
fi
APP="$APP_DIR/AgentMonitor.app"
BIN="$APP/Contents/MacOS/AgentMonitor"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading Agent Monitor"
curl -fsSL "$URL" -o "$TMP/AgentMonitor.zip" || die "download failed: $URL"
if curl -fsSL "$URL.sha256" -o "$TMP/AgentMonitor.zip.sha256" 2>/dev/null; then
  (cd "$TMP" && shasum -a 256 -c AgentMonitor.zip.sha256 >/dev/null 2>&1) || die "checksum mismatch; aborting."
fi
ditto -x -k "$TMP/AgentMonitor.zip" "$TMP/x"
[ -x "$TMP/x/AgentMonitor.app/Contents/MacOS/AgentMonitor" ] || die "the download doesn't contain AgentMonitor.app"
xattr -dr com.apple.quarantine "$TMP/x/AgentMonitor.app" 2>/dev/null || true

# Stop a running copy, remembering how it was running.
restart=""
if launchctl print "$DOMAIN/$BG_LABEL" >/dev/null 2>&1; then
  restart=background
  launchctl bootout "$DOMAIN/$BG_LABEL" 2>/dev/null || true
fi
if pgrep -f "^$BIN\$" >/dev/null 2>&1; then
  [ -z "$restart" ] && restart=open
  pkill -TERM -f "^$BIN\$" 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -f "^$BIN\$" >/dev/null 2>&1 || break; sleep 0.1; done
fi

say "Installing to $APP"
mkdir -p "$APP_DIR"
rm -rf "$APP"
mv "$TMP/x/AgentMonitor.app" "$APP"

# Put the CLI on PATH: reuse an existing link, else the first writable PATH dir we prefer.
in_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
BIN_DIR=""
existing="$(command -v agent-monitor 2>/dev/null || true)"
if [ -n "$existing" ] && [ -L "$existing" ]; then
  BIN_DIR="$(dirname "$existing")"
else
  for d in "$HOME/.local/bin" /usr/local/bin "$HOME/bin"; do
    if in_path "$d" && { [ -w "$d" ] || { [ ! -e "$d" ] && [ "$d" = "$HOME/.local/bin" ]; }; }; then BIN_DIR="$d"; break; fi
  done
fi
path_hint=""
if [ -z "$BIN_DIR" ]; then
  BIN_DIR="$HOME/.local/bin"
  path_hint=1
fi
mkdir -p "$BIN_DIR"
ln -sfn "$APP/Contents/Resources/agent-monitor" "$BIN_DIR/agent-monitor"

# Codex hooks point into the app bundle; refresh their path if they're installed.
if [ "$("$BIN" hooks status 2>/dev/null || true)" = "installed" ]; then
  "$BIN" hooks install >/dev/null 2>&1 || true
fi

case "$restart" in
  background) launchctl bootstrap "$DOMAIN" "$BG_PLIST" 2>/dev/null || true ;;
  open) open "$APP" ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
say "Agent Monitor $VERSION installed"
if [ -n "${AGENT_MONITOR_UPDATE:-}" ]; then
  [ -n "$restart" ] && echo "    Restarted."
  exit 0
fi
cat <<EOF

  ${B}agent-monitor${R}                   run it now
  ${B}agent-monitor set background${R}    keep it running after the terminal closes
  ${B}agent-monitor set startup${R}       start it at login
  ${B}agent-monitor help${R}              everything else
EOF
if [ -n "$path_hint" ]; then
  cat <<EOF

${D}$BIN_DIR is not on your PATH. Add it with:${R}
  echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.zshrc && source ~/.zshrc
EOF
fi
