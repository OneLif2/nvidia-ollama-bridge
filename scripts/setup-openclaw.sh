#!/usr/bin/env bash
# setup-openclaw.sh — Configure OpenClaw to call NVIDIA NIM directly (no bridge)
#
# Reads the NVIDIA API key, registers nvidia/google/gemma-4-31b-it as a
# selectable + fallback model in OpenClaw, runs onboard, validates config, and
# restarts the gateway.
#
# Usage:
#   bash scripts/setup-openclaw.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PY_FILE="$REPO_DIR/gemma-4-31b-it.py"
ENV_FILE="$HOME/.config/nvidia-ollama-bridge/env"

OPENCLAW_JSON="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
NIM_BASE_URL="https://integrate.api.nvidia.com/v1"
MODEL_ID="${NVIDIA_MODEL:-google/gemma-4-31b-it}"
MODEL_NAME="${NVIDIA_MODEL_NAME:-Google Gemma 4 31B Instruct}"
MODEL_REF="nvidia/${MODEL_ID}"

green="\033[0;32m"; yellow="\033[1;33m"; red="\033[0;31m"; reset="\033[0m"
ok()   { echo -e "${green}✓${reset} $*"; }
warn() { echo -e "${yellow}⚠${reset} $*"; }
fail() { echo -e "${red}✗${reset} $*"; }
info() { echo -e "  $*"; }

resolve_api_key() {
  local key=""

  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    echo "$NVIDIA_API_KEY"
    return 0
  fi

  if [ -f "$ENV_FILE" ]; then
    key=$(grep -E '^NVIDIA_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | sed -E 's/^["'\'']?(.*?)["'\'']?$/\1/')
    if [ -n "$key" ]; then
      echo "$key"
      return 0
    fi
  fi

  if [ -f "$PY_FILE" ]; then
    key=$(grep -o 'nvapi-[A-Za-z0-9_-]*' "$PY_FILE" | head -1)
    if [ -n "$key" ] && [ "$key" != "nvapi-YOUR-KEY-HERE" ]; then
      echo "$key"
      return 0
    fi
  fi

  return 1
}

restore_backup() {
  warn "Restoring backup: $BACKUP"
  cp "$BACKUP" "$OPENCLAW_JSON"
}

wait_for_gateway() {
  local attempts=20
  local i
  for ((i = 1; i <= attempts; i++)); do
    if openclaw gateway status 2>/dev/null | grep -q "Connectivity probe: ok"; then
      ok "OpenClaw gateway is ready"
      return 0
    fi
    sleep 2
  done
  warn "OpenClaw restarted, but readiness probe did not pass yet"
  info "Check: openclaw gateway status"
  info "Logs : openclaw logs --follow"
  return 0
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " setup-openclaw — direct NVIDIA NIM in OpenClaw"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Prerequisites
command -v node &>/dev/null || { fail "node not found"; exit 1; }
ok "node $(node --version) found"

# Extract API key
API_KEY=$(resolve_api_key) || {
  fail "No valid NVIDIA API key found"
  info "Use one of:"
  info "  export NVIDIA_API_KEY=nvapi-..."
  info "  echo NVIDIA_API_KEY=nvapi-... > ~/.config/nvidia-ollama-bridge/env"
  info "  cp gemma-4-31b-it.template.py gemma-4-31b-it.py  (then edit)"
  exit 1
}
ok "API key loaded"

# openclaw.json
if [ ! -f "$OPENCLAW_JSON" ]; then
  fail "openclaw.json not found at $OPENCLAW_JSON"
  info "Set OPENCLAW_CONFIG env var if it's elsewhere"
  exit 1
fi

BACKUP="${OPENCLAW_JSON}.bak.gemma-$(date +%Y%m%d%H%M%S)"
cp "$OPENCLAW_JSON" "$BACKUP"
ok "Backed up openclaw.json → $(basename "$BACKUP")"

# Patch openclaw.json
OPENCLAW_JSON="$OPENCLAW_JSON" NIM_BASE_URL="$NIM_BASE_URL" MODEL_ID="$MODEL_ID" MODEL_NAME="$MODEL_NAME" node --input-type=module <<'EOF'
import { readFileSync, writeFileSync } from 'fs';

const path  = process.env.OPENCLAW_JSON;
const url   = process.env.NIM_BASE_URL;
const model = process.env.MODEL_ID;
const name  = process.env.MODEL_NAME;
const ref   = 'nvidia/' + model;

const cfg = JSON.parse(readFileSync(path, 'utf8'));

// Register NVIDIA as a direct provider
cfg.models ??= {};
cfg.models.providers ??= {};
cfg.models.providers.nvidia ??= {};
cfg.models.providers.nvidia.baseUrl = url;
cfg.models.providers.nvidia.api = 'openai-completions';
cfg.models.providers.nvidia.models ??= [];
const modelEntry = { id: model, name, contextWindow: 131072, maxTokens: 16384 };
const existing = cfg.models.providers.nvidia.models.find((entry) => entry?.id === model);
if (existing) Object.assign(existing, modelEntry);
else cfg.models.providers.nvidia.models.push(modelEntry);

// Add to models allowlist
cfg.agents ??= {};
cfg.agents.defaults ??= {};
cfg.agents.defaults.models ??= {};
cfg.agents.defaults.models[ref] = {};

// Add to defaults fallbacks (NEVER touch primary)
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

writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
console.log('  → registered: ' + ref);
EOF

ok "openclaw.json patched"

# Validate config
if command -v openclaw &>/dev/null; then
  if openclaw config validate; then
    ok "openclaw.json is valid OpenClaw config"
  else
    fail "openclaw.json failed OpenClaw validation"
    restore_backup
    exit 1
  fi
elif node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$OPENCLAW_JSON" 2>/dev/null; then
  ok "openclaw.json is valid JSON"
else
  fail "openclaw.json is invalid JSON"
  restore_backup
  exit 1
fi

# Persist API key in env so OpenClaw can find it
ENV_DIR="$HOME/.config/nvidia-ollama-bridge"
mkdir -p "$ENV_DIR"
umask 077
printf 'NVIDIA_API_KEY=%s\n' "$API_KEY" > "$ENV_DIR/env"
chmod 600 "$ENV_DIR/env"
ok "API key saved to $ENV_DIR/env with 600 permissions"

# Add to bashrc if not already there. Source the env file instead of copying
# the secret into another file.
if ! grep -q "nvidia-ollama-bridge/env" "$HOME/.bashrc" 2>/dev/null; then
  echo "" >> "$HOME/.bashrc"
  echo "# nvidia-ollama-bridge" >> "$HOME/.bashrc"
  echo "[ -f \"\$HOME/.config/nvidia-ollama-bridge/env\" ] && . \"\$HOME/.config/nvidia-ollama-bridge/env\"" >> "$HOME/.bashrc"
  ok "Added NVIDIA env-file loader to ~/.bashrc"
else
  warn "NVIDIA env-file loader already in ~/.bashrc — not modifying"
fi

# Register API key in agent auth-profiles.json (this is what OpenClaw actually
# reads at runtime). Without this, agents fail with:
#   "No API key found for provider 'nvidia'"
AUTH_FILE="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_FILE" ]; then
  cp "$AUTH_FILE" "${AUTH_FILE}.bak.gemma-$(date +%Y%m%d%H%M%S)"
  ok "Backed up auth-profiles.json"
  if NVIDIA_KEY="$API_KEY" AUTH_FILE="$AUTH_FILE" node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'fs';
const path = process.env.AUTH_FILE;
const c = JSON.parse(readFileSync(path, 'utf8'));
c.profiles ??= {};
c.profiles['nvidia:default'] = {
  type: 'api_key',
  provider: 'nvidia',
  key: process.env.NVIDIA_KEY,
};
writeFileSync(path, JSON.stringify(c, null, 2));
console.log('  → registered nvidia:default');
NODE
  then
    chmod 600 "$AUTH_FILE"
    ok "nvidia:default registered in auth-profiles.json"
  else
    fail "Failed to write auth-profiles.json"
  fi
else
  warn "auth-profiles.json not found at $AUTH_FILE"
  info "Run interactively: openclaw onboard --auth-choice nvidia-api-key"
fi

# Run openclaw onboard
if command -v openclaw &>/dev/null; then
  echo
  info "Running openclaw onboard for NVIDIA…"
  if NVIDIA_API_KEY="$API_KEY" openclaw onboard --auth-choice nvidia-api-key 2>&1; then
    ok "openclaw onboard completed"
  else
    warn "openclaw onboard returned an error — config patch still applied"
  fi
else
  warn "openclaw CLI not in PATH — skipping onboard"
  info "Run manually after exporting NVIDIA_API_KEY:"
  info "  openclaw onboard --auth-choice nvidia-api-key"
fi

# Restart OpenClaw
if systemctl --user is-active --quiet openclaw-gateway 2>/dev/null; then
  systemctl --user restart openclaw-gateway
  ok "OpenClaw gateway restarted via systemd"
  wait_for_gateway
elif systemctl --user is-active --quiet openclaw 2>/dev/null; then
  systemctl --user restart openclaw
  ok "OpenClaw restarted via systemd"
  wait_for_gateway
elif pgrep -f "openclaw.*gateway" &>/dev/null; then
  pkill -f "openclaw.*gateway" || true
  sleep 1
  if command -v openclaw &>/dev/null; then
    set -a
    . "$ENV_DIR/env"
    set +a
    nohup openclaw gateway --port 18789 > /tmp/openclaw-restart.log 2>&1 &
    sleep 2
    ok "OpenClaw restarted"
    wait_for_gateway
  fi
else
  warn "OpenClaw not running — start it manually to load the new config"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "OpenClaw setup complete!"
echo
echo "  Model ref:  ${MODEL_REF}"
echo "  Status   :  selectable + last-resort fallback"
echo "  Default  :  unchanged"
echo
if command -v openclaw &>/dev/null; then
  info "Verify: openclaw models list | grep '${MODEL_REF}'"
fi
info "In OpenClaw model picker, choose:  ${MODEL_REF}"
