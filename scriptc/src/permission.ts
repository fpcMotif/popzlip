import { GuidancePanelAnchorPolicy, type PanelSize, type ScreenBounds } from "./guidance-policy.ts";
import type { Rect } from "./types.ts";

export type AccessibilityGrantPhase = "idle" | "presentingGuidance" | "granted" | "dismissed";

export type Schedule = (delayMs: number, run: () => void) => void;

export interface GuidancePort {
  createPanel(bundleUrl: string): void;
  showPanel(x: number, y: number, width: number, height: number): void;
  setPanelFrame(x: number, y: number, width: number, height: number, animate: boolean): void;
  setPanelPhase(phase: number): void;
  hidePanel(): void;
  isPanelVisible(): boolean;
  setDismissHandler(handler: (actionId: number) => void): void;
  setActivationHandler(handler: (actionId: number) => void): void;
  locateSettingsWindow(): Rect | null;
  openAccessibilitySettings(): boolean;
  isTrusted(): boolean;
  screenWidth(): number;
  screenHeight(): number;
}

export interface CoordinatorOptions {
  port?: GuidancePort;
  openSettings?: () => boolean;
  isGranted?: () => boolean;
  targetWindowLocator?: () => Rect | null;
  parentWindowProvider?: () => Rect | null;
  screenProvider?: () => ScreenBounds;
  schedule?: Schedule;
  onGranted?: () => void;
  onDismissed?: () => void;
  autoPresentPanel?: boolean;
  panelSize?: PanelSize;
  pollIntervalMs?: number;
}

const GRANTED_HUD_MS = 1500;

const timerSchedule: Schedule = (delayMs, run) => {
  setTimeout(run, delayMs);
};

function portScreen(port: GuidancePort | undefined): ScreenBounds {
  const width = port?.screenWidth() ?? 0;
  const height = port?.screenHeight() ?? 0;
  return { x: 0, y: 0, width: width > 0 ? width : 1440, height: height > 0 ? height : 900 };
}

export class AccessibilityGrantCoordinator {
  phase: AccessibilityGrantPhase = "idle";
  private port: GuidancePort | null;
  private openSettings: () => boolean;
  private isGrantedProvider: () => boolean;
  private targetWindowLocator: () => Rect | null;
  private parentWindowProvider: (() => Rect | null) | null;
  private screenProvider: () => ScreenBounds;
  private schedule: Schedule;
  private onGrantedCallback: (() => void) | undefined;
  private onDismissedCallback: (() => void) | undefined;
  private autoPresentPanel: boolean;
  private panelSize: PanelSize;
  private pollIntervalMs: number;
  private timerGeneration = 0;
  currentFrame: Rect = { x: 0, y: 0, width: 380, height: 110 };

  constructor(options: CoordinatorOptions = {}) {
    const port = options.port;
    this.port = port ?? null;
    this.openSettings = options.openSettings ?? (() => port?.openAccessibilitySettings() ?? false);
    this.isGrantedProvider = options.isGranted ?? (() => port?.isTrusted() ?? false);
    this.targetWindowLocator = options.targetWindowLocator ?? (() => port?.locateSettingsWindow() ?? null);
    this.parentWindowProvider = options.parentWindowProvider ?? null;
    this.screenProvider = options.screenProvider ?? (() => portScreen(port));
    this.schedule = options.schedule ?? timerSchedule;
    this.onGrantedCallback = options.onGranted;
    this.onDismissedCallback = options.onDismissed;
    this.autoPresentPanel = options.autoPresentPanel ?? true;
    this.panelSize = options.panelSize ?? { width: 380, height: 110 };
    this.pollIntervalMs = options.pollIntervalMs ?? 500;
  }

  isGranted(): boolean {
    return this.isGrantedProvider();
  }

  beginGrantFlow(): void {
    if (this.isGrantedProvider()) {
      this.phase = "granted";
      this.onGrantedCallback?.();
      return;
    }

    if (this.phase === "presentingGuidance") {
      if (this.autoPresentPanel && this.port) {
        this.port.showPanel(
          this.currentFrame.x,
          this.currentFrame.y,
          this.currentFrame.width,
          this.currentFrame.height,
        );
      }
      return;
    }

    this.phase = "presentingGuidance";
    this.openSettings();

    if (this.autoPresentPanel && this.port) {
      this.port.createPanel("");
      this.port.setDismissHandler((_actionId: number) => this.dismiss());
      this.port.setActivationHandler((_actionId: number) => this.poll());

      const target = this.targetWindowLocator();
      const parent = this.parentWindowProvider ? this.parentWindowProvider() : null;
      const screen = this.screenProvider();
      this.currentFrame = GuidancePanelAnchorPolicy.computeFrame(target, parent, screen, this.panelSize);

      this.port.setPanelPhase(0);
      this.port.showPanel(this.currentFrame.x, this.currentFrame.y, this.currentFrame.width, this.currentFrame.height);
    }

    this.startPolling();
  }

  poll(): void {
    if (this.phase !== "presentingGuidance") return;

    if (this.isGrantedProvider()) {
      this.handleGrantDetected();
      return;
    }

    if (this.autoPresentPanel && this.port) {
      const target = this.targetWindowLocator();
      const parent = this.parentWindowProvider ? this.parentWindowProvider() : null;
      const screen = this.screenProvider();
      const newFrame = GuidancePanelAnchorPolicy.computeFrame(target, parent, screen, this.panelSize);

      if (Math.abs(newFrame.x - this.currentFrame.x) > 4 || Math.abs(newFrame.y - this.currentFrame.y) > 4) {
        this.currentFrame = newFrame;
        this.port.setPanelFrame(newFrame.x, newFrame.y, newFrame.width, newFrame.height, true);
      }
    }
  }

  dismiss(): void {
    if (this.phase === "dismissed") return;
    this.stopPolling();
    if (this.autoPresentPanel && this.port) {
      this.port.hidePanel();
    }
    this.phase = "dismissed";
    this.onDismissedCallback?.();
  }

  private handleGrantDetected(): void {
    this.stopPolling();
    this.phase = "granted";
    this.onGrantedCallback?.();

    if (this.autoPresentPanel && this.port) {
      this.port.setPanelPhase(1);
      const generation = this.timerGeneration;
      this.schedule(GRANTED_HUD_MS, () => {
        if (generation === this.timerGeneration) this.dismiss();
      });
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.schedulePoll(this.timerGeneration);
  }

  private schedulePoll(generation: number): void {
    this.schedule(this.pollIntervalMs, () => {
      if (generation !== this.timerGeneration) return;
      this.poll();
      if (this.phase === "presentingGuidance") this.schedulePoll(generation);
    });
  }

  private stopPolling(): void {
    this.timerGeneration += 1;
  }
}
