import { filterActions, getActionsForSelection } from "./actions.ts";
import { type Config, popupActionIds } from "./config.ts";
import { executeAction } from "./executor.ts";
import { GestureTracker, KEY_DOWN, KEY_ESCAPE, MOUSE_DOWN, SCROLL } from "./gesture.ts";
import {
  pzAppInit,
  pzAppRun,
  pzIsTrusted,
  pzMenuBarHeight,
  pzMonitorStart,
  pzNowMs,
  pzPanelAddButton,
  pzPanelAddSeparator,
  pzPanelClear,
  pzPanelCreate,
  pzPanelHide,
  pzPanelPress,
  pzPanelSetFrame,
  pzPanelSetLabelColor,
  pzPanelShow,
  pzRssBytes,
  pzSchedule,
  pzScreenHeight,
  pzScreenWidth,
  pzSetClickHandler,
  pzSetTimerHandler,
  pzTextWidth,
} from "./native.ts";
import { calculatePlacement, rectContains } from "./placement.ts";
import { layoutPopup, type Theme, themeFor } from "./popup.ts";
import { grabSelection, nativeSystem } from "./system.ts";
import type { Action, Rect } from "./types.ts";

const GRAB_DELAY_MS = 45;
const TIMER_GRAB = 1;
const TIMER_EXIT = 2;
const TIMER_PRESS = 3;
const PRESS_DELAY_MS = 300;

export interface DaemonOptions {
  simulateText: string;
  trace: boolean;
  exitAfterShowMs: number;
  pressIndex: number;
}

export class Daemon {
  cfg: Config;
  theme: Theme;
  opts: DaemonOptions;
  gesture = new GestureTracker();
  actions: Action[] = [];
  selectedText = "";
  frame: Rect = { x: 0, y: 0, width: 0, height: 0 };
  visible = false;
  pendingX = 0;
  pendingY = 0;
  mouseUpAt = 0;

  constructor(cfg: Config, opts: DaemonOptions) {
    this.cfg = cfg;
    this.theme = themeFor(cfg.theme);
    this.opts = opts;
  }

  trace(message: string): void {
    if (this.opts.trace) console.error(`[popzlip] ${message}`);
  }

  start(): void {
    const startedAt = pzNowMs();
    pzAppInit();
    const bg = this.theme.background;
    pzPanelCreate(this.theme.radius, bg.r, bg.g, bg.b, bg.a);
    const label = this.theme.label;
    pzPanelSetLabelColor(label.r, label.g, label.b, label.a);
    pzSetClickHandler((index: number) => this.onClick(index));
    pzSetTimerHandler((timerId: number) => this.onTimer(timerId));

    if (this.opts.simulateText.length > 0) {
      this.present(this.opts.simulateText, pzScreenWidth() / 2, pzScreenHeight() / 2);
      this.trace(`startup to popup: ${(pzNowMs() - startedAt).toFixed(2)} ms`);
    } else if (
      pzMonitorStart((kind: number, x: number, y: number, detail: number) => this.onEvent(kind, x, y, detail))
    ) {
      console.log("popzlip daemon active: listening for text selections.");
    } else {
      console.error("Could not start the event tap. Grant Accessibility access to popzlip, then restart it.");
    }
    if (!pzIsTrusted()) this.trace("Accessibility access is not granted.");
    if (this.opts.pressIndex >= 0) pzSchedule(PRESS_DELAY_MS, TIMER_PRESS);
    if (this.opts.exitAfterShowMs > 0) pzSchedule(this.opts.exitAfterShowMs, TIMER_EXIT);
    pzAppRun();
  }

  onEvent(kind: number, x: number, y: number, detail: number): void {
    if (kind === MOUSE_DOWN && this.visible && !rectContains(this.frame, x, y)) this.dismiss();
    else if (kind === SCROLL && this.visible) this.dismiss();
    else if (kind === KEY_DOWN && detail === KEY_ESCAPE && this.visible) this.dismiss();
    if (this.gesture.handle(kind, x, y, detail) === "select") {
      this.pendingX = x;
      this.pendingY = y;
      this.mouseUpAt = pzNowMs();
      pzSchedule(GRAB_DELAY_MS, TIMER_GRAB);
    }
  }

  onTimer(timerId: number): void {
    if (timerId === TIMER_EXIT) process.exit(0);
    if (timerId === TIMER_PRESS && !pzPanelPress(this.opts.pressIndex)) this.trace("no button to press");
    if (timerId !== TIMER_GRAB) return;
    const grabStart = pzNowMs();
    const text = grabSelection();
    const grabMs = pzNowMs() - grabStart;
    if (text.length === 0) return;
    this.present(text, this.pendingX, this.pendingY);
    this.trace(
      `grab ${grabMs.toFixed(2)} ms, mouse-up to popup ${(pzNowMs() - this.mouseUpAt).toFixed(2)} ms, rss ${(pzRssBytes() / 1048576).toFixed(1)} MB`,
    );
  }

  present(text: string, x: number, y: number): void {
    const all = getActionsForSelection(text, true);
    const shown = filterActions(all, popupActionIds(this.cfg));
    if (shown.length === 0) return;
    this.selectedText = text;
    this.actions = shown;
    const theme = this.theme;
    const layout = layoutPopup(shown, theme, (s: string) => pzTextWidth(s, theme.fontSize, false));
    const placement = calculatePlacement({ x, y, width: 1, height: 1 }, layout.width, layout.height, {
      width: pzScreenWidth(),
      height: pzScreenHeight(),
      menuBarHeight: pzMenuBarHeight(),
      margin: 12,
    });
    pzPanelSetFrame(placement.x, placement.y, layout.width, layout.height);
    pzPanelClear();
    const sep = theme.separator;
    for (const s of layout.separators) pzPanelAddSeparator(s.x, s.y, s.height, sep.r, sep.g, sep.b, sep.a);
    for (const b of layout.buttons)
      pzPanelAddButton(b.actionIndex, b.label, b.x, b.y, b.width, b.height, theme.fontSize);
    pzPanelShow();
    this.frame = { x: placement.x, y: placement.y, width: layout.width, height: layout.height };
    this.visible = true;
  }

  onClick(index: number): void {
    const act = this.actions[index];
    if (act === undefined) return;
    const result = executeAction(act, this.selectedText, this.cfg, nativeSystem);
    this.trace(`${act.id}: ${result}`);
    this.dismiss();
  }

  dismiss(): void {
    pzPanelHide();
    this.visible = false;
  }
}
