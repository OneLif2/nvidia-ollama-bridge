# nvidia-ollama-bridge

Connect NVIDIA NIM's free LLM API (`google/gemma-4-31b-it`) to **Ollama** and/or
**OpenClaw** with a single setup command.

No npm install required — pure Node.js standard library.

```
┌──────────────────┐
│  Local Client    │       HTTP (OpenAI or Ollama format)
│  ollama CLI      ├──────────────────────────────────────────┐
│  OpenAI SDK      │                                          │
│  memory-lancedb  │                                          ▼
│  curl / browser  │          ┌───────────────────────────────────────┐
└──────────────────┘          │  nvidia-bridge.mjs                    │
                              │  127.0.0.1:11545                      │
                              │                                       │
                              │  • Route requests                     │
                              │  • Format conversion                  │
                              │  • Streaming SSE → NDJSON             │
                              └──────────────────────┬────────────────┘
                                                     │  HTTPS
                                                     ▼
                              ┌───────────────────────────────────────┐
                              │  NVIDIA NIM API                       │
                              │  integrate.api.nvidia.com/v1          │
                              │  model: google/gemma-4-31b-it         │
                              └───────────────────────────────────────┘
```

---

## Getting Started

### Step 1 — Get a free NVIDIA API key

Go to **https://build.nvidia.com/settings/api-keys** and create an API key.
No credit card. No trial period.

NVIDIA will show you sample code that looks like this:

```python
headers = {
  "Authorization": "Bearer nvapi-xxxxxxxxxxxxxxxxxxxx",
  ...
}
```

### Step 2 — Create `gemma-4-31b-it.py`

Copy the template and replace the placeholder with your real key:

```bash
cp gemma-4-31b-it.template.py gemma-4-31b-it.py
# edit gemma-4-31b-it.py — replace nvapi-YOUR-KEY-HERE with your real key
```

> `gemma-4-31b-it.py` is **git-ignored** — your API key never leaves your machine.

The setup script and any OpenClaw agent will automatically extract the key from
this file. You do not need to set any environment variables manually.

### Step 3 — Run setup

Choose what you want to install:

```bash
# Both OpenClaw + Ollama (recommended)
bash scripts/openclaw-fast-setup.sh all

# OpenClaw only  (direct NVIDIA API, fastest)
bash scripts/openclaw-fast-setup.sh configure-openclaw

# Ollama only  (starts bridge on port 11545)
bash scripts/openclaw-fast-setup.sh install
```

The script reads your API key from `gemma-4-31b-it.py` automatically — no extra steps.

**Or ask an OpenClaw agent:**
> "Set up nvidia-ollama-bridge. My API key is in `gemma-4-31b-it.py`."

The agent will read the file, extract the key, and configure everything.

### Step 4 — Verify

```bash
bash scripts/openclaw-fast-setup.sh check
```

---

## Ways to call this model

### Quick Call Commands

Use these commands after the bridge is running. If you installed the user
service with `scripts/openclaw-fast-setup.sh install`, the bridge should already
be listening on `127.0.0.1:11545`.

```bash
# Interactive Ollama chat
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest

# One-shot Ollama prompt
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest "say hello in one sentence"

# List models exposed by the bridge
OLLAMA_HOST=http://127.0.0.1:11545 ollama list

# Direct bridge chat without Ollama
node nvidia-bridge.mjs --chat
```

The bridge advertises `gemma4:latest` as the Ollama-friendly alias for
NVIDIA's `google/gemma-4-31b-it` model.

| Method | Command | Speed | Features |
|--------|---------|-------|----------|
| **Direct `--chat`** | `node nvidia-bridge.mjs --chat` | Fastest | Raw terminal chat |
| **Ollama CLI** | `OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest` | Fast | Ollama UX |
| **OpenClaw** | Select `nvidia/google/gemma-4-31b-it` in model picker | Full | Memory, tools, channels |

> **Which is faster?** Direct `--chat` skips all middleware — one hop to NVIDIA.
> OpenClaw adds ~100–500 ms of pre-processing (memory recall, context injection).
> The real bottleneck is NVIDIA's API (~500 ms to first token), so the difference
> is small in practice. Use `--chat` for speed; use OpenClaw for smart features.

---

## Phase 1 — Terminal Chat

### Option A: Built-in `--chat` mode (fastest, no Ollama needed)

```bash
export NVIDIA_API_KEY=nvapi-your-key-here
node nvidia-bridge.mjs --chat
```

```
nvidia-ollama-bridge chat — model: google/gemma-4-31b-it
Type your message and press Enter. Type "exit" or Ctrl-C to quit.

You: What is 2+2?
Assistant: 2 + 2 = 4 ...
```

### Option B: Via Ollama CLI

Ollama defaults to its own port `11434`. Set `OLLAMA_HOST` to redirect it to
the bridge on port `11545` instead:

**Step 1 — Start the bridge** (leave this terminal open)

```bash
export NVIDIA_API_KEY=nvapi-your-key-here
node nvidia-bridge.mjs
```

**Step 2 — In a new terminal, run Ollama pointed at the bridge**

```bash
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest
```

> **Why `OLLAMA_HOST`?** Without it, Ollama uses its own server on port `11434`
> and ignores the bridge entirely.

### Option C: Background service

```bash
bash scripts/openclaw-fast-setup.sh install

systemctl --user status nvidia-ollama-bridge
journalctl --user -u nvidia-ollama-bridge -f
```

---

## Phase 2 — Testing

```bash
bash scripts/test-bridge.sh
```

Tests cover: health, model list, streaming, non-streaming, Ollama chat,
Ollama generate, multi-turn conversation.

---

## Phase 3 — OpenClaw Integration

```bash
bash scripts/openclaw-fast-setup.sh configure-openclaw
```

This will:
1. Read your API key from `gemma-4-31b-it.py`
2. Register `nvidia/google/gemma-4-31b-it` as a selectable model in OpenClaw
3. Add it to the fallback chain (default model is **not** changed)
4. Run `openclaw onboard --auth-choice nvidia-api-key`
5. Restart OpenClaw

---

## Quick API reference

### curl — streaming

```bash
curl -X POST http://127.0.0.1:11545/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Hello!"}],"stream":true}'
```

### curl — non-streaming

```bash
curl -X POST http://127.0.0.1:11545/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:latest","messages":[{"role":"user","content":"Hello!"}],"stream":false}'
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11545/v1",
    api_key="nvidia-bridge",  # value doesn't matter for local bridge
)

stream = client.chat.completions.create(
    model="gemma4:latest",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

---

## HTTP endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check |
| GET | `/version` | Bridge version |
| GET | `/v1/models` | OpenAI-format model list |
| POST | `/v1/chat/completions` | OpenAI chat |
| GET | `/api/tags` | Ollama-format model list |
| POST | `/api/chat` | Ollama chat (NDJSON stream) |
| POST | `/api/generate` | Ollama generate |

---

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `NVIDIA_API_KEY` | **(required)** | Free key from [build.nvidia.com](https://build.nvidia.com) |
| `NVIDIA_BRIDGE_HOST` | `127.0.0.1` | Listen address |
| `NVIDIA_BRIDGE_PORT` | `11545` | Listen port |
| `NVIDIA_MODEL` | `google/gemma-4-31b-it` | Default model |
| `NVIDIA_BASE_URL` | `https://integrate.api.nvidia.com/v1` | NIM API base |
| `NVIDIA_THINKING` | `0` | Set `1` for chain-of-thought mode |

The setup script also reads the key from `gemma-4-31b-it.py` automatically —
no need to export it manually if the file exists.

---

## File layout

```
nvidia-ollama-bridge/
├── goal.md
├── README.md
├── package.json
├── nvidia-bridge.mjs                      ← Single-file bridge (zero deps)
├── gemma-4-31b-it.template.py             ← Template: copy → gemma-4-31b-it.py
├── gemma-4-31b-it.py                      ← YOUR file (git-ignored, has your key)
├── .gitignore
├── systemd/
│   └── nvidia-ollama-bridge.service
├── scripts/
│   ├── test-bridge.sh
│   └── openclaw-fast-setup.sh             ← Reads key from gemma-4-31b-it.py
└── skills/
    └── nvidia-ollama-bridge/
        ├── SKILL.md
        ├── skill.json
        └── _meta.json
```

---

## Troubleshooting

**No API key found** — Create `gemma-4-31b-it.py` from the template and add your key.

**429 Too Many Requests** — NVIDIA NIM limits ~40 req/min. Wait 90 s and retry.

**401 Unauthorized** — Key is invalid. Regenerate at <https://build.nvidia.com>.

**Ollama CLI not connecting** — Always set `OLLAMA_HOST=http://127.0.0.1:11545`
before running `ollama run`.

**Bridge port in use** — `NVIDIA_BRIDGE_PORT=11546 node nvidia-bridge.mjs`
