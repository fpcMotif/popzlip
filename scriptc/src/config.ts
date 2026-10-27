import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface Config {
  searchEngine: string;
  terminalApp: string;
  theme: string;
  enableAppend: boolean;
  enableNotes: boolean;
  enableMath: boolean;
  popupActions: string;
}

export const CONFIG_KEYS = [
  "search_engine",
  "terminal_app",
  "theme",
  "enable_append",
  "enable_notes",
  "enable_math",
  "popup_actions",
];

export function defaultConfig(): Config {
  return {
    searchEngine: "https://www.google.com/search?q={query}",
    terminalApp: "Terminal",
    theme: "dark",
    enableAppend: true,
    enableNotes: true,
    enableMath: true,
    popupActions: "append,notes",
  };
}

function parseBool(value: string): boolean {
  return value === "true" || value === "1";
}

export function getConfigValue(cfg: Config, key: string): string | null {
  if (key === "search_engine") return cfg.searchEngine;
  if (key === "terminal_app") return cfg.terminalApp;
  if (key === "theme") return cfg.theme;
  if (key === "enable_append") return cfg.enableAppend ? "true" : "false";
  if (key === "enable_notes") return cfg.enableNotes ? "true" : "false";
  if (key === "enable_math") return cfg.enableMath ? "true" : "false";
  if (key === "popup_actions") return cfg.popupActions;
  return null;
}

export function setConfigValue(cfg: Config, key: string, value: string): boolean {
  if (key === "search_engine") cfg.searchEngine = value;
  else if (key === "terminal_app") cfg.terminalApp = value;
  else if (key === "theme") cfg.theme = value;
  else if (key === "enable_append") cfg.enableAppend = parseBool(value);
  else if (key === "enable_notes") cfg.enableNotes = parseBool(value);
  else if (key === "enable_math") cfg.enableMath = parseBool(value);
  else if (key === "popup_actions") cfg.popupActions = value;
  else return false;
  return true;
}

export function popupActionIds(cfg: Config): string[] {
  const ids: string[] = [];
  for (const raw of cfg.popupActions.split(",")) {
    const id = raw.trim();
    if (id.length === 0) continue;
    if (id === "append" && !cfg.enableAppend) continue;
    if (id === "notes" && !cfg.enableNotes) continue;
    if (id === "calculate" && !cfg.enableMath) continue;
    ids.push(id);
  }
  return ids;
}

export function configPath(): string {
  const xdg = process.env["XDG_CONFIG_HOME"];
  const base = xdg !== undefined && xdg.length > 0 ? xdg : join(homedir(), ".config");
  return join(base, "popzlip", "config.json");
}

export function serializeConfig(cfg: Config): string {
  const out: Record<string, string> = {};
  for (const key of CONFIG_KEYS) out[key] = getConfigValue(cfg, key) ?? "";
  return JSON.stringify(out, null, 2) + "\n";
}

export function parseConfig(json: string): Config {
  const cfg = defaultConfig();
  const parsed: unknown = JSON.parse(json);
  if (typeof parsed !== "object" || parsed === null) return cfg;
  const record = parsed as Record<string, unknown>;
  for (const key of CONFIG_KEYS) {
    const value = record[key];
    if (typeof value === "string") setConfigValue(cfg, key, value);
  }
  return cfg;
}

export function loadConfig(path: string): Config {
  if (!existsSync(path)) return defaultConfig();
  try {
    return parseConfig(readFileSync(path, "utf8"));
  } catch {
    return defaultConfig();
  }
}

export function saveConfig(path: string, cfg: Config): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, serializeConfig(cfg));
}
