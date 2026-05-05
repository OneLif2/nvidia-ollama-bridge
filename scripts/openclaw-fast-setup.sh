#!/usr/bin/env bash
# openclaw-fast-setup.sh — Phase 3 OpenClaw integration for nvidia-ollama-bridge
#
# Usage:
#   bash openclaw-fast-setup.sh all               # full setup
#   bash openclaw-fast-setup.sh install           # systemd service only
#   bash openclaw-fast-setup.sh configure-memory  # memory-lancedb-pro wiring
#   bash openclaw-fast-setup.sh check             # health checks

set -euo pipefail

BRIDGE_HOST="${NVIDIA_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${NVIDIA_BRIDGE_PORT:-11545}"
BRIDGE_MODEL="${NVIDIA_MODEL:-google/gemma-4-31b-it}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_JSON="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
OLLAMA_BASE="${OLLAMA_BASE_URL:-http://localhost:11434}"
EMBED_MODEL="${MEMORY_EMBED_MODEL:-nomic-embed-text}"

green="\033[0;32m"; yellow="\033[1;33m"; red="\033[0;31m"; reset="\033[0m"
ok()   { echo -e "${green}✓${reset} $*"; }
warn() { echo -e "${yellow}⚠${reset} $*"; }
fail() { echo -e "${red}✗${reset} $*"; }
info() { echo -e "  $*"; }

# ── install ──────────────────────────────────────────────────────────────────
cmd_install() {
  echo "Installing systemd user service…"
  local svc_src="$REPO_DIR/systemd/nvidia-ollama-bridge.service"
  local svc_dir="$HOME/.config/systemd/user"
  local svc_dst="$svc_dir/nvidia-ollama-bridge.service"

  mkdir -p "$svc_dir"
  sed "s|%REPO_DIR%|$REPO_DIR|g" "$svc_src" > "$svc_dst"

  systemctl --user daemon-reload
  systemctl --user enable --now nvidia-ollama-bridge.service
  ok "Service enabled and started"
  info "Status: systemctl --user status nvidia-ollama-bridge"
}

# ── configure-memory ─────────────────────────────────────────────────────────
cmd_configure_memory() {
  if [ ! -f "$OPENCLAW_JSON" ]; then
    fail "openclaw.json not found at $OPENCLAW_JSON"
    info "Set OPENCLAW_CONFIG env var if it's elsewhere."
    return 1
  fi

  local backup="${OPENCLAW_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$OPENCLAW_JSON" "$backup"
  ok "Backed up openclaw.json → $backup"

  node --input-type=module <<EOF
import { readFileSync, writeFileSync } from 'fs';

const path = '${OPENCLAW_JSON}';
const cfg = JSON.parse(readFileSync(path, 'utf8'));

cfg.plugins ??= {};
cfg.plugins.allow ??= [];
if (!cfg.plugins.allow.includes('memory-lancedb-pro')) {
  cfg.plugins.allow.push('memory-lancedb-pro');
}
cfg.plugins.slots ??= {};
cfg.plugins.slots.memory = 'memory-lancedb-pro';
cfg.plugins.entries ??= {};
cfg.plugins.entries['memory-lancedb-pro'] = {
  enabled: true,
  config: {
    llm: {
      baseURL: 'http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1',
      model: '${BRIDGE_MODEL}',
      apiKey: 'nvidia-bridge',
    },
    embedding: {
      baseURL: '${OLLAMA_BASE}/v1',
      model: '${EMBED_MODEL}',
      dimensions: 768,
    },
  },
};

writeFileSync(path, JSON.stringify(cfg, null, 2));
console.log('openclaw.json updated');
EOF

  ok "memory-lancedb-pro wired to nvidia-ollama-bridge"
}

# ── restart openclaw ─────────────────────────────────────────────────────────
cmd_restart_openclaw() {
  if systemctl --user is-active --quiet openclaw 2>/dev/null; then
    systemctl --user restart openclaw
    ok "OpenClaw restarted"
  else
    warn "OpenClaw service not running — skipping restart"
  fi
}

# ── check ────────────────────────────────────────────────────────────────────
cmd_check() {
  local PASS=0 WARN=0 FAIL=0
  local BASE="http://${BRIDGE_HOST}:${BRIDGE_PORT}"

  echo "Checking nvidia-ollama-bridge setup…"
  echo

  # Service
  if systemctl --user is-active --quiet nvidia-ollama-bridge 2>/dev/null; then
    ok "systemd service: active"; ((PASS++))
  else
    warn "systemd service: not running (may be started manually)"; ((WARN++))
  fi

  # Bridge HTTP
  if curl -sf "$BASE/" &>/dev/null; then
    ok "bridge HTTP: reachable at $BASE"; ((PASS++))
  else
    fail "bridge HTTP: not reachable at $BASE"; ((FAIL++))
    info "Start with: node $REPO_DIR/nvidia-bridge.mjs"
  fi

  # Ollama embeddings
  if curl -sf "${OLLAMA_BASE}/api/tags" &>/dev/null; then
    if curl -sf "${OLLAMA_BASE}/api/tags" | grep -q "$EMBED_MODEL" 2>/dev/null; then
      ok "Ollama embed model: $EMBED_MODEL found"; ((PASS++))
    else
      warn "Ollama running but $EMBED_MODEL not found — run: ollama pull $EMBED_MODEL"; ((WARN++))
    fi
  else
    warn "Ollama not reachable at $OLLAMA_BASE (embeddings unavailable)"; ((WARN++))
  fi

  # openclaw.json
  if [ -f "$OPENCLAW_JSON" ]; then
    if node -e "const c=require('$OPENCLAW_JSON');process.exit(c?.plugins?.entries?.['memory-lancedb-pro']?.enabled ? 0 : 1)" 2>/dev/null || \
       node --input-type=module -e "import c from '${OPENCLAW_JSON}' assert {type:'json'};process.exit(c?.plugins?.entries?.['memory-lancedb-pro']?.enabled ? 0:1)" 2>/dev/null; then
      ok "openclaw.json: memory-lancedb-pro enabled"; ((PASS++))
    else
      warn "openclaw.json exists but memory-lancedb-pro not configured"; ((WARN++))
      info "Run: bash $0 configure-memory"
    fi
  else
    warn "openclaw.json not found at $OPENCLAW_JSON"; ((WARN++))
  fi

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " ${green}${PASS} pass${reset}  ${yellow}${WARN} warn${reset}  ${red}${FAIL} fail${reset}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [ $FAIL -eq 0 ]
}

# ── all ───────────────────────────────────────────────────────────────────────
cmd_all() {
  cmd_install
  cmd_configure_memory
  cmd_restart_openclaw
  cmd_check
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-all}" in
  all)               cmd_all ;;
  install)           cmd_install ;;
  configure-memory)  cmd_configure_memory ;;
  restart-openclaw)  cmd_restart_openclaw ;;
  check)             cmd_check ;;
  *)
    echo "Usage: $0 {all|install|configure-memory|restart-openclaw|check}"
    exit 1
    ;;
esac
