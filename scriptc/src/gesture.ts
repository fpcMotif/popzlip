export const MOUSE_DOWN = 1;
export const MOUSE_DRAGGED = 2;
export const MOUSE_UP = 3;
export const SCROLL = 4;
export const KEY_DOWN = 5;
export const KEY_ESCAPE = 0x35;

const MIN_DRAG_DISTANCE_SQ = 16;
const MIN_DRAG_EVENTS = 2;

export type GestureResult = "none" | "select" | "press";

export class GestureTracker {
  downX = 0;
  downY = 0;
  dragEvents = 0;

  handle(kind: number, x: number, y: number, detail: number): GestureResult {
    if (kind === MOUSE_DOWN) {
      this.downX = x;
      this.downY = y;
      this.dragEvents = 0;
      return "press";
    }
    if (kind === MOUSE_DRAGGED) {
      this.dragEvents++;
      return "none";
    }
    if (kind === MOUSE_UP) {
      const dx = x - this.downX;
      const dy = y - this.downY;
      const dragged = this.dragEvents >= MIN_DRAG_EVENTS && dx * dx + dy * dy >= MIN_DRAG_DISTANCE_SQ;
      this.dragEvents = 0;
      return dragged || detail >= 2 ? "select" : "none";
    }
    return "none";
  }
}
