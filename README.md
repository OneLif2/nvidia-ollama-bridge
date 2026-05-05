# nvidia-ollama-bridge

Single-file Node.js proxy that exposes **NVIDIA NIM** models through both
**Ollama-compatible** and **OpenAI-compatible** local HTTP endpoints.

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

## Phase 1 — Terminal Chat

### Option A: Built-in chat mode (no Ollama needed)

```bash
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
node nvidia-bridge.mjs
```

**Step 2 — In a new terminal, run Ollama pointed at the bridge**

```bash
OLLAMA_HOST=http://127.0.0.1:11545 ollama run gemma4:latest
```

You'll get a normal Ollama chat prompt, but all inference goes through NVIDIA NIM.

> **Why `OLLAMA_HOST`?** Without it, Ollama looks for a local model on its own
> server (port `11434`) and ignores the bridge entirely.

### Option C: Start as a background service

```bash
# Install systemd service
bash scripts/openclaw-fast-setup.sh install

# Check status
systemctl --user status nvidia-ollama-bridge

# View logs
journalctl --user -u nvidia-ollama-bridge -f
```

---

## Phase 2 — Testing

```bash
# Bridge must be running first
bash scripts/test-bridge.sh
# or
npm test
```

Tests cover:
- Health endpoint
- Ollama model list (`/api/tags`)
- OpenAI model list (`/v1/models`)
- OpenAI streaming chat
- OpenAI non-streaming chat
- Ollama `/api/chat`
- Ollama `/api/generate`
- Multi-turn conversation (memory)

---

## Phase 3 — OpenClaw Integration

One command wires everything up:

```bash
npm run openclaw:setup
# or
bash scripts/openclaw-fast-setup.sh all
```

This will:
1. Install + enable the systemd user service
2. Configure `memory-lancedb-pro` to use the bridge as its LLM backend
3. Restart OpenClaw

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
    api_key="nvidia-bridge",  # value doesn't matter
)

stream = client.chat.completions.create(
    model="gemma4:latest",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

### JavaScript (OpenAI SDK)

```js
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:11545/v1",
  apiKey: "nvidia-bridge",
});

const stream = await client.chat.completions.create({
  model: "gemma4:latest",
  messages: [{ role: "user", content: "Hello!" }],
  stream: true,
});

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0]?.delta?.content ?? "");
}
```

---

## HTTP endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check — returns `{"status":"ok"}` |
| GET | `/version` | Bridge version |
| GET | `/v1/models` | OpenAI-format model list |
| POST | `/v1/chat/completions` | OpenAI chat completions |
| GET | `/api/tags` | Ollama-format model list |
| GET | `/api/ps` | Ollama running models |
| POST | `/api/chat` | Ollama chat (NDJSON stream) |
| POST | `/api/generate` | Ollama generate |

---

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `NVIDIA_API_KEY` | (bundled key) | NVIDIA NIM bearer token |
| `NVIDIA_BRIDGE_HOST` | `127.0.0.1` | Listen address |
| `NVIDIA_BRIDGE_PORT` | `11545` | Listen port |
| `NVIDIA_MODEL` | `google/gemma-4-31b-it` | Default model |
| `NVIDIA_BASE_URL` | `https://integrate.api.nvidia.com/v1` | NIM API base |
| `NVIDIA_THINKING` | `0` | Set `1` for chain-of-thought mode |

Persistent overrides: `~/.config/nvidia-ollama-bridge/env` (auto-loaded by systemd).

---

## Supported model aliases

All of these resolve to `google/gemma-4-31b-it`:

- `gemma4:latest`
- `gemma4`
- `gemma-4-31b-it`
- `google/gemma-4-31b-it`
- `nvidia/gemma-4-31b-it`

To use a different NVIDIA NIM model, pass its full name directly:

```bash
NVIDIA_MODEL=deepseek-ai/deepseek-r1 node nvidia-bridge.mjs
```

---

## File layout

```
nvidia-ollama-bridge/
├── goal.md                                ← Project goals & phases
├── README.md                              ← This file
├── package.json
├── nvidia-bridge.mjs                      ← Single-file bridge (zero deps)
├── .gitignore
├── systemd/
│   └── nvidia-ollama-bridge.service       ← systemd user service
├── scripts/
│   ├── test-bridge.sh                     ← Phase 2 automated tests
│   └── openclaw-fast-setup.sh             ← Phase 3 OpenClaw wiring
└── skills/
    └── nvidia-ollama-bridge/
        ├── SKILL.md                       ← OpenClaw skill doc
        ├── skill.json
        └── _meta.json
```

---

## Troubleshooting

**429 Too Many Requests** — NVIDIA NIM rate-limits to ~40 req/min. Wait 90 s.

**401 Unauthorized** — Regenerate your API key at <https://build.nvidia.com> and
set `NVIDIA_API_KEY`.

**Ollama CLI not connecting** — Always set `OLLAMA_HOST=http://127.0.0.1:11545`
before running `ollama run`.

**Bridge port in use** — Change with `NVIDIA_BRIDGE_PORT=11546 node nvidia-bridge.mjs`.
