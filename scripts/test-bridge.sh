#!/usr/bin/env bash
# test-bridge.sh — Phase 2 automated test suite for nvidia-ollama-bridge

set -euo pipefail

HOST="${NVIDIA_BRIDGE_HOST:-127.0.0.1}"
PORT="${NVIDIA_BRIDGE_PORT:-11545}"
BASE="http://${HOST}:${PORT}"

PASS=0; WARN=0; FAIL=0

green="\033[0;32m"; yellow="\033[1;33m"; red="\033[0;31m"; reset="\033[0m"

ok()   { echo -e "${green}✓ PASS${reset}  $*"; ((PASS++)); }
warn() { echo -e "${yellow}⚠ WARN${reset}  $*"; ((WARN++)); }
fail() { echo -e "${red}✗ FAIL${reset}  $*"; ((FAIL++)); }

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then ok "$label"; else fail "$label"; fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " nvidia-ollama-bridge test suite"
echo " target: $BASE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Test 1: health check ────────────────────────────────────────────────────
echo
echo "[1] Health check"
resp=$(curl -sf "${BASE}/" 2>&1) || { fail "bridge not reachable at ${BASE}/"; echo "  → Start with: node nvidia-bridge.mjs"; FAIL=$((FAIL)); echo; }
if echo "$resp" | grep -q '"status"'; then
  ok "GET / returned JSON with status"
else
  warn "GET / responded but no status field: $resp"
fi

# ── Test 2: model list (Ollama) ─────────────────────────────────────────────
echo
echo "[2] Ollama model list"
resp=$(curl -sf "${BASE}/api/tags" 2>&1) || { fail "/api/tags not reachable"; }
if echo "$resp" | grep -q '"models"'; then
  ok "/api/tags returned model list"
  model_name=$(echo "$resp" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const m=JSON.parse(d).models[0]?.name||'none';console.log(m);})" 2>/dev/null || echo "unknown")
  echo "  → first model: $model_name"
else
  fail "/api/tags no models field"
fi

# ── Test 3: model list (OpenAI) ─────────────────────────────────────────────
echo
echo "[3] OpenAI model list"
resp=$(curl -sf "${BASE}/v1/models" 2>&1) || { fail "/v1/models not reachable"; }
if echo "$resp" | grep -q '"data"'; then
  ok "/v1/models returned model list"
else
  fail "/v1/models no data field"
fi

# ── Test 4: Ollama compatibility metadata ───────────────────────────────────
echo
echo "[4] Ollama compatibility metadata"
resp=$(curl -sf -X POST "${BASE}/api/show" \
  -H "Content-Type: application/json" \
  -d '{"name":"gemma4:latest"}' 2>&1) || { fail "/api/show request failed"; }
if echo "$resp" | grep -q '"details"'; then
  ok "/api/show returned model metadata"
else
  fail "/api/show no details field"
fi

resp=$(curl -sf -X POST "${BASE}/api/pull" \
  -H "Content-Type: application/json" \
  -d '{"name":"gemma4:latest"}' 2>&1) || { fail "/api/pull request failed"; }
if echo "$resp" | grep -q '"success"'; then
  ok "/api/pull returned compatibility success"
else
  fail "/api/pull no success status"
fi

# ── Test 5: streaming chat (OpenAI format) ──────────────────────────────────
echo
echo "[5] OpenAI streaming chat"
resp=$(curl -sf -X POST "${BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Reply with just the word HELLO"}],"stream":true,"max_tokens":20}' \
  --max-time 30 2>&1) || { fail "streaming request failed"; }

if echo "$resp" | grep -q "data:"; then
  ok "streaming response received SSE data lines"
elif echo "$resp" | grep -qi "rate limit\|429"; then
  warn "rate-limited by NVIDIA (try again in 90s)"
elif echo "$resp" | grep -qi "401\|unauthorized\|invalid.*key"; then
  fail "authentication error — check NVIDIA_API_KEY"
else
  warn "unexpected streaming response: ${resp:0:200}"
fi

# ── Test 6: non-streaming chat (OpenAI format) ──────────────────────────────
echo
echo "[6] OpenAI non-streaming chat"
resp=$(curl -sf -X POST "${BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Reply with just the word HELLO"}],"stream":false,"max_tokens":20}' \
  --max-time 30 2>&1) || { fail "non-streaming request failed"; }

if echo "$resp" | grep -q '"choices"'; then
  ok "non-streaming response has choices"
elif echo "$resp" | grep -qi "rate limit\|429"; then
  warn "rate-limited by NVIDIA"
else
  warn "unexpected response: ${resp:0:200}"
fi

# ── Test 7: Ollama /api/chat ─────────────────────────────────────────────────
echo
echo "[7] Ollama /api/chat (streaming)"
resp=$(curl -sf -X POST "${BASE}/api/chat" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Say HELLO"}],"stream":true}' \
  --max-time 30 2>&1) || { fail "/api/chat request failed"; }

if echo "$resp" | grep -q '"message"'; then
  ok "/api/chat returned Ollama NDJSON chunks"
elif echo "$resp" | grep -qi "rate limit\|429"; then
  warn "rate-limited by NVIDIA"
else
  warn "unexpected /api/chat response: ${resp:0:200}"
fi

# ── Test 8: Ollama /api/generate ────────────────────────────────────────────
echo
echo "[8] Ollama /api/generate"
resp=$(curl -sf -X POST "${BASE}/api/generate" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","prompt":"Say HELLO","stream":false}' \
  --max-time 30 2>&1) || { fail "/api/generate request failed"; }

if echo "$resp" | grep -q '"response"'; then
  ok "/api/generate returned response field"
elif echo "$resp" | grep -qi "rate limit\|429"; then
  warn "rate-limited by NVIDIA"
else
  warn "unexpected /api/generate response: ${resp:0:200}"
fi

# ── Test 9: multi-turn conversation ─────────────────────────────────────────
echo
echo "[9] Multi-turn conversation"
resp=$(curl -sf -X POST "${BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gemma4:latest",
    "messages":[
      {"role":"user","content":"My name is TestUser."},
      {"role":"assistant","content":"Hello TestUser!"},
      {"role":"user","content":"What is my name?"}
    ],
    "stream":false,"max_tokens":50
  }' --max-time 30 2>&1) || { fail "multi-turn request failed"; }

if echo "$resp" | grep -qi "TestUser\|test user"; then
  ok "model recalled name from prior turn"
elif echo "$resp" | grep -q '"choices"'; then
  warn "multi-turn responded but name not found in reply (model may have paraphrased)"
elif echo "$resp" | grep -qi "rate limit\|429"; then
  warn "rate-limited by NVIDIA"
else
  warn "unexpected multi-turn response: ${resp:0:200}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e " Results: ${green}${PASS} pass${reset}  ${yellow}${WARN} warn${reset}  ${red}${FAIL} fail${reset}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ $FAIL -eq 0 ] && exit 0 || exit 1
