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

export function executeAction(act: Action, text: string, cfg: Config, sys: SystemPort): string {
  const kind = act.kind;
  if (kind === "copy" || kind === "cut") {
    sys.writeClipboard(text);
    return "Copied to clipboard.";
  }
  if (kind === "append_clipboard") {
    sys.writeClipboard(appendClipboard(sys.readClipboard(), text));
    return "Appended to clipboard.";
  }
  if (kind === "notes") {
    return sys.runAppleScript(notesScript(text)) ? "Created a note in Notes." : "Notes did not accept the note.";
  }
  if (kind === "terminal") {
    return sys.runShell(text) ? "Started the command." : "Could not start the command.";
  }
  if (kind === "search") {
    return sys.openUrl(searchUrl(cfg.searchEngine, text)) ? "Opened the search." : "Could not open the search.";
  }
  if (kind === "open_url") {
    const target = act.payload.length > 0 ? act.payload : text.trim();
    const url = target.includes("://") ? target : `https://${target}`;
    return sys.openUrl(url) ? "Opened the link." : "Could not open the link.";
  }
  if (kind === "email") {
    return sys.openUrl(`mailto:${text.trim()}`) ? "Opened a new email." : "Could not open Mail.";
  }
  if (kind === "dictionary") {
    return sys.openUrl(`dict://${urlEncode(text.trim())}`) ? "Opened Dictionary." : "Could not open Dictionary.";
  }
  if (kind === "calculate") {
    sys.writeClipboard(act.payload);
    return act.payload;
  }
  const transformed = transformFor(kind, text);
  if (transformed !== null) {
    sys.writeClipboard(transformed);
    return transformed;
  }
  return "No change.";
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
