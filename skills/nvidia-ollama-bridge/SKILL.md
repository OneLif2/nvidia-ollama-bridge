---
name: nvidia-ollama-bridge
version: 0.2.1
description: Install and configure NVIDIA NIM (google/gemma-4-31b-it) for Ollama and/or OpenClaw
requires:
  bins: ["node", "python3"]
  optional_bins: ["ollama", "openclaw"]
emoji: "🚀"
---

# nvidia-ollama-bridge

Connect NVIDIA NIM's free LLM API (`google/gemma-4-31b-it`) to Ollama and/or
OpenClaw. NVIDIA's API is OpenAI-compatible, so no local GPU is needed for the
cloud path.

---

## Prerequisites

Before starting, verify the environment:

```bash
# Required
node --version          # must be >= 18
python3 --version       # must be >= 3.8

# Optional — only needed for the chosen install target
ollama --version        # for Ollama integration
openclaw --version      # for OpenClaw integration
```

Get a free NVIDIA NIM API key at https://build.nvidia.com/settings/api-keys
(no credit card, no trial period).

---

## Install — Recommended: Python interactive installer

The single-file installer handles everything. It asks one question and
configures whatever is needed.

```bash
cd nvidia-ollama-bridge
python3 gemma-4-31b-it.py
```

The installer will:
1. Ask for your `NVIDIA_API_KEY`
2. Ask what to install:
   - `1` — Both OpenClaw + Ollama
   - `2` — OpenClaw only
   - `3` — Ollama only
3. Generate `gemma-4-31b-it.mjs` (the bridge launcher)
4. Configure the chosen target(s)
5. Verify the setup

---

## Install — Manual: Ollama integration

### Step 1 — Set the API key

```bash
export NVIDIA_API_KEY=nvapi-your-key-here

# Persist across reboots
mkdir -p ~/.config/nvidia-ollama-bridge
echo "NVIDIA_API_KEY=nvapi-your-key-here" > ~/.config/nvidia-ollama-bridge/env
chmod 600 ~/.config/nvidia-ollama-bridge/env
```

### Step 2 — Start the bridge

```bash
cd nvidia-ollama-bridge
node nvidia-bridge.mjs
# or run in background:
nohup node nvidia-bridge.mjs > /tmp/nvidia-bridge.log 2>&1 &
```

Expected output:
```
nvidia-ollama-bridge v0.1.0 listening on http://127.0.0.1:11545
  model   : google/gemma-4-31b-it
  OpenAI  : http://127.0.0.1:11545/v1/chat/completions
  Ollama  : http://127.0.0.1:11545/api/chat
```

### Step 3 — Verify bridge is alive

```bash
wget -qO- http://127.0.0.1:11545/
# expected: {"status":"ok","model":"google/gemma-4-31b-it","version":"0.1.0"}
```

### Step 4 — Chat via Ollama CLI

```bash
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest
```

> Ollama defaults to port 11434. `OLLAMA_HOST` redirects it to the bridge on
> port 11545. Without it, Ollama tries its own local server and ignores the bridge.

Recent Ollama CLI versions may call metadata/pull endpoints before chatting.
The bridge supports `/api/show` and `/api/pull`, so this should work without a
local model download:

```bash
OLLAMA_HOST=http://127.0.0.1:11545 ollama show gemma4:latest
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest "say ok"
```

### Step 5 — Run as a background service (optional)

```bash
bash scripts/openclaw-fast-setup.sh install
systemctl --user status nvidia-ollama-bridge
```

---

## Install — Manual: OpenClaw integration

OpenClaw has a **native NVIDIA provider** — no bridge needed for this path.
OpenClaw calls NVIDIA's API directly.

### Step 1 — Set the API key

```bash
export NVIDIA_API_KEY=nvapi-your-key-here

# Persist without duplicating the secret into ~/.bashrc
mkdir -p ~/.config/nvidia-ollama-bridge
echo "NVIDIA_API_KEY=nvapi-your-key-here" > ~/.config/nvidia-ollama-bridge/env
chmod 600 ~/.config/nvidia-ollama-bridge/env
echo '[ -f "$HOME/.config/nvidia-ollama-bridge/env" ] && . "$HOME/.config/nvidia-ollama-bridge/env"' >> ~/.bashrc
```

### Step 2 — Run OpenClaw onboarding

```bash
openclaw onboard --auth-choice nvidia-api-key
```

This stores NVIDIA auth inside OpenClaw. For `google/gemma-4-31b-it`, still add
the explicit custom model entry below because it may not exist in OpenClaw's
built-in NVIDIA catalog.

### Step 3 — Register the model and add as fallback

Add the following to `~/.openclaw/openclaw.json` using your text editor or
ask an agent to patch it:

```json
{
  "models": {
    "providers": {
      "nvidia": {
        "baseUrl": "https://integrate.api.nvidia.com/v1",
        "api": "openai-completions",
        "models": [
          {
            "id": "google/gemma-4-31b-it",
            "name": "Google Gemma 4 31B Instruct",
            "contextWindow": 131072,
            "maxTokens": 16384
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "models": {
        "nvidia/google/gemma-4-31b-it": {}
      },
      "model": {
        "fallbacks": ["nvidia/google/gemma-4-31b-it"]
      }
    }
  }
}
```

> ⚠️ Do NOT change `agents.defaults.model.primary` — the default model must
> stay unchanged. Only add to the `fallbacks` array.

Important: OpenClaw requires custom provider models to include `name`. Without
it, `openclaw config validate` fails with
`models.providers.nvidia.models.0.name: Invalid input: expected string`.

Validate before restarting:

```bash
openclaw config validate
openclaw models list | grep 'nvidia/google/gemma-4-31b-it'
```

### Step 4 — Restart OpenClaw

```bash
# If running as OpenClaw gateway systemd service:
systemctl --user restart openclaw-gateway

# Older service name fallback:
systemctl --user restart openclaw

# If running manually, kill and restart:
pkill -f "openclaw.*gateway"
openclaw gateway --port 18789 &
```

### Step 5 — Verify

In OpenClaw's model picker, `nvidia/google/gemma-4-31b-it` should now appear.
Select it and send a test message:

```
What is 2+2?
```

Expected: a streaming response from gemma-4-31b-it.

CLI smoke test:

```bash
openclaw agent --agent main --model nvidia/google/gemma-4-31b-it \
  --message 'Reply with exactly: OK' --timeout 120 --json
```

Expected metadata includes `"provider": "nvidia"` and
`"model": "google/gemma-4-31b-it"`.

---

## Install — Both (OpenClaw + Ollama)

Follow **Manual: Ollama integration** Steps 1–5, then follow
**Manual: OpenClaw integration** Steps 2–5.

The bridge and the direct OpenClaw path are independent — both can run at the
same time without conflict.

---

## Automated setup script

```bash
# Full setup (both Ollama bridge + OpenClaw)
bash scripts/openclaw-fast-setup.sh all

# Ollama bridge only
bash scripts/openclaw-fast-setup.sh install

# OpenClaw config only, direct NVIDIA provider
bash scripts/setup-openclaw.sh

# Verify everything
bash scripts/openclaw-fast-setup.sh check
```

---

## Verification commands

```bash
# 1. Bridge health
wget -qO- http://127.0.0.1:11545/

# 2. Bridge model list
wget -qO- http://127.0.0.1:11545/api/tags

# 3. Test LLM call through bridge
wget -qO- --post-data='{"model":"gemma4:latest","messages":[{"role":"user","content":"Say HELLO"}],"stream":false}' \
  --header='Content-Type: application/json' \
  http://127.0.0.1:11545/v1/chat/completions

# 4. Full automated test suite
bash scripts/test-bridge.sh

# 5. OpenClaw model check
openclaw config validate
openclaw models list | grep 'nvidia/google/gemma-4-31b-it'
```

---

## Configuration reference (env vars)

| Variable | Description | Required |
|----------|-------------|----------|
| `NVIDIA_API_KEY` | Bearer token from build.nvidia.com | **Yes** |
| `NVIDIA_BRIDGE_HOST` | Bridge listen address (default: `127.0.0.1`) | No |
| `NVIDIA_BRIDGE_PORT` | Bridge listen port (default: `11545`) | No |
| `NVIDIA_MODEL` | Default model (default: `google/gemma-4-31b-it`) | No |
| `NVIDIA_THINKING` | Enable chain-of-thought: set `1` (default: `0`) | No |

Persistent env overrides: `~/.config/nvidia-ollama-bridge/env`

---

## Troubleshooting

**`NVIDIA_API_KEY` not set** — Bridge exits immediately with an error.
Run `export NVIDIA_API_KEY=nvapi-...` before starting.

**429 Too Many Requests** — NVIDIA NIM limits to ~40 req/min.
Wait 90 seconds and retry.

**401 Unauthorized** — API key is invalid or expired.
Regenerate at https://build.nvidia.com/settings/api-keys.

**Ollama CLI not connecting** — Always prefix with `OLLAMA_HOST=http://127.0.0.1:11545`.
Without it, Ollama uses its own server on port 11434.

**Bridge port 11545 in use** — Change with:
`NVIDIA_BRIDGE_PORT=11546 node nvidia-bridge.mjs`

**`nvidia/google/gemma-4-31b-it` not in OpenClaw model picker** — Restart
OpenClaw after editing `openclaw.json`. Check JSON is valid first:
`node -e "JSON.parse(require('fs').readFileSync(process.env.HOME+'/.openclaw/openclaw.json','utf8'))"`

**`Unknown model: nvidia/google/gemma-4-31b-it`** — The model ref was added to
the picker/fallbacks, but `models.providers.nvidia` is missing or the custom
model entry is incomplete. Run:

```bash
bash scripts/setup-openclaw.sh
openclaw config validate
openclaw models list | grep 'nvidia/google/gemma-4-31b-it'
```

The provider config must include:

```json
{
  "id": "google/gemma-4-31b-it",
  "name": "Google Gemma 4 31B Instruct",
  "contextWindow": 131072,
  "maxTokens": 16384
}
```

**OpenClaw 401 to NVIDIA** — Run `openclaw onboard --auth-choice nvidia-api-key`
with `NVIDIA_API_KEY` set in the environment.

**Gateway restarted but model still looks old** — Confirm the active gateway is
using the same config file:

```bash
openclaw gateway status
openclaw logs --follow
```
