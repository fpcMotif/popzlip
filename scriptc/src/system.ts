import type { SystemPort } from "./executor.ts";
import {
  pzAxSelectedText,
  pzFrontmostPid,
  pzOpenUrl,
  pzPbChangeCount,
  pzPbRead,
  pzPbRestore,
  pzPbSnapshot,
  pzPbWrite,
  pzPressCopyMenu,
  pzRunAppleScript,
  pzRunShell,
  pzSelfPid,
  pzSleepMs,
} from "./native.ts";

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
