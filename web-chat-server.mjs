import { createHash, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const modelBaseUrl = (process.env.NEMOTRON_BASE_URL ??
  "http://workspace-nemotron-3-nano-4b.default.svc.cluster.local/v1").replace(/\/$/, "");
const modelName = process.env.NEMOTRON_MODEL ?? "nvidia-nemotron-3-nano-4b-bf16";
const toolNamespace = process.env.TOOL_NAMESPACE ?? "default";
const apiToken = process.env.API_TOKEN;
const publicDirectory = fileURLToPath(new URL("./public", import.meta.url));
const rateWindows = new Map();
let mcpClient;
let mcpReady = false;

if (!apiToken || apiToken.length < 24) {
  throw new Error("API_TOKEN must be set to at least 24 characters.");
}

const advertisedTool = {
  type: "function",
  function: {
    name: "kubernetes_pods_list",
    description: `List pods in the fixed '${toolNamespace}' Kubernetes namespace using the read-only MCP service.`,
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
};

function safeTokenEqual(candidate) {
  const expected = createHash("sha256").update(apiToken).digest();
  const actual = createHash("sha256").update(candidate).digest();
  return timingSafeEqual(expected, actual);
}

function authorized(request) {
  const header = request.headers.authorization ?? "";
  return header.startsWith("Bearer ") && safeTokenEqual(header.slice(7));
}

function clientAddress(request) {
  return request.socket.remoteAddress ?? "unknown";
}

function withinRateLimit(request) {
  const key = clientAddress(request);
  const now = Date.now();
  const current = rateWindows.get(key);
  if (!current || now - current.startedAt >= 60_000) {
    rateWindows.set(key, { startedAt: now, requests: 1 });
    return true;
  }
  current.requests += 1;
  return current.requests <= 30;
}

function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
  });
  response.end(body);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 65_536) {
      throw new Error("Request body exceeds 64 KiB.");
    }
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function validateMessages(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 20) {
    throw new Error("messages must contain between 1 and 20 entries.");
  }

  let totalLength = 0;
  const messages = value.map((message) => {
    if (!message || !["user", "assistant"].includes(message.role) ||
        typeof message.content !== "string" || message.content.length > 4_000) {
      throw new Error("Each message requires a user/assistant role and content up to 4,000 characters.");
    }
    totalLength += message.content.length;
    return { role: message.role, content: message.content };
  });
  if (totalLength > 16_000) {
    throw new Error("Conversation exceeds 16,000 characters.");
  }
  return messages;
}

async function modelCompletion(messages, signal) {
  const response = await fetch(`${modelBaseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${process.env.OPENAI_API_KEY ?? "EMPTY"}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: modelName,
      messages,
      tools: [advertisedTool],
      tool_choice: "auto",
      max_tokens: 512,
      temperature: 0,
      chat_template_kwargs: { enable_thinking: false },
    }),
    signal,
  });

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1_000);
    throw new Error(`Nemotron returned HTTP ${response.status}: ${detail}`);
  }
  return response.json();
}

function toolText(result) {
  return (result.content ?? [])
    .filter((entry) => entry.type === "text")
    .map((entry) => entry.text)
    .join("\n")
    .slice(0, 12_000);
}

async function runBoundedTool(call) {
  if (call.function?.name !== advertisedTool.function.name) {
    throw new Error(`Tool '${call.function?.name}' is not allowed.`);
  }
  if (call.function.arguments) {
    const args = JSON.parse(call.function.arguments);
    if (!args || Array.isArray(args) || Object.keys(args).length !== 0) {
      throw new Error("The Kubernetes tool does not accept caller-controlled arguments.");
    }
  }

  const result = await mcpClient.callTool({
    name: "pods_list_in_namespace",
    arguments: { namespace: toolNamespace },
  });
  if (result.isError) {
    throw new Error(`Kubernetes MCP tool failed: ${toolText(result)}`);
  }
  return toolText(result);
}

async function chat(request, response) {
  if (!mcpReady) {
    sendJson(response, 503, { error: "Kubernetes MCP integration is not ready." });
    return;
  }

  const body = await readJson(request);
  const conversation = validateMessages(body.messages);
  const messages = [
    {
      role: "system",
      content: `You are the SE350 Kubernetes assistant. Answer concisely. Use kubernetes_pods_list when a user asks about live pods, workloads, readiness, or cluster status. The tool is read-only and fixed to the '${toolNamespace}' namespace. Never claim to run commands or change resources.`,
    },
    ...conversation,
  ];
  const toolActivity = [];
  const timeout = AbortSignal.timeout(120_000);

  for (let round = 0; round < 3; round += 1) {
    const completion = await modelCompletion(messages, timeout);
    const message = completion.choices?.[0]?.message;
    if (!message) {
      throw new Error("Nemotron returned no assistant message.");
    }

    if (!message.tool_calls?.length) {
      sendJson(response, 200, {
        message: message.content ?? "",
        model: completion.model ?? modelName,
        toolActivity,
      });
      return;
    }

    if (round === 2 || message.tool_calls.length > 1) {
      throw new Error("Nemotron exceeded the bounded tool-call limit.");
    }
    messages.push({
      role: "assistant",
      content: message.content ?? "",
      tool_calls: message.tool_calls,
    });

    for (const call of message.tool_calls) {
      const result = await runBoundedTool(call);
      toolActivity.push({
        tool: advertisedTool.function.name,
        namespace: toolNamespace,
      });
      messages.push({
        role: "tool",
        tool_call_id: call.id,
        content: result,
      });
    }
  }
}

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

async function staticFile(request, response) {
  const relativePath = request.url === "/" ? "index.html" : request.url.slice(1);
  if (!["index.html", "app.js", "styles.css"].includes(relativePath)) {
    sendJson(response, 404, { error: "Not found." });
    return;
  }
  const data = await readFile(join(publicDirectory, relativePath));
  response.writeHead(200, {
    "Content-Type": contentTypes[extname(relativePath)],
    "Content-Length": data.length,
    "Cache-Control": "no-cache",
    "Content-Security-Policy": "default-src 'self'; connect-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  });
  response.end(data);
}

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/healthz") {
      sendJson(response, 200, { status: "ok" });
      return;
    }
    if (request.method === "GET" && request.url === "/readyz") {
      sendJson(response, mcpReady ? 200 : 503, { status: mcpReady ? "ready" : "not-ready" });
      return;
    }
    if (request.url?.startsWith("/api/")) {
      if (!authorized(request)) {
        sendJson(response, 401, { error: "A valid bearer token is required." });
        return;
      }
      if (!withinRateLimit(request)) {
        sendJson(response, 429, { error: "Rate limit exceeded. Try again shortly." });
        return;
      }
      if (request.method === "POST" && request.url === "/api/chat") {
        await chat(request, response);
        return;
      }
      sendJson(response, 404, { error: "Not found." });
      return;
    }
    if (request.method === "GET") {
      await staticFile(request, response);
      return;
    }
    sendJson(response, 405, { error: "Method not allowed." });
  } catch (error) {
    console.error(error);
    const isClientError = error instanceof SyntaxError ||
      error.message?.includes("messages") ||
      error.message?.includes("characters") ||
      error.message?.includes("64 KiB");
    sendJson(response, isClientError ? 400 : 502, { error: error.message ?? String(error) });
  }
});

async function start() {
  mcpClient = new Client({ name: "se350-web-chat", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: "/usr/local/bin/kubernetes-mcp-server",
    args: [
      "--read-only",
      "--disable-destructive",
      "--disable-multi-cluster",
      "--cluster-provider",
      "in-cluster",
      "--toolsets",
      "core",
      "--log-file",
      "stderr",
    ],
    env: { ...process.env },
    stderr: "inherit",
  });
  await mcpClient.connect(transport);
  const available = await mcpClient.listTools();
  if (!available.tools?.some((tool) => tool.name === "pods_list_in_namespace")) {
    throw new Error("Required MCP tool 'pods_list_in_namespace' is unavailable.");
  }
  mcpReady = true;
  server.listen(port, "0.0.0.0", () => {
    console.log(`Web chat listening on port ${port}; model=${modelBaseUrl}; namespace=${toolNamespace}`);
  });
}

async function shutdown() {
  mcpReady = false;
  server.close();
  await mcpClient?.close();
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
start().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
