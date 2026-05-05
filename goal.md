# nvidia-ollama-bridge — Goal

## Overview

A single-file local HTTP proxy that bridges NVIDIA NIM (free API) models into both
OpenAI-compatible and Ollama-compatible local endpoints.  No OAuth — just an API key.

## Background

NVIDIA opened its NIM inference microservices to the public at no cost:
- 80+ production-grade models (DeepSeek, Gemma, Kimi, GLM, etc.)
- Zero credit-card / trial restrictions
- Rate limit: ~40 req/min (≈1 request per 1.5 s)
- Research & prototype use only (not for commercial production)
- 100% OpenAI-compatible — only the base URL and key need to change

Target model for Phase 1: **google/gemma-4-31b-it**
API endpoint: `https://integrate.api.nvidia.com/v1`

---

## Phase 1 — Terminal Chat via Ollama

**Goal:** Expose the NVIDIA NIM API as a local Ollama-compatible server so any
user can `ollama run gemma4:latest` (or equivalent) and get a streaming chat
session in the terminal.

Deliverables:
- `nvidia-bridge.mjs` — single Node.js file, zero npm dependencies
- Listens on `127.0.0.1:11545`
- Accepts both Ollama (`/api/chat`, `/api/generate`) and OpenAI (`/v1/chat/completions`) requests
- Streams tokens back in the correct format for each client
- Built-in `--chat` flag for direct terminal chat without needing Ollama installed
- Systemd user service unit for background operation
- API key stored in env var `NVIDIA_API_KEY` (default provided for quick start)

---

## Phase 2 — LLM Testing

**Goal:** Validate model quality and bridge correctness.

Deliverables:
- `scripts/test-bridge.sh` — automated test suite
  - Health check (bridge responds)
  - Streaming response (SSE tokens arrive)
  - Non-streaming response (JSON complete)
  - Ollama `/api/chat` endpoint
  - Ollama `/api/generate` endpoint
  - Multi-turn conversation (history preserved)
  - Thinking mode (`enable_thinking: true`)
- Pass/Warn/Fail colour-coded summary

---

## Phase 3 — OpenClaw Integration

**Goal:** Let the OpenClaw agent runtime use NVIDIA NIM as its LLM backend,
including powering `memory-lancedb-pro` for long-term memory.

Deliverables:
- `scripts/openclaw-fast-setup.sh` — one-command wiring:
  1. Install + enable systemd service
  2. Patch `~/.openclaw/openclaw.json` to point LLM at the bridge
  3. Configure `memory-lancedb-pro` plugin (LLM = bridge, embeddings = Ollama)
  4. Restart OpenClaw
- `skills/nvidia-ollama-bridge/` — OpenClaw skill definition
  - `SKILL.md` — human-readable usage guide
  - `skill.json` — machine-readable metadata
  - `_meta.json` — version info

---

## Non-Goals

- No support for image / audio modalities in Phase 1
- No local GPU inference (that is Ollama's job)
- No commercial deployment

---

## Success Criteria

| Phase | Criteria |
|-------|----------|
| 1 | `node nvidia-bridge.mjs --chat` opens a working streaming chat session |
| 1 | `ollama run gemma4:latest` works when bridge is running |
| 2 | All automated tests pass or warn (no hard failures) |
| 3 | OpenClaw uses NVIDIA LLM for every turn; memory-lancedb-pro recalls facts |
