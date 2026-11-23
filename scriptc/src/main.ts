import { appendClipboard, getActionsForSelection } from "./actions.ts";
import { CONFIG_KEYS, configPath, getConfigValue, loadConfig, saveConfig, setConfigValue } from "./config.ts";
import { Daemon } from "./daemon.ts";
import { runMcpServer } from "./mcp.ts";
import { AccessibilityGrantCoordinator } from "./permission.ts";
import {
  pzAppInit,
  pzAppQuit,
  pzAppRun,
  pzNowMs,
  pzPbWrite,
  pzRssBytes,
  pzSettingsShow,
  pzStatusItemCreate,
} from "./native.ts";
import { accessibilitySelection, nativeGuidancePort, nativeSchedule, nativeSystem, readClipboard } from "./system.ts";

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
  popzlip settings                 Open the settings window
  popzlip permissions             Check and guide Accessibility permission grant
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

function runBenchEngine(args: string[]): number {
  const runs = Number(args[0] ?? "100000");
  const text = args[1] ?? "https://github.com/vercel-labs/scriptc";
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
  return 0;
}

function runAppend(text: string): number {
  pzPbWrite(appendClipboard(readClipboard(), text));
  console.log(`Appended ${Buffer.byteLength(text, "utf8")} bytes to the clipboard.`);
  return 0;
}

function runActions(text: string): number {
  console.log(JSON.stringify(getActionsForSelection(text, true)));
  return 0;
}

function startMcp(): number {
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

function runPermissions(args: string[] = []): number {
  pzAppInit();
  const force = args.includes("--force") || args.includes("-f");
  const coordinator = new AccessibilityGrantCoordinator({
    port: nativeGuidancePort,
    schedule: nativeSchedule,
    isGranted: force ? () => false : undefined,
    onGranted: () => {
      console.log("Accessibility access granted.");
    },
    onDismissed: () => {
      console.log("Permission guidance dismissed.");
      pzAppQuit();
    },
  });
  if (!force && coordinator.isGranted()) {
    console.log("Accessibility access is already granted.");
    return 0;
  }
  console.log("Opening System Settings and presenting guidance HUD...");
  coordinator.beginGrantFlow();
  pzAppRun();
  return 0;
}

function runSettings(): number {
  pzAppInit();
  pzStatusItemCreate();
  pzSettingsShow();
  pzAppRun();
  return 0;
}

interface Flags {
  simulate: string;
  trace: boolean;
  exitAfter: number;
  press: number;
  rest: string[];
}

function parseFlags(argv: string[]): Flags {
  const flags: Flags = { simulate: "", trace: false, exitAfter: 0, press: -1, rest: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] as string;
    if (arg === "--trace") flags.trace = true;
    else if (arg === "--exit-after") flags.exitAfter = Number(argv[++i] ?? "0");
    else if (arg === "--press") flags.press = Number(argv[++i] ?? "-1");
    else if (arg === "--simulate" || arg === "-s") flags.simulate = argv[++i] ?? "";
    else if (arg.startsWith("--simulate=")) flags.simulate = arg.slice("--simulate=".length);
    else flags.rest.push(arg);
  }
  return flags;
}

function runHelp(): number {
  usage();
  return 0;
}

function runVersion(): number {
  console.log(VERSION);
  return 0;
}

const COMMANDS: Record<string, (rest: string[]) => number> = {
  "--help": runHelp,
  "-h": runHelp,
  help: runHelp,
  "--version": runVersion,
  "-v": runVersion,
  config: (rest) => runConfig(rest.slice(1)),
  append: (rest) => runAppend(rest[1] ?? ""),
  actions: (rest) => runActions(rest[1] ?? ""),
  "bench-engine": (rest) => runBenchEngine(rest.slice(1)),
  "--mcp": startMcp,
  settings: runSettings,
  setting: runSettings,
  preferences: runSettings,
  "--settings": runSettings,
  permissions: (rest) => runPermissions(rest.slice(1)),
  permission: (rest) => runPermissions(rest.slice(1)),
  "--permissions": (rest) => runPermissions(rest.slice(1)),
};

function runCommand(command: string, rest: string[]): number | null {
  const run = Object.hasOwn(COMMANDS, command) ? COMMANDS[command] : undefined;
  return run ? run(rest) : null;
}

function main(argv: string[]): number {
  const flags = parseFlags(argv);
  const command = flags.rest[0] ?? "";
  const code = runCommand(command, flags.rest);
  if (code !== null) return code;
  new Daemon(loadConfig(configPath()), {
    simulateText: flags.simulate.length > 0 ? flags.simulate : command,
    trace: flags.trace,
    exitAfterShowMs: flags.exitAfter,
    pressIndex: flags.press,
  }).start();
  return 0;
}

const code = main(process.argv.slice(2));
if (code >= 0) process.exitCode = code;
