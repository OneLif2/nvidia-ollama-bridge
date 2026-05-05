#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# TEMPLATE — nvidia-ollama-bridge
#
# HOW TO USE:
#   1. Go to https://build.nvidia.com/settings/api-keys
#   2. Create a free API key (no credit card required)
#   3. Copy this file:
#        cp gemma-4-31b-it.template.py gemma-4-31b-it.py
#   4. Replace  nvapi-YOUR-KEY-HERE  with your real key
#   5. Run setup:
#        bash scripts/openclaw-fast-setup.sh all
#      The script reads your API key from this file automatically.
#
# gemma-4-31b-it.py is git-ignored — your key stays on your machine only.
# ─────────────────────────────────────────────────────────────────────────────

import requests, base64

invoke_url = "https://integrate.api.nvidia.com/v1/chat/completions"
stream = True

def read_b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()

headers = {
    "Authorization": "Bearer nvapi-YOUR-KEY-HERE",
    "Accept": "text/event-stream" if stream else "application/json"
}

payload = {
    "model": "google/gemma-4-31b-it",
    "messages": [{"role": "user", "content": "Hello! What can you do?"}],
    "max_tokens": 16384,
    "temperature": 1.00,
    "top_p": 0.95,
    "stream": stream,
    "chat_template_kwargs": {"enable_thinking": True},
}

response = requests.post(invoke_url, headers=headers, json=payload, stream=stream)
if stream:
    for line in response.iter_lines():
        if line:
            print(line.decode("utf-8"))
else:
    print(response.json())
