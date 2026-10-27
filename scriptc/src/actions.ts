import type { Action, TextStats, YamlExtension } from "./types.ts";

const URL_PREFIXES = ["http://", "https://", "www.", "ftp://"];
const TLDS = [".com", ".org", ".net", ".io", ".dev", ".ai", ".app", ".me", ".co", ".edu", ".gov", ".cn"];

export function isUrl(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 4) return false;
  for (const prefix of URL_PREFIXES) {
    if (trimmed.startsWith(prefix)) return true;
  }
  if (trimmed.includes(" ")) return false;
  const dot = trimmed.indexOf(".");
  if (dot <= 0 || dot >= trimmed.length - 2) return false;
  for (const tld of TLDS) {
    if (trimmed.includes(tld)) return true;
  }
  return false;
}

export function isEmail(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 5 || trimmed.includes(" ")) return false;
  const at = trimmed.indexOf("@");
  if (at <= 0 || at >= trimmed.length - 3) return false;
  const domain = trimmed.slice(at + 1);
  const dot = domain.indexOf(".");
  return dot > 0 && dot < domain.length - 1;
}

function isDigit(c: string): boolean {
  return c >= "0" && c <= "9";
}

function isOperator(c: string): boolean {
  return c === "+" || c === "-" || c === "*" || c === "/" || c === "%" || c === "^";
}

function precedence(op: string): number {
  if (op === "+" || op === "-") return 1;
  if (op === "*" || op === "/" || op === "%") return 2;
  if (op === "^") return 3;
  return 0;
}

function binary(op: string, a: number, b: number): number | null {
  if (op === "+") return a + b;
  if (op === "-") return a - b;
  if (op === "*") return a * b;
  if (op === "/") return b === 0 ? null : a / b;
  if (op === "%") return a - b * Math.floor(a / b);
  if (op === "^") return Math.pow(a, b);
  return null;
}

function applyOperator(values: number[], op: string): boolean {
  const b = values.pop();
  const a = values.pop();
  if (a === undefined || b === undefined) return false;
  const result = binary(op, a, b);
  if (result === null) return false;
  values.push(result);
  return true;
}

interface MathState {
  values: number[];
  ops: string[];
  expectOperand: boolean;
}

function startsNumber(c: string, next: string, expectOperand: boolean): boolean {
  if (isDigit(c)) return true;
  if (c === ".") return isDigit(next);
  return c === "-" && expectOperand && (isDigit(next) || next === ".");
}

function numberEnd(expr: string, start: number): number {
  let i = expr.charAt(start) === "-" ? start + 1 : start;
  let hasDot = false;
  for (; i < expr.length; i++) {
    const ch = expr.charAt(i);
    if (ch === "." && !hasDot) hasDot = true;
    else if (!isDigit(ch)) break;
  }
  return i;
}

function pushNumber(expr: string, start: number, state: MathState): number {
  const end = numberEnd(expr, start);
  const num = Number(expr.slice(start, end));
  if (Number.isNaN(num)) return -1;
  state.values.push(num);
  state.expectOperand = false;
  return end;
}

function closeParen(state: MathState): boolean {
  state.expectOperand = false;
  for (let top = state.ops.pop(); top !== "("; top = state.ops.pop()) {
    if (top === undefined || !applyOperator(state.values, top)) return false;
  }
  return true;
}

function pushOperator(state: MathState, op: string): boolean {
  state.expectOperand = true;
  let top = state.ops[state.ops.length - 1];
  while (top !== undefined && top !== "(" && precedence(top) >= precedence(op)) {
    state.ops.pop();
    if (!applyOperator(state.values, top)) return false;
    top = state.ops[state.ops.length - 1];
  }
  state.ops.push(op);
  return true;
}

function step(expr: string, i: number, state: MathState): number {
  const c = expr.charAt(i);
  if (c === " " || c === "\t") return i + 1;
  if (startsNumber(c, expr.charAt(i + 1), state.expectOperand)) return pushNumber(expr, i, state);
  if (c === "(") {
    state.ops.push(c);
    state.expectOperand = true;
    return i + 1;
  }
  if (c === ")") return closeParen(state) ? i + 1 : -1;
  if (isOperator(c)) return pushOperator(state, c) ? i + 1 : -1;
  return -1;
}

function evaluateExpression(expr: string): number | null {
  const state: MathState = { values: [], ops: [], expectOperand: true };
  for (let i = 0; i < expr.length;) {
    i = step(expr, i, state);
    if (i < 0) return null;
  }
  for (let op = state.ops.pop(); op !== undefined; op = state.ops.pop()) {
    if (op === "(" || !applyOperator(state.values, op)) return null;
  }
  return state.values.length === 1 ? (state.values[0] ?? null) : null;
}

export function evaluateMath(text: string): number | null {
  const trimmed = text.trim();
  if (trimmed.length === 0) return null;
  let hasOperator = false;
  for (const c of trimmed) {
    if (isOperator(c)) hasOperator = true;
    else if (!isDigit(c) && c !== "." && c !== "(" && c !== ")" && c !== " " && c !== "\t") return null;
  }
  if (!hasOperator) return null;
  return evaluateExpression(trimmed);
}

export function formatMathResult(result: number): string {
  return Math.round(result) === result ? `= ${result}` : `= ${result.toFixed(4)}`;
}

function mapAscii(text: string, upper: boolean): string {
  let out = "";
  for (const c of text) {
    const isLowerAscii = c >= "a" && c <= "z";
    const isUpperAscii = c >= "A" && c <= "Z";
    if (upper && isLowerAscii) out += c.toUpperCase();
    else if (!upper && isUpperAscii) out += c.toLowerCase();
    else out += c;
  }
  return out;
}

export function toUpper(text: string): string {
  return mapAscii(text, true);
}

export function toLower(text: string): string {
  return mapAscii(text, false);
}

function isAsciiLetter(c: string): boolean {
  return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
}

export function toTitleCase(text: string): string {
  let out = "";
  let capNext = true;
  for (const c of text) {
    if (isAsciiLetter(c)) {
      out += capNext ? c.toUpperCase() : c.toLowerCase();
      capNext = false;
    } else {
      out += c;
      capNext = true;
    }
  }
  return out;
}

export function toMarkdownBold(text: string): string {
  return `**${text}**`;
}

export function toMarkdownItalic(text: string): string {
  return `*${text}*`;
}

export function toMarkdownCode(text: string): string {
  return `\`${text}\``;
}

export function toMarkdownQuote(text: string): string {
  return `> ${text}`;
}

export function appendClipboard(current: string, addition: string): string {
  return current.length > 0 ? `${current}\n${addition}` : addition;
}

const HEX = "0123456789ABCDEF";

function isUnreservedByte(b: number): boolean {
  const isAlnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122);
  return isAlnum || b === 45 || b === 95 || b === 46 || b === 126;
}

export function urlEncode(text: string): string {
  const bytes = Buffer.from(text, "utf8");
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i] as number;
    if (isUnreservedByte(b)) out += String.fromCharCode(b);
    else if (b === 32) out += "+";
    else out += "%" + (HEX[b >> 4] as string) + (HEX[b & 15] as string);
  }
  return out;
}

export function escapeForAppleScript(text: string): string {
  let out = "";
  for (const c of text) {
    if (c === '"' || c === "\\") out += "\\" + c;
    else if (c === "\n") out += "\\n";
    else if (c === "\r") out += "\\r";
    else out += c;
  }
  return out;
}

function isWhitespace(c: string): boolean {
  return c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\v" || c === "\f";
}

export function countStats(text: string): TextStats {
  let words = 0;
  let lines = text.length > 0 ? 1 : 0;
  let inWord = false;
  for (const c of text) {
    if (c === "\n") lines++;
    if (isWhitespace(c)) inWord = false;
    else if (!inWord) {
      words++;
      inWord = true;
    }
  }
  return { words, chars: Buffer.byteLength(text, "utf8"), lines };
}

function stripQuotes(value: string): string {
  let v = value.trim();
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
    v = v.slice(1, v.length - 1);
  }
  return v;
}

const YAML_HEADERS = ["#popclip", "# popclip", "#xpop", "# xpop"];

function setYamlField(ext: YamlExtension, key: string, value: string): void {
  if (key === "name") ext.name = value;
  else if (key === "icon") ext.icon = value;
  else if (key === "url") ext.url = value;
  else if (key === "shell script") ext.shellScript = value;
  else if (key === "key combo") ext.keyCombo = value;
}

export function parseYamlExtension(yaml: string): YamlExtension | null {
  const trimmed = yaml.trim();
  if (!YAML_HEADERS.some((h) => trimmed.startsWith(h))) return null;
  const ext: YamlExtension = { name: "", icon: "", url: "", shellScript: "", keyCombo: "" };
  for (const raw of trimmed.split("\n")) {
    const line = raw.trim();
    const colon = line.indexOf(":");
    if (line.startsWith("#") || colon < 0) continue;
    setYamlField(ext, line.slice(0, colon).trim(), stripQuotes(line.slice(colon + 1)));
  }
  return ext.name.length > 0 ? ext : null;
}

function action(id: string, label: string, kind: Action["kind"], payload: string): Action {
  return { id, label, kind, payload };
}

export function getActionsForSelection(text: string, canPaste: boolean): Action[] {
  const list: Action[] = [];
  const trimmed = text.trim();
  if (trimmed.length > 0) {
    list.push(action("copy", "Copy", "copy", ""));
    list.push(action("cut", "Cut", "cut", ""));
    list.push(action("terminal", ">_", "terminal", ""));
    list.push(action("append", "+", "append_clipboard", ""));
    list.push(action("notes", "Notes", "notes", ""));
    list.push(action("drafts", "Drafts", "drafts", ""));
    list.push(action("claude", "Claude", "claude", ""));
    list.push(action("search", "Search", "search", ""));
    if (isUrl(trimmed)) list.push(action("open_url", "Open Link", "open_url", trimmed));
    if (isEmail(trimmed)) list.push(action("email", "Email", "email", trimmed));
    const math = evaluateMath(trimmed);
    if (math !== null) {
      const label = formatMathResult(math);
      list.push(action("calculate", label, "calculate", label));
    }
    if (!trimmed.includes(" ") && trimmed.length <= 30) list.push(action("dictionary", "Define", "dictionary", ""));
    list.push(action("upper", "UPPER", "upper_case", ""));
    list.push(action("lower", "lower", "lower_case", ""));
    list.push(action("title", "Title", "title_case", ""));
    list.push(action("md_bold", "**B**", "markdown_bold", ""));
    list.push(action("md_code", "`code`", "markdown_code", ""));
    const stats = countStats(trimmed);
    const count = `${stats.words}w, ${stats.chars}c`;
    list.push(action("word_count", count, "word_count", count));
  }
  if (canPaste) list.push(action("paste", "Paste", "paste", ""));
  return list;
}

export function filterActions(list: Action[], ids: string[]): Action[] {
  if (ids.length === 0) return list;
  const out: Action[] = [];
  for (const id of ids) {
    for (const a of list) {
      if (a.id === id) out.push(a);
    }
  }
  return out;
}
