import type { Action } from "./types.ts";

export interface Rgba {
  r: number;
  g: number;
  b: number;
  a: number;
}

export interface Theme {
  background: Rgba;
  label: Rgba;
  separator: Rgba;
  radius: number;
  fontSize: number;
  height: number;
  buttonPadding: number;
  minWidth: number;
}

export interface ButtonLayout {
  actionIndex: number;
  label: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface SeparatorLayout {
  x: number;
  y: number;
  height: number;
}

export interface PopupLayout {
  width: number;
  height: number;
  buttons: ButtonLayout[];
  separators: SeparatorLayout[];
}

export function themeFor(name: string): Theme {
  if (name === "light") {
    return {
      background: { r: 0.97, g: 0.97, b: 0.98, a: 0.97 },
      label: { r: 0.1, g: 0.11, b: 0.13, a: 1 },
      separator: { r: 0, g: 0, b: 0, a: 0.12 },
      radius: 9,
      fontSize: 13,
      height: 30,
      buttonPadding: 11,
      minWidth: 72,
    };
  }
  return {
    background: { r: 0.13, g: 0.14, b: 0.17, a: 0.96 },
    label: { r: 1, g: 1, b: 1, a: 0.95 },
    separator: { r: 1, g: 1, b: 1, a: 0.16 },
    radius: 9,
    fontSize: 13,
    height: 30,
    buttonPadding: 11,
    minWidth: 72,
  };
}

export function layoutPopup(actions: Action[], theme: Theme, measure: (label: string) => number): PopupLayout {
  const buttons: ButtonLayout[] = [];
  const separators: SeparatorLayout[] = [];
  const inset = 3;
  const buttonHeight = theme.height - inset * 2;
  let x = inset;
  for (let i = 0; i < actions.length; i++) {
    const act = actions[i] as Action;
    if (i > 0) {
      separators.push({ x, y: inset + 5, height: buttonHeight - 10 });
      x += 1;
    }
    const width = measure(act.label) + theme.buttonPadding * 2;
    buttons.push({ actionIndex: i, label: act.label, x, y: inset, width, height: buttonHeight });
    x += width;
  }
  const width = Math.max(theme.minWidth, x + inset);
  if (buttons.length > 0 && width > x + inset) {
    const extra = width - (x + inset);
    const last = buttons[buttons.length - 1] as ButtonLayout;
    last.width += extra;
  }
  return { width, height: theme.height, buttons, separators };
}
