import { describe, expect, test } from "bun:test";
import { getActionsForSelection } from "../src/actions.ts";
import { GestureTracker, KEY_DOWN, MOUSE_DOWN, MOUSE_DRAGGED, MOUSE_UP } from "../src/gesture.ts";
import { calculatePlacement, rectContains } from "../src/placement.ts";
import { layoutPopup, themeFor } from "../src/popup.ts";

const screen = { width: 1000, height: 800, menuBarHeight: 30, margin: 10 };

describe("calculatePlacement (ported from placement.zig tests)", () => {
  test("centers horizontally above the selection", () => {
    const p = calculatePlacement({ x: 400, y: 300, width: 100, height: 20 }, 200, 40, screen);
    expect(p.x).toBe(350);
    expect(p.y).toBe(252);
    expect(p.arrowBelow).toBe(true);
  });

  test("clamps to the left and right margins", () => {
    expect(calculatePlacement({ x: 5, y: 300, width: 20, height: 20 }, 200, 40, screen).x).toBe(10);
    expect(calculatePlacement({ x: 980, y: 300, width: 20, height: 20 }, 200, 40, screen).x).toBe(790);
  });

  test("flips below near the top of the screen", () => {
    const p = calculatePlacement({ x: 400, y: 35, width: 100, height: 20 }, 200, 40, screen);
    expect(p.y).toBe(63);
    expect(p.arrowBelow).toBe(false);
  });

  test("rectContains includes edges", () => {
    const r = { x: 10, y: 10, width: 20, height: 10 };
    expect(rectContains(r, 10, 10)).toBe(true);
    expect(rectContains(r, 30, 20)).toBe(true);
    expect(rectContains(r, 31, 20)).toBe(false);
  });
});

describe("GestureTracker (same thresholds as event_tap.m)", () => {
  test("a drag of two events and 4px or more selects", () => {
    const g = new GestureTracker();
    g.handle(MOUSE_DOWN, 100, 100, 0);
    g.handle(MOUSE_DRAGGED, 102, 100, 0);
    g.handle(MOUSE_DRAGGED, 104, 100, 0);
    expect(g.handle(MOUSE_UP, 104, 100, 1)).toBe("select");
  });

  test("a short jitter or a single drag event does not select", () => {
    const g = new GestureTracker();
    g.handle(MOUSE_DOWN, 100, 100, 0);
    g.handle(MOUSE_DRAGGED, 101, 100, 0);
    g.handle(MOUSE_DRAGGED, 102, 101, 0);
    expect(g.handle(MOUSE_UP, 102, 101, 1)).toBe("none");
    g.handle(MOUSE_DOWN, 100, 100, 0);
    g.handle(MOUSE_DRAGGED, 150, 100, 0);
    expect(g.handle(MOUSE_UP, 150, 100, 1)).toBe("none");
  });

  test("a double click selects and keys are ignored", () => {
    const g = new GestureTracker();
    g.handle(MOUSE_DOWN, 100, 100, 0);
    expect(g.handle(MOUSE_UP, 100, 100, 2)).toBe("select");
    expect(g.handle(KEY_DOWN, 0, 0, 0x35)).toBe("none");
  });
});

describe("layoutPopup", () => {
  const theme = themeFor("dark");
  const measure = (label: string) => label.length * 8;

  test("lays out buttons left to right with separators between them", () => {
    const actions = getActionsForSelection("hello world", true).filter((a) => a.id === "append" || a.id === "notes");
    const layout = layoutPopup(actions, theme, measure);
    expect(layout.buttons.map((b) => b.label)).toEqual(["+", "Notes"]);
    expect(layout.separators.length).toBe(1);
    const [first, second] = layout.buttons;
    expect(first?.x).toBe(3);
    expect(second?.x).toBe((first?.x ?? 0) + (first?.width ?? 0) + 1);
    expect(layout.height).toBe(theme.height);
  });

  test("pads to the minimum width by widening the last button", () => {
    const one = getActionsForSelection("x", false).filter((a) => a.id === "append");
    const layout = layoutPopup(one, theme, measure);
    expect(layout.width).toBe(theme.minWidth);
    expect(layout.buttons[0]?.width).toBe(theme.minWidth - 6);
  });

  test("light theme uses dark labels", () => {
    expect(themeFor("light").label.r).toBeLessThan(0.5);
    expect(themeFor("anything").label.r).toBe(1);
  });
});
