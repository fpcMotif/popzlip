import { createInterface } from "node:readline";
import { getActionsForSelection } from "./actions.ts";
import type { Config } from "./config.ts";
import { executeAction, type SystemPort } from "./executor.ts";
import type { Action } from "./types.ts";

export interface McpHost {
  system: SystemPort;
  config: Config;
  currentSelection(): string;
  rssBytes(): number;
  uptimeMs(): number;
}

interface ToolSpec {
  name: string;
  description: string;
  properties: string[];
  required: string[];
}

const TOOLS: ToolSpec[] = [
  { name: "popclip_get_selection", description: "Get the text selected in the frontmost macOS app.", properties: [], required: [] },
  {
    name: "popclip_list_actions",
    description: "List the PopClip actions available for a text.",
    properties: ["text"],
    required: ["text"],
  },
  {
    name: "popclip_trigger_action",
    description: "Run a PopClip action (copy, append, notes, search, open_url, upper, calculate, and others) on a text.",
    properties: ["action", "text"],
    required: ["action", "text"],
  },
  { name: "popclip_read_clipboard", description: "Read the current text on the clipboard.", properties: [], required: [] },
  {
    name: "popclip_append_clipboard",
    description: "Append a text to the clipboard on a new line.",
    properties: ["text"],
    required: ["text"],
  },
  { name: "popclip_get_stats", description: "Get live process stats: memory RSS and uptime.", properties: [], required: [] },
];

function toolSchema(tool: ToolSpec): unknown {
  const properties: Record<string, unknown> = {};
  for (const p of tool.properties) properties[p] = { type: "string" };
  return {
    name: tool.name,
    description: tool.description,
    inputSchema: { type: "object", properties, required: tool.required },
  };
}

function stringArg(args: Record<string, unknown>, key: string): string {
  const value = args[key];
  return typeof value === "string" ? value : "";
}

function findAction(list: Action[], id: string): Action | null {
  for (const a of list) {
    if (a.id === id || a.kind === id) return a;
  }
  return null;
}

export function callTool(host: McpHost, name: string, args: Record<string, unknown>): string {
  if (name === "popclip_get_selection") return host.currentSelection();
  if (name === "popclip_read_clipboard") return host.system.readClipboard();
  if (name === "popclip_get_stats") {
    const rssMb = (host.rssBytes() / 1048576).toFixed(2);
    return `popzlip (scriptc) running. Memory RSS: ${rssMb} MB. Uptime: ${(host.uptimeMs() / 1000).toFixed(1)} s.`;
  }
  const text = stringArg(args, "text");
  if (name === "popclip_list_actions") {
    const parts: string[] = [];
    for (const a of getActionsForSelection(text, true)) parts.push(`${a.label} (id: ${a.id})`);
    return `Available actions: ${parts.join(", ")}`;
  }
  if (name === "popclip_append_clipboard") {
    const append = findAction(getActionsForSelection(text, false), "append");
    if (append === null) return "Nothing to append.";
    return executeAction(append, text, host.config, host.system);
  }
  if (name === "popclip_trigger_action") {
    const act = findAction(getActionsForSelection(text, true), stringArg(args, "action"));
    if (act === null) return `Unknown action for this text: ${stringArg(args, "action")}`;
    return executeAction(act, text, host.config, host.system);
  }
  throw new Error(`Unknown tool: ${name}`);
}

export function handleRequest(host: McpHost, line: string): string | null {
  let message: unknown;
  try {
    message = JSON.parse(line);
  } catch {
    return JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  if (typeof message !== "object" || message === null) return null;
  const req = message as Record<string, unknown>;
  const id = req["id"];
  const method = req["method"];
  if (id === undefined || typeof method !== "string") return null;

  if (method === "initialize") {
    return JSON.stringify({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "popzlip-scriptc-mcp", version: "0.2.0" },
      },
    });
  }
  if (method === "tools/list") {
    const tools: unknown[] = [];
    for (const t of TOOLS) tools.push(toolSchema(t));
    return JSON.stringify({ jsonrpc: "2.0", id, result: { tools } });
  }
  if (method === "tools/call") {
    const params = req["params"];
    const p = typeof params === "object" && params !== null ? (params as Record<string, unknown>) : {};
    const name = typeof p["name"] === "string" ? (p["name"] as string) : "";
    const rawArgs = p["arguments"];
    const args = typeof rawArgs === "object" && rawArgs !== null ? (rawArgs as Record<string, unknown>) : {};
    try {
      const text = callTool(host, name, args);
      return JSON.stringify({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
    } catch (err) {
      const msg = err instanceof Error ? err.message : "Tool failed";
      return JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32602, message: msg } });
    }
  }
  return JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } });
}

export function runMcpServer(host: McpHost): void {
  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line: string) => {
    const trimmed = line.trim();
    if (trimmed.length === 0) return;
    const reply = handleRequest(host, trimmed);
    if (reply !== null) process.stdout.write(reply + "\n");
  });
}
