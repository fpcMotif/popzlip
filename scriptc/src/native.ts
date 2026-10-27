export declare function pzAppInit(): void;
export declare function pzAppRun(): void;
export declare function pzAppQuit(): void;
export declare function pzRssBytes(): number;
export declare function pzNowMs(): number;
export declare function pzIsTrusted(): boolean;
export declare function pzSetTimerHandler(handler: (timerId: number) => void): void;
export declare function pzSchedule(delayMs: number, timerId: number): void;
export declare function pzSleepMs(ms: number): void;
export declare function pzMonitorStart(
  handler: (kind: number, x: number, y: number, detail: number) => void,
): boolean;
export declare function pzFrontmostPid(): number;
export declare function pzSelfPid(): number;
export declare function pzAxSelectedText(pid: number, out: Uint8Array): number;
export declare function pzPressCopyMenu(pid: number): number;
export declare function pzPbChangeCount(): number;
export declare function pzPbRead(out: Uint8Array): number;
export declare function pzPbWrite(text: string): void;
export declare function pzPbSnapshot(): void;
export declare function pzPbRestore(): void;
export declare function pzOpenUrl(url: string): boolean;
export declare function pzRunAppleScript(source: string): boolean;
export declare function pzRunShell(command: string): boolean;
export declare function pzScreenWidth(): number;
export declare function pzScreenHeight(): number;
export declare function pzMenuBarHeight(): number;
export declare function pzTextWidth(text: string, size: number, bold: boolean): number;
export declare function pzSetClickHandler(handler: (actionId: number) => void): void;
export declare function pzPanelCreate(radius: number, r: number, g: number, b: number, a: number): void;
export declare function pzPanelSetLabelColor(r: number, g: number, b: number, a: number): void;
export declare function pzPanelClear(): void;
export declare function pzPanelAddButton(
  actionId: number,
  label: string,
  x: number,
  y: number,
  width: number,
  height: number,
  fontSize: number,
): void;
export declare function pzPanelAddSeparator(
  x: number,
  y: number,
  height: number,
  r: number,
  g: number,
  b: number,
  a: number,
): void;
export declare function pzPanelSetFrame(x: number, y: number, width: number, height: number): void;
export declare function pzPanelShow(): void;
export declare function pzPanelHide(): void;
export declare function pzPanelVisible(): boolean;
export declare function pzPanelPress(actionId: number): boolean;
