#!/usr/bin/env node
/**
 * nvidia-bridge.mjs — single-file NVIDIA NIM → Ollama/OpenAI bridge
 *
 * Listens on 127.0.0.1:11545 and proxies requests to the NVIDIA NIM API.
 * Supports both OpenAI (/v1/chat/completions) and Ollama (/api/chat, /api/generate) formats.
 *
 * Usage:
 *   node nvidia-bridge.mjs              # start HTTP bridge
 *   node nvidia-bridge.mjs --chat       # interactive terminal chat
 *
 * Env vars (all optional):
 *   NVIDIA_API_KEY      Bearer token for NVIDIA NIM
 *   NVIDIA_BRIDGE_HOST  (default: 127.0.0.1)
 *   NVIDIA_BRIDGE_PORT  (default: 11545)
 *   NVIDIA_MODEL        (default: google/gemma-4-31b-it)
 *   NVIDIA_BASE_URL     (default: https://integrate.api.nvidia.com/v1)
 *   NVIDIA_THINKING     set to "1" to enable chain-of-thought (default: 0)
 */

import http from "http";
import https from "https";
import fs from "fs";
import os from "os";
import path from "path";
import readline from "readline";

// ─── Configuration ─────────────────────────────────────────────────────────

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  const content = fs.readFileSync(filePath, "utf8");
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    const [, key, rawValue] = match;
    if (process.env[key] !== undefined) continue;
    process.env[key] = rawValue.replace(/^(['"])(.*)\1$/, "$2");
  }
}

loadEnvFile(path.join(process.cwd(), ".env"));
loadEnvFile(path.join(os.homedir(), ".config", "nvidia-ollama-bridge", "env"));

const API_KEY = process.env.NVIDIA_API_KEY;
if (!API_KEY) {
  console.error("Error: NVIDIA_API_KEY environment variable is not set.");
  console.error("Get a free key at https://build.nvidia.com then run:");
  console.error("  export NVIDIA_API_KEY=nvapi-...");
  process.exit(1);
}

const BASE_URL =
  process.env.NVIDIA_BASE_URL || "https://integrate.api.nvidia.com/v1";

const DEFAULT_MODEL =
  process.env.NVIDIA_MODEL || "google/gemma-4-31b-it";

const HOST = process.env.NVIDIA_BRIDGE_HOST || "127.0.0.1";
const PORT = parseInt(process.env.NVIDIA_BRIDGE_PORT || "11545", 10);
const ENABLE_THINKING = process.env.NVIDIA_THINKING === "1";

const VERSION = "0.1.0";

// Model aliases accepted from Ollama clients
const MODEL_ALIASES = new Set([
  "gemma4:latest",
  "gemma4",
  "gemma-4-31b-it",
  "google/gemma-4-31b-it",
  "nvidia/gemma-4-31b-it",
]);

function resolveModel(name) {
  if (!name) return DEFAULT_MODEL;
  if (MODEL_ALIASES.has(name)) return DEFAULT_MODEL;
  return name; // pass other NVIDIA model names through as-is
}

// ─── NVIDIA NIM API call ────────────────────────────────────────────────────

/**
 * Build OpenAI-compatible payload for NVIDIA NIM.
 * @param {Array}   messages   OpenAI messages array
 * @param {string}  model      resolved model name
 * @param {boolean} stream
 * @param {object}  overrides  extra payload fields
 */
function buildPayload(messages, model, stream, overrides = {}) {
  const payload = {
    model,
    messages,
    max_tokens: 16384,
    temperature: 1.0,
    top_p: 0.95,
    stream,
    ...overrides,
  };
  if (ENABLE_THINKING) {
    payload.chat_template_kwargs = { enable_thinking: true };
  }
  return payload;
}

/**
 * Call NVIDIA NIM.
 * @returns {Promise<IncomingMessage>}  raw Node.js response stream
 */
function callNvidia(payload) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${BASE_URL}/chat/completions`);
    const body = JSON.stringify(payload);

    const req = https.request(
      {
        hostname: url.hostname,
        port: url.port || 443,
        path: url.pathname + url.search,
        method: "POST",
        headers: {
          Authorization: `Bearer ${API_KEY}`,
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
          Accept: payload.stream ? "text/event-stream" : "application/json",
        },
      },
      resolve
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

// ─── Stream helpers ─────────────────────────────────────────────────────────

/** Yield SSE lines from a Node.js readable stream. */
async function* sseLines(stream) {
  let buf = "";
  for await (const chunk of stream) {
    buf += chunk.toString();
    const lines = buf.split("\n");
    buf = lines.pop(); // keep incomplete last line
    for (const line of lines) {
      yield line;
    }
  }
  if (buf.trim()) yield buf;
}

/**
 * Extract the text delta from one NVIDIA SSE data line.
 * Returns null when the stream is done.
 */
function extractDelta(line) {
  if (!line.startsWith("data: ")) return undefined; // not a data line
  const raw = line.slice(6).trim();
  if (raw === "[DONE]") return null; // end marker
  try {
    const obj = JSON.parse(raw);
    return obj.choices?.[0]?.delta?.content ?? "";
  } catch {
    return "";
  }
}

// ─── Response formatters ────────────────────────────────────────────────────

function nowISO() {
  return new Date().toISOString();
}

function makeOllamaChatChunk(content, done, model) {
  return JSON.stringify({
    model,
    created_at: nowISO(),
    message: { role: "assistant", content },
    done,
  });
}

function makeOllamaGenerateChunk(content, done, model) {
  return JSON.stringify({
    model,
    created_at: nowISO(),
    response: content,
    done,
  });
}

function makeOpenAIChunk(content, model, id) {
  return `data: ${JSON.stringify({
    id,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, delta: { content }, finish_reason: null }],
  })}\n\n`;
}

// ─── Endpoint handlers ──────────────────────────────────────────────────────

/** POST /v1/chat/completions — OpenAI-compatible passthrough with stream fix */
async function handleOpenAI(req, res, body) {
  const model = resolveModel(body.model);
  const stream = body.stream !== false;
  const payload = buildPayload(body.messages, model, stream, {
    temperature: body.temperature ?? 1.0,
    top_p: body.top_p ?? 0.95,
    max_tokens: body.max_tokens ?? 16384,
  });

  const upstream = await callNvidia(payload);

  if (stream) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    for await (const line of sseLines(upstream)) {
      if (line) res.write(line + "\n");
    }
    res.write("data: [DONE]\n\n");
    res.end();
  } else {
    let raw = "";
    for await (const chunk of upstream) raw += chunk.toString();
    res.writeHead(upstream.statusCode, { "Content-Type": "application/json" });
    res.end(raw);
  }
}

/** POST /api/chat — Ollama chat format */
async function handleOllamaChat(req, res, body) {
  const model = resolveModel(body.model);
  const stream = body.stream !== false;
  const messages = (body.messages || []).map((m) => ({
    role: m.role,
    content: typeof m.content === "string" ? m.content : JSON.stringify(m.content),
  }));

  const payload = buildPayload(messages, model, true); // always stream from nvidia
  const upstream = await callNvidia(payload);

  if (stream) {
    res.writeHead(200, { "Content-Type": "application/x-ndjson" });
    for await (const line of sseLines(upstream)) {
      const delta = extractDelta(line);
      if (delta === null) {
        res.write(makeOllamaChatChunk("", true, model) + "\n");
        break;
      }
      if (delta) res.write(makeOllamaChatChunk(delta, false, model) + "\n");
    }
    res.end();
  } else {
    let full = "";
    for await (const line of sseLines(upstream)) {
      const delta = extractDelta(line);
      if (delta === null) break;
      if (delta) full += delta;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        model,
        created_at: nowISO(),
        message: { role: "assistant", content: full },
        done: true,
      })
    );
  }
}

/** POST /api/generate — Ollama generate format */
async function handleOllamaGenerate(req, res, body) {
  const model = resolveModel(body.model);
  const stream = body.stream !== false;
  const messages = [{ role: "user", content: body.prompt || "" }];
  if (body.system) messages.unshift({ role: "system", content: body.system });

  const payload = buildPayload(messages, model, true);
  const upstream = await callNvidia(payload);

  if (stream) {
    res.writeHead(200, { "Content-Type": "application/x-ndjson" });
    for await (const line of sseLines(upstream)) {
      const delta = extractDelta(line);
      if (delta === null) {
        res.write(makeOllamaGenerateChunk("", true, model) + "\n");
        break;
      }
      if (delta) res.write(makeOllamaGenerateChunk(delta, false, model) + "\n");
    }
    res.end();
  } else {
    let full = "";
    for await (const line of sseLines(upstream)) {
      const delta = extractDelta(line);
      if (delta === null) break;
      if (delta) full += delta;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        model,
        created_at: nowISO(),
        response: full,
        done: true,
      })
    );
  }
}

// ─── Model list helpers ─────────────────────────────────────────────────────

const EXPOSED_ALIASES = [
  "gemma4:latest",
  "gemma4",
  "google/gemma-4-31b-it",
];

function ollamaTagsList() {
  return {
    models: EXPOSED_ALIASES.map((name) => ({
      name,
      model: name,
      modified_at: nowISO(),
      size: 0,
      digest: "nvidia-nim",
      details: { family: "gemma", parameter_size: "31B", quantization_level: "API" },
    })),
  };
}

function openaiModelsList() {
  return {
    object: "list",
    data: EXPOSED_ALIASES.map((id) => ({
      id,
      object: "model",
      created: Math.floor(Date.now() / 1000),
      owned_by: "nvidia-nim",
    })),
  };
}

// ─── HTTP server ─────────────────────────────────────────────────────────────

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString();
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        resolve({});
      }
    });
    req.on("error", reject);
  });
}

function jsonReply(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function cors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

async function handleRequest(req, res) {
  cors(res);

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    return res.end();
  }

  const { method, url } = req;

  try {
    // ── Health ──────────────────────────────────────────────────────────────
    if ((method === "GET" || method === "HEAD") && (url === "/" || url === "/health")) {
      return jsonReply(res, 200, { status: "ok", model: DEFAULT_MODEL, version: VERSION });
    }

    if (method === "GET" && (url === "/version" || url === "/api/version")) {
      return jsonReply(res, 200, { version: VERSION });
    }

    // ── Model lists ─────────────────────────────────────────────────────────
    if (method === "GET" && (url === "/api/tags" || url === "/api/ps")) {
      return jsonReply(res, 200, ollamaTagsList());
    }

    if (method === "GET" && url === "/v1/models") {
      return jsonReply(res, 200, openaiModelsList());
    }

    // ── Chat endpoints ───────────────────────────────────────────────────────
    if (method === "POST" && url === "/v1/chat/completions") {
      const body = await readBody(req);
      return await handleOpenAI(req, res, body);
    }

    if (method === "POST" && url === "/api/chat") {
      const body = await readBody(req);
      return await handleOllamaChat(req, res, body);
    }

    if (method === "POST" && url === "/api/generate") {
      const body = await readBody(req);
      return await handleOllamaGenerate(req, res, body);
    }

    // ── 404 ──────────────────────────────────────────────────────────────────
    jsonReply(res, 404, { error: `Not found: ${method} ${url}` });
  } catch (err) {
    console.error("[bridge error]", err.message);
    if (!res.headersSent) {
      jsonReply(res, 502, { error: err.message });
    } else {
      res.end();
    }
  }
}

// ─── Terminal chat mode ──────────────────────────────────────────────────────

async function terminalChat() {
  const history = [];
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: true,
  });

  const model = DEFAULT_MODEL;
  console.log(`\nnvidia-ollama-bridge chat — model: ${model}`);
  console.log('Type your message and press Enter. Type "exit" or Ctrl-C to quit.\n');

  const ask = () => {
    rl.question("You: ", async (input) => {
      const text = input.trim();
      if (!text) return ask();
      if (text.toLowerCase() === "exit" || text.toLowerCase() === "quit") {
        console.log("Bye!");
        rl.close();
        return;
      }

      history.push({ role: "user", content: text });
      const payload = buildPayload(history, model, true);

      process.stdout.write("Assistant: ");
      let full = "";

      try {
        const upstream = await callNvidia(payload);
        for await (const line of sseLines(upstream)) {
          const delta = extractDelta(line);
          if (delta === null) break;
          if (delta) {
            process.stdout.write(delta);
            full += delta;
          }
        }
      } catch (err) {
        process.stdout.write(`\n[Error: ${err.message}]`);
      }

      process.stdout.write("\n\n");
      history.push({ role: "assistant", content: full });
      ask();
    });
  };

  rl.on("close", () => process.exit(0));
  ask();
}

// ─── Entry point ─────────────────────────────────────────────────────────────

if (process.argv.includes("--chat")) {
  terminalChat();
} else {
  const server = http.createServer(handleRequest);
  server.listen(PORT, HOST, () => {
    console.log(`nvidia-ollama-bridge v${VERSION} listening on http://${HOST}:${PORT}`);
    console.log(`  model   : ${DEFAULT_MODEL}`);
    console.log(`  thinking: ${ENABLE_THINKING}`);
    console.log(`  OpenAI  : http://${HOST}:${PORT}/v1/chat/completions`);
    console.log(`  Ollama  : http://${HOST}:${PORT}/api/chat`);
    console.log(`  health  : http://${HOST}:${PORT}/`);
  });
}
