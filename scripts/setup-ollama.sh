#!/usr/bin/env bash
# setup-ollama.sh — Setup the bridge so Ollama CLI can chat with NVIDIA NIM
#
# Reads API key from gemma-4-31b-it.py, starts the bridge on port 11545,
# verifies it, and prints the ollama run command.
#
# Usage:
#   bash scripts/setup-ollama.sh             # one-shot setup + foreground bridge
#   bash scripts/setup-ollama.sh --service   # install as systemd user service
#   bash scripts/setup-ollama.sh --background # run in background, log to /tmp

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PY_FILE="$REPO_DIR/gemma-4-31b-it.py"
BRIDGE_FILE="$REPO_DIR/nvidia-bridge.mjs"
SERVICE_SRC="$REPO_DIR/systemd/nvidia-ollama-bridge.service"

BRIDGE_HOST="${NVIDIA_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${NVIDIA_BRIDGE_PORT:-11545}"

green="\033[0;32m"; yellow="\033[1;33m"; red="\033[0;31m"; reset="\033[0m"
ok()   { echo -e "${green}✓${reset} $*"; }
warn() { echo -e "${yellow}⚠${reset} $*"; }
fail() { echo -e "${red}✗${reset} $*"; }
info() { echo -e "  $*"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " setup-ollama — bridge for ollama CLI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Prerequisites
command -v node &>/dev/null || { fail "node not found"; exit 1; }
ok "node $(node --version) found"

[ -f "$BRIDGE_FILE" ] || { fail "nvidia-bridge.mjs missing"; exit 1; }
ok "nvidia-bridge.mjs found"

# Extract API key
[ -f "$PY_FILE" ] || {
  fail "gemma-4-31b-it.py not found"
  info "Create it: cp gemma-4-31b-it.template.py gemma-4-31b-it.py  (then edit)"
  exit 1
}

API_KEY=$(grep -o 'nvapi-[A-Za-z0-9_-]*' "$PY_FILE" | head -1)
[ -z "$API_KEY" ] || [ "$API_KEY" = "nvapi-YOUR-KEY-HERE" ] && {
  fail "No valid API key in gemma-4-31b-it.py — edit it and paste your real key"
  exit 1
}
ok "API key extracted"

# Persist key
ENV_DIR="$HOME/.config/nvidia-ollama-bridge"
mkdir -p "$ENV_DIR"
echo "NVIDIA_API_KEY=$API_KEY" > "$ENV_DIR/env"
ok "API key saved to $ENV_DIR/env"

export NVIDIA_API_KEY="$API_KEY"

# Check if bridge already running
if wget -qO- "http://${BRIDGE_HOST}:${BRIDGE_PORT}/" &>/dev/null; then
  ok "bridge already running at http://${BRIDGE_HOST}:${BRIDGE_PORT}"
else
  case "${1:-}" in
    --service)
      echo
      echo "Installing systemd user service…"
      mkdir -p "$HOME/.config/systemd/user"
      sed "s|%REPO_DIR%|$REPO_DIR|g" "$SERVICE_SRC" \
        > "$HOME/.config/systemd/user/nvidia-ollama-bridge.service"
      systemctl --user daemon-reload
      systemctl --user enable --now nvidia-ollama-bridge.service
      sleep 2
      if wget -qO- "http://${BRIDGE_HOST}:${BRIDGE_PORT}/" &>/dev/null; then
        ok "Service started — bridge reachable"
      else
        warn "Service enabled but bridge not responding yet"
        info "Check: systemctl --user status nvidia-ollama-bridge"
      fi
      ;;
    --background)
      echo
      echo "Starting bridge in background…"
      nohup node "$BRIDGE_FILE" > /tmp/nvidia-bridge.log 2>&1 &
      BRIDGE_PID=$!
      sleep 2
      if kill -0 "$BRIDGE_PID" 2>/dev/null && wget -qO- "http://${BRIDGE_HOST}:${BRIDGE_PORT}/" &>/dev/null; then
        ok "Bridge started (PID $BRIDGE_PID), logs: /tmp/nvidia-bridge.log"
      else
        fail "Bridge failed — check /tmp/nvidia-bridge.log"
        tail -20 /tmp/nvidia-bridge.log
        exit 1
      fi
      ;;
    *)
      echo
      ok "Configuration complete"
      info "To start the bridge, choose one:"
      info "  Foreground:  node nvidia-bridge.mjs"
      info "  Background:  bash scripts/setup-ollama.sh --background"
      info "  Systemd:     bash scripts/setup-ollama.sh --service"
      echo
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Then chat with Ollama:"
      info "OLLAMA_HOST=http://${BRIDGE_HOST}:${BRIDGE_PORT} ollama run gemma4:latest"
      exit 0
      ;;
  esac
fi

# Verify
echo
RESP=$(wget -qO- "http://${BRIDGE_HOST}:${BRIDGE_PORT}/api/tags" 2>/dev/null)
if echo "$RESP" | grep -q '"models"'; then
  ok "/api/tags returned model list"
else
  warn "/api/tags returned unexpected response"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Ollama setup complete!"
echo
echo "Chat with NVIDIA Gemma-4 via Ollama:"
echo
echo "    OLLAMA_HOST=http://${BRIDGE_HOST}:${BRIDGE_PORT} ollama run gemma4:latest"
echo
info "Also works:  node nvidia-bridge.mjs --chat"
