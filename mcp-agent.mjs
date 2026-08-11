import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import OpenAI from "openai";

const configPath = process.argv[2] ?? "mcp.config.json";
const config = JSON.parse(await readFile(configPath, "utf8"));
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY ?? "EMPTY",
  baseURL: process.env.OPENAI_BASE_URL ?? config.baseUrl,
});
const clients = new Map();
const tools = [];

function toolName(serverName, name) {
  return `${serverName}__${name}`;
}

async function connectServer(serverName, serverConfig) {
  const client = new Client({ name: "nemotron-mcp-agent", version: "0.1.0" });
  const transport = new StdioClientTransport({
    command: serverConfig.command,
    args: serverConfig.args ?? [],
    env: { ...process.env, ...(serverConfig.env ?? {}) },
    stderr: "inherit",
  });
  await client.connect(transport);
  const result = await client.listTools();
  clients.set(serverName, client);

  for (const tool of result.tools ?? []) {
    tools.push({
      type: "function",
      function: {
        name: toolName(serverName, tool.name),
        description: `[${serverName}] ${tool.description ?? tool.name}`,
        parameters: tool.inputSchema ?? { type: "object", properties: {} },
      },
    });
  }

  console.log(`Connected MCP server '${serverName}' (${result.tools?.length ?? 0} tools)`);
}

async function closeServers() {
  await Promise.all([...clients.values()].map((client) => client.close()));
}

async function complete(messages) {
  return openai.chat.completions.create({
    model: config.model,
    messages,
    tools,
    tool_choice: "auto",
    max_tokens: config.maxTokens ?? 512,
    chat_template_kwargs: { enable_thinking: false },
  });
}

async function runTool(call) {
  const separator = call.function.name.indexOf("__");
  if (separator < 1) {
    throw new Error(`Invalid MCP tool name: ${call.function.name}`);
  }

  const serverName = call.function.name.slice(0, separator);
  const name = call.function.name.slice(separator + 2);
  const client = clients.get(serverName);
  if (!client) {
    throw new Error(`MCP server is not connected: ${serverName}`);
  }

  let argumentsObject = {};
  if (call.function.arguments) {
    argumentsObject = JSON.parse(call.function.arguments);
  }
  console.log(`Tool: ${serverName}/${name}`);
  return client.callTool({ name, arguments: argumentsObject });
}

async function main() {
  for (const [serverName, serverConfig] of Object.entries(config.servers ?? {})) {
    await connectServer(serverName, serverConfig);
  }
  if (tools.length === 0) {
    throw new Error("No MCP tools were discovered.");
  }

  const rl = createInterface({ input, output });
  const messages = [];
  console.log("Nemotron MCP agent. Type 'exit' to quit.");

  try {
    while (true) {
      const prompt = await rl.question("You: ");
      if (prompt.trim().toLowerCase() === "exit") {
        break;
      }
      messages.push({ role: "user", content: prompt });

      while (true) {
        const response = await complete(messages);
        const message = response.choices[0].message;
        const assistantMessage = {
          role: "assistant",
          content: message.content ?? "",
        };
        if (message.tool_calls?.length) {
          assistantMessage.tool_calls = message.tool_calls;
        }
        messages.push(assistantMessage);

        if (!message.tool_calls?.length) {
          console.log(`Nemotron: ${message.content ?? ""}`);
          break;
        }

        for (const call of message.tool_calls) {
          let result;
          try {
            result = await runTool(call);
          } catch (error) {
            result = { isError: true, content: [{ type: "text", text: String(error) }] };
          }
          messages.push({
            role: "tool",
            tool_call_id: call.id,
            content: JSON.stringify(result),
          });
        }
      }
    }
  } finally {
    rl.close();
    await closeServers();
  }
}

main().catch(async (error) => {
  console.error(error);
  await closeServers();
  process.exitCode = 1;
});
