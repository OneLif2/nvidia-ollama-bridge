---
name: nvidia-ollama-bridge
version: 0.1.0
description: Operate the local NVIDIA NIM Ollama bridge
requires:
  bins: ["node"]
emoji: "🚀"
---

# nvidia-ollama-bridge

Single-file proxy that exposes NVIDIA NIM models (e.g. `google/gemma-4-31b-it`)
through local Ollama-compatible and OpenAI-compatible HTTP endpoints.

## Quick start

```bash
# Terminal chat (no server needed)
node nvidia-bridge.mjs --chat

# Or start the background bridge
node nvidia-bridge.mjs
```

## OpenClaw one-command setup (Phase 3)

```bash
npm run openclaw:setup
# or
bash scripts/openclaw-fast-setup.sh all
```

This will:
1. Install + enable the systemd user service
2. Wire memory-lancedb-pro to use the bridge as its LLM
3. Restart OpenClaw

## Chat via Ollama CLI

```bash
# Requires bridge running on port 11545
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest
```

## OpenAI SDK (Python)

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:11545/v1", api_key="nvidia-bridge")
resp = client.chat.completions.create(
    model="gemma4:latest",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)
for chunk in resp:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## curl examples

```bash
# Health
curl http://127.0.0.1:11545/

# Non-streaming
curl -X POST http://127.0.0.1:11545/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Hi"}],"stream":false}'

# Streaming
curl -X POST http://127.0.0.1:11545/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Hi"}],"stream":true}'
```

## HTTP endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check |
| GET | `/v1/models` | OpenAI model list |
| POST | `/v1/chat/completions` | OpenAI chat |
| GET | `/api/tags` | Ollama model list |
| POST | `/api/chat` | Ollama chat |
| POST | `/api/generate` | Ollama generate |

## Configuration (env vars)

| Variable | Default | Description |
|----------|---------|-------------|
| `NVIDIA_API_KEY` | (bundled key) | NVIDIA NIM bearer token |
| `NVIDIA_BRIDGE_HOST` | `127.0.0.1` | Listen address |
| `NVIDIA_BRIDGE_PORT` | `11545` | Listen port |
| `NVIDIA_MODEL` | `google/gemma-4-31b-it` | Default model |
| `NVIDIA_BASE_URL` | `https://integrate.api.nvidia.com/v1` | NIM base URL |
| `NVIDIA_THINKING` | `0` | Set to `1` for chain-of-thought |

Override via `~/.config/nvidia-ollama-bridge/env` (loaded by systemd).

## Troubleshooting

**429 rate limit** — NVIDIA NIM allows ~40 req/min. Wait 90 s and retry.

**401 unauthorized** — Check `NVIDIA_API_KEY` is valid at
`https://build.nvidia.com`.

**Bridge not reachable** — Ensure `node nvidia-bridge.mjs` is running, or
`systemctl --user status nvidia-ollama-bridge`.

**Ollama CLI not connecting** — Set `OLLAMA_HOST=http://127.0.0.1:11545` before
running `ollama run`.
