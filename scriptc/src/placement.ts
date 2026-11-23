import type { Placement, Rect, ScreenBounds } from "./types.ts";

const GAP = 8;

export function calculatePlacement(
  sel: Rect,
  popupWidth: number,
  popupHeight: number,
  screen: ScreenBounds,
): Placement {
  let x = sel.x + (sel.width - popupWidth) / 2;
  if (x < screen.margin) x = screen.margin;
  else if (x + popupWidth > screen.width - screen.margin) x = screen.width - screen.margin - popupWidth;

  const yAbove = sel.y - popupHeight - GAP;
  if (yAbove >= screen.menuBarHeight + screen.margin) {
    return { x, y: yAbove, width: popupWidth, height: popupHeight, arrowBelow: true };
  }
  let y = sel.y + sel.height + GAP;
  if (y + popupHeight > screen.height - screen.margin) y = screen.height - screen.margin - popupHeight;
  return { x, y, width: popupWidth, height: popupHeight, arrowBelow: false };
}

export function rectContains(rect: Rect, x: number, y: number): boolean {
  return x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height;
}
