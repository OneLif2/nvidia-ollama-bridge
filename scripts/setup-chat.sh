#!/usr/bin/env bash
# setup-chat.sh — Setup for `node nvidia-bridge.mjs --chat`
#
# Extracts the NVIDIA API key from gemma-4-31b-it.py and exports it,
# then verifies the bridge can run.
#
# Usage:
#   bash scripts/setup-chat.sh           # configure + verify
#   source scripts/setup-chat.sh         # configure + export key into current shell
#   bash scripts/setup-chat.sh --run     # configure and launch chat immediately

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PY_FILE="$REPO_DIR/gemma-4-31b-it.py"
BRIDGE_FILE="$REPO_DIR/nvidia-bridge.mjs"

green="\033[0;32m"; yellow="\033[1;33m"; red="\033[0;31m"; reset="\033[0m"
ok()   { echo -e "${green}✓${reset} $*"; }
warn() { echo -e "${yellow}⚠${reset} $*"; }
fail() { echo -e "${red}✗${reset} $*"; }
info() { echo -e "  $*"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " setup-chat — node nvidia-bridge.mjs --chat"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check prerequisites
if ! command -v node &>/dev/null; then
  fail "node not found — install Node.js >= 18"
  return 1 2>/dev/null || exit 1
fi
ok "node $(node --version) found"

if [ ! -f "$BRIDGE_FILE" ]; then
  fail "nvidia-bridge.mjs not found at $BRIDGE_FILE"
  return 1 2>/dev/null || exit 1
fi
ok "nvidia-bridge.mjs found"

# Extract API key from gemma-4-31b-it.py
if [ ! -f "$PY_FILE" ]; then
  fail "gemma-4-31b-it.py not found"
  info "Create it from the template:"
  info "  cp gemma-4-31b-it.template.py gemma-4-31b-it.py"
  info "  # then edit it and paste your real nvapi-... key"
  return 1 2>/dev/null || exit 1
fi

API_KEY=$(grep -o 'nvapi-[A-Za-z0-9_-]*' "$PY_FILE" | head -1)

if [ -z "$API_KEY" ] || [ "$API_KEY" = "nvapi-YOUR-KEY-HERE" ]; then
  fail "No valid API key in $PY_FILE"
  info "Edit gemma-4-31b-it.py and paste your real key (starts with nvapi-)"
  return 1 2>/dev/null || exit 1
fi

ok "API key extracted from gemma-4-31b-it.py"

# Persist to env file (for systemd / future shells)
ENV_DIR="$HOME/.config/nvidia-ollama-bridge"
mkdir -p "$ENV_DIR"
echo "NVIDIA_API_KEY=$API_KEY" > "$ENV_DIR/env"
ok "API key saved to $ENV_DIR/env"

# Export to current shell
export NVIDIA_API_KEY="$API_KEY"
ok "NVIDIA_API_KEY exported to current shell"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Ready! Run chat with:"
echo
echo "    node nvidia-bridge.mjs --chat"
echo
info "If you ran this script with 'bash' (not 'source'),"
info "the key is only set in this script's shell."
info "Either run:    source scripts/setup-chat.sh"
info "Or run:        bash scripts/setup-chat.sh --run"
echo

# Optional: launch chat directly
if [ "${1:-}" = "--run" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Starting chat…"
  echo
  exec node "$BRIDGE_FILE" --chat
fi
