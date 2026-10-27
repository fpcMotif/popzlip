import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getActionsForSelection } from "../src/actions.ts";
import {
  defaultConfig,
  getConfigValue,
  loadConfig,
  parseConfig,
  popupActionIds,
  saveConfig,
  setConfigValue,
} from "../src/config.ts";
import { executeAction, notesScript, searchUrl, type SystemPort } from "../src/executor.ts";
import { handleRequest, type McpHost } from "../src/mcp.ts";

class FakeSystem implements SystemPort {
  clipboard = "";
  opened: string[] = [];
  scripts: string[] = [];
  shells: string[] = [];
  readClipboard(): string {
    return this.clipboard;
  }
  writeClipboard(text: string): void {
    this.clipboard = text;
  }
  openUrl(url: string): boolean {
    this.opened.push(url);
    return true;
  }
  runAppleScript(source: string): boolean {
    this.scripts.push(source);
    return true;
  }
  runShell(command: string): boolean {
    this.shells.push(command);
    return true;
  }
}

function act(text: string, id: string) {
  const found = getActionsForSelection(text, true).find((a) => a.id === id);
  if (found === undefined) throw new Error(`no ${id} action for ${text}`);
  return found;
}

describe("config", () => {
  test("ported get/set cases", () => {
    const cfg = defaultConfig();
    expect(getConfigValue(cfg, "search_engine")).toBe("https://www.google.com/search?q={query}");
    expect(getConfigValue(cfg, "theme")).toBe("dark");
    setConfigValue(cfg, "theme", "light");
    expect(getConfigValue(cfg, "theme")).toBe("light");
    setConfigValue(cfg, "enable_math", "false");
    expect(getConfigValue(cfg, "enable_math")).toBe("false");
    expect(setConfigValue(cfg, "nope", "1")).toBe(false);
  });

  test("persists to disk, unlike the Zig version", () => {
    const path = join(mkdtempSync(join(tmpdir(), "popzlip-")), "nested", "config.json");
    const cfg = defaultConfig();
    setConfigValue(cfg, "search_engine", "https://duckduckgo.com/?q={query}");
    saveConfig(path, cfg);
    expect(loadConfig(path).searchEngine).toBe("https://duckduckgo.com/?q={query}");
  });

  test("ignores unknown keys and bad JSON", () => {
    expect(parseConfig('{"theme":"light","x":1}').theme).toBe("light");
    expect(loadConfig("/definitely/missing/config.json").theme).toBe("dark");
  });

  test("popup shows only append and notes by default, and respects the enable flags", () => {
    const cfg = defaultConfig();
    expect(popupActionIds(cfg)).toEqual(["append", "notes"]);
    setConfigValue(cfg, "enable_notes", "false");
    expect(popupActionIds(cfg)).toEqual(["append"]);
  });
});

describe("executeAction", () => {
  const cfg = defaultConfig();

  test("append adds the selection on a new line after the clipboard", () => {
    const sys = new FakeSystem();
    sys.clipboard = "Initial Line";
    executeAction(act("Appended Line (™)", "append"), "Appended Line (™)", cfg, sys);
    expect(sys.clipboard).toBe("Initial Line\nAppended Line (™)");
  });

  test("notes sends one AppleScript with quotes escaped", () => {
    const sys = new FakeSystem();
    executeAction(act('it\'s "quoted"', "notes"), 'it\'s "quoted"', cfg, sys);
    expect(sys.scripts).toEqual([notesScript('it\'s "quoted"')]);
    expect(sys.scripts[0]).toContain('{body:"it\'s \\"quoted\\""}');
  });

  test("search uses the configured engine template", () => {
    const sys = new FakeSystem();
    const custom = defaultConfig();
    setConfigValue(custom, "search_engine", "https://kagi.com/search?q={query}");
    executeAction(act("zig vs ts", "search"), "zig vs ts", custom, sys);
    expect(sys.opened).toEqual(["https://kagi.com/search?q=zig+vs+ts"]);
    expect(searchUrl("https://x.test/?q=", "a b")).toBe("https://x.test/?q=a+b");
  });

  test("open_url adds a scheme to bare domains", () => {
    const sys = new FakeSystem();
    executeAction(act("github.com", "open_url"), "github.com", cfg, sys);
    expect(sys.opened).toEqual(["https://github.com"]);
  });

  test("transforms and calculate write the result to the clipboard", () => {
    const sys = new FakeSystem();
    executeAction(act("hello", "upper"), "hello", cfg, sys);
    expect(sys.clipboard).toBe("HELLO");
    executeAction(act("12 * 8", "calculate"), "12 * 8", cfg, sys);
    expect(sys.clipboard).toBe("= 96");
  });
});

function host(sys: FakeSystem): McpHost {
  return {
    system: sys,
    config: defaultConfig(),
    currentSelection: () => "selected text",
    rssBytes: () => 8 * 1048576,
    uptimeMs: () => 1500,
  };
}

function call(h: McpHost, name: string, args: Record<string, unknown>): Record<string, unknown> {
  const line = JSON.stringify({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name, arguments: args } });
  return JSON.parse(handleRequest(h, line) ?? "null") as Record<string, unknown>;
}

function replyText(reply: Record<string, unknown>): string {
  const result = reply["result"] as { content: { text: string }[] };
  return result.content[0]?.text ?? "";
}

function parseReply(h: McpHost, line: string): unknown {
  return JSON.parse(handleRequest(h, line) ?? "{}");
}

describe("MCP", () => {
  test("initialize and tools/list", () => {
    const h = host(new FakeSystem());
    const init = parseReply(h, '{"jsonrpc":"2.0","id":1,"method":"initialize"}') as {
      result: { serverInfo: { name: string } };
    };
    expect(init.result.serverInfo.name).toBe("popzlip-scriptc-mcp");
    const list = parseReply(h, '{"jsonrpc":"2.0","id":"a","method":"tools/list"}') as {
      id: string;
      result: { tools: { name: string }[] };
    };
    expect(list.id).toBe("a");
    expect(list.result.tools.map((t) => t.name)).toContain("popclip_append_clipboard");
  });

  test("notifications get no reply and bad JSON gets a parse error", () => {
    const h = host(new FakeSystem());
    expect(handleRequest(h, '{"jsonrpc":"2.0","method":"notifications/initialized"}')).toBeNull();
    expect((parseReply(h, "{oops") as { error: { code: number } }).error.code).toBe(-32700);
  });

  test("clipboard text with quotes stays valid JSON", () => {
    const sys = new FakeSystem();
    sys.clipboard = 'say "hi"\n\tbye';
    expect(replyText(call(host(sys), "popclip_read_clipboard", {}))).toBe('say "hi"\n\tbye');
  });

  test("append keeps the existing clipboard", () => {
    const sys = new FakeSystem();
    sys.clipboard = "one";
    call(host(sys), "popclip_append_clipboard", { text: "two" });
    expect(sys.clipboard).toBe("one\ntwo");
  });

  test("trigger_action runs any action by id or kind", () => {
    const sys = new FakeSystem();
    expect(replyText(call(host(sys), "popclip_trigger_action", { action: "calculate", text: "2 ^ 10" }))).toBe(
      "= 1024",
    );
    call(host(sys), "popclip_trigger_action", { action: "title_case", text: "a b" });
    expect(sys.clipboard).toBe("A B");
  });

  test("selection, stats and unknown tools", () => {
    const h = host(new FakeSystem());
    expect(replyText(call(h, "popclip_get_selection", {}))).toBe("selected text");
    expect(replyText(call(h, "popclip_get_stats", {}))).toContain("8.00 MB");
    expect((call(h, "nope", {})["error"] as { code: number }).code).toBe(-32602);
  });
});
