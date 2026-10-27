import {
  appendClipboard,
  escapeForAppleScript,
  toLower,
  toMarkdownBold,
  toMarkdownCode,
  toMarkdownItalic,
  toMarkdownQuote,
  toTitleCase,
  toUpper,
  urlEncode,
} from "./actions.ts";
import type { Config } from "./config.ts";
import type { Action } from "./types.ts";

export interface SystemPort {
  readClipboard(): string;
  writeClipboard(text: string): void;
  openUrl(url: string): boolean;
  runAppleScript(source: string): boolean;
  runShell(command: string): boolean;
}

export function searchUrl(template: string, text: string): string {
  const query = urlEncode(text);
  return template.includes("{query}") ? template.split("{query}").join(query) : template + query;
}

export function notesScript(text: string): string {
  return `tell application "Notes" to tell default account to make new note with properties {body:"${escapeForAppleScript(text)}"}`;
}

function runClipboardAction(act: Action, text: string, sys: SystemPort): string | null {
  if (act.kind === "copy" || act.kind === "cut") {
    sys.writeClipboard(text);
    return "Copied to clipboard.";
  }
  if (act.kind === "append_clipboard") {
    sys.writeClipboard(appendClipboard(sys.readClipboard(), text));
    return "Appended to clipboard.";
  }
  if (act.kind === "calculate") {
    sys.writeClipboard(act.payload);
    return act.payload;
  }
  return null;
}

function linkUrl(act: Action, text: string): string {
  const target = act.payload.length > 0 ? act.payload : text.trim();
  return target.includes("://") ? target : `https://${target}`;
}

function runOpenAction(act: Action, text: string, cfg: Config, sys: SystemPort): string | null {
  if (act.kind === "search") {
    return sys.openUrl(searchUrl(cfg.searchEngine, text)) ? "Opened the search." : "Could not open the search.";
  }
  if (act.kind === "open_url") {
    return sys.openUrl(linkUrl(act, text)) ? "Opened the link." : "Could not open the link.";
  }
  if (act.kind === "email") {
    return sys.openUrl(`mailto:${text.trim()}`) ? "Opened a new email." : "Could not open Mail.";
  }
  if (act.kind === "dictionary") {
    return sys.openUrl(`dict://${urlEncode(text.trim())}`) ? "Opened Dictionary." : "Could not open Dictionary.";
  }
  return null;
}

function runAppAction(act: Action, text: string, sys: SystemPort): string | null {
  if (act.kind === "notes") {
    return sys.runAppleScript(notesScript(text)) ? "Created a note in Notes." : "Notes did not accept the note.";
  }
  if (act.kind === "terminal") {
    return sys.runShell(text) ? "Started the command." : "Could not start the command.";
  }
  return null;
}

export function executeAction(act: Action, text: string, cfg: Config, sys: SystemPort): string {
  const result =
    runClipboardAction(act, text, sys) ?? runOpenAction(act, text, cfg, sys) ?? runAppAction(act, text, sys);
  if (result !== null) return result;
  const transformed = transformFor(act.kind, text);
  if (transformed === null) return "No change.";
  sys.writeClipboard(transformed);
  return transformed;
}

function transformFor(kind: Action["kind"], text: string): string | null {
  if (kind === "upper_case") return toUpper(text);
  if (kind === "lower_case") return toLower(text);
  if (kind === "title_case") return toTitleCase(text);
  if (kind === "markdown_bold") return toMarkdownBold(text);
  if (kind === "markdown_italic") return toMarkdownItalic(text);
  if (kind === "markdown_code") return toMarkdownCode(text);
  if (kind === "markdown_quote") return toMarkdownQuote(text);
  return null;
}
