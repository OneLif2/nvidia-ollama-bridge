#!/usr/bin/env bash
# openclaw-fast-setup.sh — Setup NVIDIA NIM bridge for OpenClaw and/or Ollama
#
# Usage:
#   bash openclaw-fast-setup.sh all                # Ollama bridge + OpenClaw
#   bash openclaw-fast-setup.sh install            # Ollama bridge (systemd service)
#   bash openclaw-fast-setup.sh configure-openclaw # OpenClaw direct NVIDIA config
#   bash openclaw-fast-setup.sh configure-memory   # memory-lancedb-pro wiring
#   bash openclaw-fast-setup.sh restart-openclaw   # restart OpenClaw only
#   bash openclaw-fast-setup.sh check              # health checks

set -euo pipefail

BRIDGE_HOST="${NVIDIA_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${NVIDIA_BRIDGE_PORT:-11545}"
BRIDGE_MODEL="${NVIDIA_MODEL:-google/gemma-4-31b-it}"
NIM_BASE_URL="https://integrate.api.nvidia.com/v1"
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

# ── Resolve NVIDIA API key ────────────────────────────────────────────────────
# Reads from gemma-4-31b-it.py first, then falls back to env var.
resolve_api_key() {
  local py_file="$REPO_DIR/gemma-4-31b-it.py"
  local key=""

  if [ -f "$py_file" ]; then
    # Extract first nvapi-... value from the file
    key=$(grep -o 'nvapi-[A-Za-z0-9_-]*' "$py_file" | head -1)
    if [ -n "$key" ] && [ "$key" != "nvapi-YOUR-KEY-HERE" ]; then
      echo "$key"
      return 0
    fi
  fi

  # Fall back to environment variable
  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    echo "$NVIDIA_API_KEY"
    return 0
  fi

  fail "No NVIDIA API key found."
  info "Create gemma-4-31b-it.py with your key (see gemma-4-31b-it.template.py)"
  info "Or set:  export NVIDIA_API_KEY=nvapi-..."
  return 1
}

# ── install (Ollama bridge via systemd) ──────────────────────────────────────
cmd_install() {
  local api_key
  api_key=$(resolve_api_key)
  export NVIDIA_API_KEY="$api_key"
  ok "API key loaded"

  echo "Installing systemd user service…"
  local svc_src="$REPO_DIR/systemd/nvidia-ollama-bridge.service"
  local svc_dir="$HOME/.config/systemd/user"
  local svc_dst="$svc_dir/nvidia-ollama-bridge.service"

  mkdir -p "$svc_dir"
  sed "s|%REPO_DIR%|$REPO_DIR|g" "$svc_src" > "$svc_dst"

  # Write API key to env file so systemd service picks it up
  local env_dir="$HOME/.config/nvidia-ollama-bridge"
  mkdir -p "$env_dir"
  echo "NVIDIA_API_KEY=$api_key" > "$env_dir/env"
  ok "API key saved to $env_dir/env"

  systemctl --user daemon-reload
  systemctl --user enable --now nvidia-ollama-bridge.service
  ok "Service enabled and started"
  info "Status: systemctl --user status nvidia-ollama-bridge"
  info "Ollama: OLLAMA_HOST=http://127.0.0.1:${BRIDGE_PORT} ollama run gemma4:latest"
}

# ── configure-openclaw (direct NVIDIA API — no bridge needed) ─────────────────
cmd_configure_openclaw() {
  local api_key
  api_key=$(resolve_api_key)
  ok "API key loaded"

  if [ ! -f "$OPENCLAW_JSON" ]; then
    fail "openclaw.json not found at $OPENCLAW_JSON"
    info "Set OPENCLAW_CONFIG env var if it's elsewhere."
    return 1
  fi

  local backup="${OPENCLAW_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$OPENCLAW_JSON" "$backup"
  ok "Backed up openclaw.json → $(basename "$backup")"

  node --input-type=module <<EOF
import { readFileSync, writeFileSync } from 'fs';

const path   = '${OPENCLAW_JSON}';
const nimUrl = '${NIM_BASE_URL}';
const model  = '${BRIDGE_MODEL}';
const ref    = 'nvidia/' + model;

const cfg = JSON.parse(readFileSync(path, 'utf8'));

// Register NVIDIA as a direct provider
cfg.models ??= {};
cfg.models.providers ??= {};
cfg.models.providers.nvidia = {
  baseUrl: nimUrl,
  api: 'openai-completions',
  models: [{ id: model, contextWindow: 131072, maxTokens: 16384 }],
};

// Add to models allowlist
cfg.agents ??= {};
cfg.agents.defaults ??= {};
cfg.agents.defaults.models ??= {};
cfg.agents.defaults.models[ref] = {};

// Add to defaults fallbacks (never touch primary)
cfg.agents.defaults.model ??= {};
cfg.agents.defaults.model.fallbacks ??= [];
if (!cfg.agents.defaults.model.fallbacks.includes(ref)) {
  cfg.agents.defaults.model.fallbacks.push(ref);
}

// Add to main agent fallbacks
for (const agent of (cfg.agents?.list ?? [])) {
  if (agent.id === 'main') {
    agent.model ??= {};
    agent.model.fallbacks ??= [];
    if (!agent.model.fallbacks.includes(ref)) {
      agent.model.fallbacks.push(ref);
    }
  }
}

writeFileSync(path, JSON.stringify(cfg, null, 2));
console.log('openclaw.json updated — model: ' + ref);
EOF

  ok "openclaw.json configured"
  info "Model ref: nvidia/${BRIDGE_MODEL}"
  info "Default model is unchanged"

  # Run openclaw onboard if available
  if command -v openclaw &>/dev/null; then
    info "Running openclaw onboard for NVIDIA…"
    NVIDIA_API_KEY="$api_key" openclaw onboard --auth-choice nvidia-api-key && \
      ok "openclaw onboard completed" || \
      warn "openclaw onboard returned an error (config still applied)"
  else
    warn "openclaw CLI not in PATH — run manually:"
    info "  NVIDIA_API_KEY=$api_key openclaw onboard --auth-choice nvidia-api-key"
  fi

  cmd_restart_openclaw
}

# ── configure-memory (memory-lancedb-pro → bridge LLM) ───────────────────────
cmd_configure_memory() {
  if [ ! -f "$OPENCLAW_JSON" ]; then
    fail "openclaw.json not found at $OPENCLAW_JSON"
    return 1
  fi

  local backup="${OPENCLAW_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$OPENCLAW_JSON" "$backup"
  ok "Backed up openclaw.json → $(basename "$backup")"

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
    info "Start OpenClaw and the model will be available"
  fi
}

# ── check ────────────────────────────────────────────────────────────────────
cmd_check() {
  local PASS=0 WARN=0 FAIL=0
  local BASE="http://${BRIDGE_HOST}:${BRIDGE_PORT}"

  echo "Checking nvidia-ollama-bridge setup…"
  echo

  # API key
  if resolve_api_key &>/dev/null; then
    ok "API key: found"; ((PASS++))
  else
    fail "API key: not found — create gemma-4-31b-it.py from template"; ((FAIL++))
  fi

  # Ollama bridge service
  if systemctl --user is-active --quiet nvidia-ollama-bridge 2>/dev/null; then
    ok "systemd service: active"; ((PASS++))
  else
    warn "systemd service: not running (may be started manually)"; ((WARN++))
  fi

  # Bridge HTTP
  if wget -qO- "$BASE/" &>/dev/null 2>&1; then
    ok "bridge HTTP: reachable at $BASE"; ((PASS++))
  else
    warn "bridge HTTP: not reachable at $BASE"; ((WARN++))
    info "Start with: node $REPO_DIR/nvidia-bridge.mjs"
  fi

  # Ollama embeddings
  if wget -qO- "${OLLAMA_BASE}/api/tags" &>/dev/null 2>&1; then
    if wget -qO- "${OLLAMA_BASE}/api/tags" 2>/dev/null | grep -q "$EMBED_MODEL"; then
      ok "Ollama embed model: $EMBED_MODEL found"; ((PASS++))
    else
      warn "Ollama running but $EMBED_MODEL not found — run: ollama pull $EMBED_MODEL"; ((WARN++))
    fi
  else
    warn "Ollama not reachable at $OLLAMA_BASE"; ((WARN++))
  fi

  # openclaw.json — nvidia provider
  if [ -f "$OPENCLAW_JSON" ]; then
    if node --input-type=module -e "
import { readFileSync } from 'fs';
const c = JSON.parse(readFileSync('${OPENCLAW_JSON}', 'utf8'));
process.exit(c?.models?.providers?.nvidia ? 0 : 1);
" 2>/dev/null; then
      ok "openclaw.json: nvidia provider configured"; ((PASS++))
    else
      warn "openclaw.json: nvidia provider not configured"; ((WARN++))
      info "Run: bash $0 configure-openclaw"
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
  cmd_configure_openclaw
  cmd_restart_openclaw
  cmd_check
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-all}" in
  all)                cmd_all ;;
  install)            cmd_install ;;
  configure-openclaw) cmd_configure_openclaw ;;
  configure-memory)   cmd_configure_memory ;;
  restart-openclaw)   cmd_restart_openclaw ;;
  check)              cmd_check ;;
  *)
    echo "Usage: $0 {all|install|configure-openclaw|configure-memory|restart-openclaw|check}"
    exit 1
    ;;
esac
