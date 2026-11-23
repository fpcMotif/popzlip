import type { SystemPort } from "./executor.ts";
import {
  pzAxSelectedText,
  pzFrontmostPid,
  pzGuidancePanelCreate,
  pzGuidancePanelHide,
  pzGuidancePanelSetFrame,
  pzGuidancePanelSetPhase,
  pzGuidancePanelShow,
  pzGuidancePanelVisible,
  pzGuidanceSchedule,
  pzIsTrusted,
  pzLocateSettingsWindow,
  pzOpenAccessibilitySettings,
  pzOpenUrl,
  pzPbChangeCount,
  pzPbRead,
  pzPbRestore,
  pzPbSnapshot,
  pzPbWrite,
  pzPressCopyMenu,
  pzRunAppleScript,
  pzRunShell,
  pzScreenHeight,
  pzScreenWidth,
  pzSelfPid,
  pzSetActivationHandler,
  pzSetGuidanceDismissHandler,
  pzSetGuidanceTimerHandler,
  pzSleepMs,
} from "./native.ts";
import type { GuidancePort, Schedule } from "./permission.ts";
import type { Rect } from "./types.ts";

const READ_CAPACITY = 1 << 20;
const COPY_POLL_MS = 5;
const COPY_POLL_TRIES = 15;

let scratch = new Uint8Array(READ_CAPACITY);

function readInto(read: (out: Uint8Array) => number): string {
  let n = read(scratch);
  if (n < 0) {
    scratch = new Uint8Array(-n);
    n = read(scratch);
  }
  return n > 0 ? Buffer.from(scratch.subarray(0, n)).toString("utf8") : "";
}

export function readClipboard(): string {
  return readInto((out) => pzPbRead(out));
}

export const nativeSystem: SystemPort = {
  readClipboard,
  writeClipboard: (text: string) => pzPbWrite(text),
  openUrl: (url: string) => pzOpenUrl(url),
  runAppleScript: (source: string) => pzRunAppleScript(source),
  runShell: (command: string) => pzRunShell(command),
};

export function accessibilitySelection(): string {
  const pid = pzFrontmostPid();
  if (pid < 0 || pid === pzSelfPid()) return "";
  return readInto((out) => pzAxSelectedText(pid, out));
}

export function grabSelection(): string {
  const pid = pzFrontmostPid();
  if (pid < 0 || pid === pzSelfPid()) return "";
  const direct = readInto((out) => pzAxSelectedText(pid, out));
  if (direct.length > 0) return direct;

  pzPbSnapshot();
  const before = pzPbChangeCount();
  if (pzPressCopyMenu(pid) !== 1) return "";
  let copied = "";
  let changed = false;
  for (let i = 0; i < COPY_POLL_TRIES; i++) {
    pzSleepMs(COPY_POLL_MS);
    if (pzPbChangeCount() !== before) {
      changed = true;
      copied = readClipboard();
      break;
    }
  }
  if (changed) pzPbRestore();
  return copied;
}

const guidanceTimers = new Map<number, () => void>();
let nextGuidanceTimerId = 0;

export const nativeSchedule: Schedule = (delayMs, run) => {
  if (nextGuidanceTimerId === 0) {
    pzSetGuidanceTimerHandler((timerId: number) => {
      const timer = guidanceTimers.get(timerId);
      guidanceTimers.delete(timerId);
      timer?.();
    });
  }
  nextGuidanceTimerId += 1;
  guidanceTimers.set(nextGuidanceTimerId, run);
  pzGuidanceSchedule(delayMs, nextGuidanceTimerId);
};

export function locateSettingsWindow(): Rect | null {
  const buf = new Uint8Array(32);
  if (!pzLocateSettingsWindow(buf)) return null;
  const view = new DataView(buf.buffer, buf.byteOffset, 32);
  return {
    x: view.getFloat64(0, true),
    y: view.getFloat64(8, true),
    width: view.getFloat64(16, true),
    height: view.getFloat64(24, true),
  };
}

export const nativeGuidancePort: GuidancePort = {
  createPanel: (bundleUrl: string) => pzGuidancePanelCreate(bundleUrl),
  showPanel: (x: number, y: number, width: number, height: number) => pzGuidancePanelShow(x, y, width, height),
  setPanelFrame: (x: number, y: number, width: number, height: number, animate: boolean) =>
    pzGuidancePanelSetFrame(x, y, width, height, animate),
  setPanelPhase: (phase: number) => pzGuidancePanelSetPhase(phase),
  hidePanel: () => pzGuidancePanelHide(),
  isPanelVisible: () => pzGuidancePanelVisible(),
  setDismissHandler: (handler: (actionId: number) => void) => pzSetGuidanceDismissHandler(handler),
  setActivationHandler: (handler: (actionId: number) => void) => pzSetActivationHandler(handler),
  locateSettingsWindow: () => locateSettingsWindow(),
  openAccessibilitySettings: () => pzOpenAccessibilitySettings(),
  isTrusted: () => pzIsTrusted(),
  screenWidth: () => pzScreenWidth(),
  screenHeight: () => pzScreenHeight(),
};
