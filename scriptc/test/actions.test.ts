import { describe, expect, test } from "bun:test";
import {
  appendClipboard,
  countStats,
  escapeForAppleScript,
  evaluateMath,
  filterActions,
  formatMathResult,
  getActionsForSelection,
  isEmail,
  isUrl,
  parseYamlExtension,
  toMarkdownBold,
  toTitleCase,
  toUpper,
  urlEncode,
} from "../src/actions.ts";

describe("detectors (ported from actions.zig tests)", () => {
  test("isUrl", () => {
    expect(isUrl("https://github.com/justrach/nanoui")).toBe(true);
    expect(isUrl("http://example.com/test?q=1")).toBe(true);
    expect(isUrl("www.google.com")).toBe(true);
    expect(isUrl("pilotmoon.com/popclip")).toBe(true);
    expect(isUrl("hello world")).toBe(false);
    expect(isUrl("just plain text")).toBe(false);
  });

  test("isEmail", () => {
    expect(isEmail("support@pilotmoon.com")).toBe(true);
    expect(isEmail("dev@nanoui.org")).toBe(true);
    expect(isEmail("not an email")).toBe(false);
    expect(isEmail("invalid@domain")).toBe(false);
  });
});

describe("evaluateMath", () => {
  test("matches the Zig evaluator", () => {
    expect(evaluateMath("12 + 34 * 2")).toBe(80);
    expect(evaluateMath("(100 - 20) / 4")).toBe(20);
    expect(evaluateMath("2 ^ 10")).toBe(1024);
    expect(evaluateMath("just some text")).toBeNull();
  });

  test("rejects malformed input instead of guessing", () => {
    expect(evaluateMath("1 / 0")).toBeNull();
    expect(evaluateMath("(1 + 2")).toBeNull();
    expect(evaluateMath("1 +")).toBeNull();
    expect(evaluateMath("42")).toBeNull();
  });

  test("handles unary minus, decimals and floored modulo", () => {
    expect(evaluateMath("-3 + 5")).toBe(2);
    expect(evaluateMath(".5 * 4")).toBe(2);
    expect(evaluateMath("-7 % 3")).toBe(2);
  });

  test("formats whole and fractional results", () => {
    expect(formatMathResult(96)).toBe("= 96");
    expect(formatMathResult(10 / 3)).toBe("= 3.3333");
  });
});

describe("text transforms", () => {
  test("ported cases", () => {
    expect(toUpper("hello world")).toBe("HELLO WORLD");
    expect(toTitleCase("hello world from zig")).toBe("Hello World From Zig");
    expect(toMarkdownBold("bolded")).toBe("**bolded**");
  });

  test("leave non-ASCII letters alone like the Zig version", () => {
    expect(toUpper("café ™")).toBe("CAFé ™");
  });

  test("countStats counts UTF-8 bytes as chars", () => {
    expect(countStats("The quick brown fox jumps")).toEqual({ words: 5, chars: 25, lines: 1 });
    expect(countStats("Initial Line\nAppended Line (™)")).toEqual({ words: 5, chars: 32, lines: 2 });
  });
});

describe("clipboard helpers", () => {
  test("appendClipboard", () => {
    expect(appendClipboard("First line", "Second line")).toBe("First line\nSecond line");
    expect(appendClipboard("", "Only line")).toBe("Only line");
  });

  test("urlEncode percent-encodes UTF-8", () => {
    expect(urlEncode("The trademark symbol (™)")).toBe("The+trademark+symbol+%28%E2%84%A2%29");
  });

  test("escapeForAppleScript", () => {
    expect(escapeForAppleScript('He said "hello"\nNext line')).toBe('He said \\"hello\\"\\nNext line');
  });
});

describe("parseYamlExtension", () => {
  test("parses a #popclip snippet", () => {
    const ext = parseYamlExtension(
      "#popclip\nname: Google Search\nicon: magnifyingglass\nurl: https://www.google.com/search?q=***",
    );
    expect(ext?.name).toBe("Google Search");
    expect(ext?.icon).toBe("magnifyingglass");
    expect(ext?.url).toBe("https://www.google.com/search?q=***");
  });

  test("rejects text without the header", () => {
    expect(parseYamlExtension("name: x")).toBeNull();
  });
});

describe("getActionsForSelection", () => {
  test("empty selection yields only paste", () => {
    expect(getActionsForSelection("   ", true).map((a) => a.id)).toEqual(["paste"]);
    expect(getActionsForSelection("", false)).toEqual([]);
  });

  test("starts with copy and adds contextual actions", () => {
    const ids = getActionsForSelection("https://github.com/justrach/nanoui", true).map((a) => a.id);
    expect(ids[0]).toBe("copy");
    expect(ids).toContain("open_url");
    expect(ids).not.toContain("email");
    expect(ids).not.toContain("dictionary");
    expect(getActionsForSelection("github.com", true).map((a) => a.id)).toContain("dictionary");
  });

  test("math selection carries its result as the label", () => {
    const calc = getActionsForSelection("12 * 8", true).find((a) => a.id === "calculate");
    expect(calc?.label).toBe("= 96");
  });

  test("filterActions keeps the configured order", () => {
    const all = getActionsForSelection("hello world", true);
    expect(filterActions(all, ["notes", "append"]).map((a) => a.id)).toEqual(["notes", "append"]);
    expect(filterActions(all, []).length).toBe(all.length);
  });
});
