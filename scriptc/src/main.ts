import { appendClipboard, getActionsForSelection } from "./actions.ts";
import { CONFIG_KEYS, configPath, getConfigValue, loadConfig, saveConfig, setConfigValue } from "./config.ts";
import { Daemon } from "./daemon.ts";
import { runMcpServer } from "./mcp.ts";
import { pzNowMs, pzPbWrite, pzRssBytes } from "./native.ts";
import { accessibilitySelection, nativeSystem, readClipboard } from "./system.ts";

const VERSION = "0.2.0-scriptc";

function usage(): void {
  console.log(`popzlip ${VERSION}

Usage:
  popzlip                          Run the selection daemon
  popzlip --simulate <text>        Show the popup for <text> at screen center
  popzlip --mcp                    Run the MCP server on stdio
  popzlip config get <key>         Print one setting
  popzlip config set <key> <value> Change and save one setting
  popzlip config list              Print every setting
  popzlip append <text>            Append <text> to the clipboard
  popzlip actions <text>           Print the actions for <text> as JSON
  popzlip bench-engine <n> <text>  Time the action engine over <n> runs
  popzlip --version                Print the version

Options:
  --trace                          Print timing for each popup to stderr
  --exit-after <ms>                Quit the daemon after <ms> (for benchmarks)
  --press <n>                      Click popup button <n> after showing it (for tests)

Settings: ${CONFIG_KEYS.join(", ")}`);
}

function runConfig(args: string[]): number {
  const path = configPath();
  const cfg = loadConfig(path);
  const sub = args[0] ?? "list";
  if (sub === "list") {
    for (const key of CONFIG_KEYS) console.log(`${key} = ${getConfigValue(cfg, key) ?? ""}`);
    return 0;
  }
  if (sub === "get") {
    const key = args[1] ?? "search_engine";
    const value = getConfigValue(cfg, key);
    if (value === null) {
      console.error(`Unknown setting: ${key}`);
      return 1;
    }
    console.log(`${key} = ${value}`);
    return 0;
  }
  if (sub === "set") {
    const key = args[1];
    const value = args[2];
    if (key === undefined || value === undefined) {
      console.error("Usage: popzlip config set <key> <value>");
      return 1;
    }
    if (!setConfigValue(cfg, key, value)) {
      console.error(`Unknown setting: ${key}`);
      return 1;
    }
    saveConfig(path, cfg);
    console.log(`Set ${key} = ${value}`);
    return 0;
  }
  console.error(`Unknown config command: ${sub}`);
  return 1;
}

function runBenchEngine(runs: number, text: string): void {
  let total = 0;
  const start = pzNowMs();
  for (let i = 0; i < runs; i++) total += getActionsForSelection(text, true).length;
  const elapsedMs = pzNowMs() - start;
  console.log(
    JSON.stringify({
      runs,
      actions: total / runs,
      ns_per_op: (elapsedMs * 1e6) / runs,
      rss_mb: pzRssBytes() / 1048576,
    }),
  );
}

function main(argv: string[]): number {
  let simulate = "";
  let trace = false;
  let exitAfter = 0;
  let press = -1;
  const rest: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] as string;
    if (arg === "--trace") trace = true;
    else if (arg === "--exit-after") exitAfter = Number(argv[++i] ?? "0");
    else if (arg === "--press") press = Number(argv[++i] ?? "-1");
    else if (arg === "--simulate" || arg === "-s") simulate = argv[++i] ?? "";
    else if (arg.startsWith("--simulate=")) simulate = arg.slice("--simulate=".length);
    else rest.push(arg);
  }

  const command = rest[0] ?? "";
  if (command === "--help" || command === "-h" || command === "help") {
    usage();
    return 0;
  }
  if (command === "--version" || command === "-v") {
    console.log(VERSION);
    return 0;
  }
  if (command === "config") return runConfig(rest.slice(1));
  if (command === "append") {
    const text = rest[1] ?? "";
    pzPbWrite(appendClipboard(readClipboard(), text));
    console.log(`Appended ${Buffer.byteLength(text, "utf8")} bytes to the clipboard.`);
    return 0;
  }
  if (command === "actions") {
    console.log(JSON.stringify(getActionsForSelection(rest[1] ?? "", true)));
    return 0;
  }
  if (command === "bench-engine") {
    runBenchEngine(Number(rest[1] ?? "100000"), rest[2] ?? "https://github.com/vercel-labs/scriptc");
    return 0;
  }
  if (command === "--mcp") {
    const startedAt = pzNowMs();
    runMcpServer({
      system: nativeSystem,
      config: loadConfig(configPath()),
      currentSelection: accessibilitySelection,
      rssBytes: () => pzRssBytes(),
      uptimeMs: () => pzNowMs() - startedAt,
    });
    return -1;
  }
  if (command.length > 0 && simulate.length === 0) {
    simulate = command;
  }
  new Daemon(loadConfig(configPath()), {
    simulateText: simulate,
    trace,
    exitAfterShowMs: exitAfter,
    pressIndex: press,
  }).start();
  return 0;
}

const code = main(process.argv.slice(2));
if (code >= 0) process.exitCode = code;
