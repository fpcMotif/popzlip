import type { Rect } from "./types.ts";

export interface PanelSize {
  width: number;
  height: number;
}

export interface ScreenBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export class GuidancePanelAnchorPolicy {
  static computeFrame(
    targetWindow: Rect | null,
    parentWindow: Rect | null,
    screen: ScreenBounds,
    panelSize: PanelSize = { width: 380, height: 110 },
  ): Rect {
    if (targetWindow) {
      const midX = targetWindow.x + targetWindow.width / 2;
      const posX = midX - panelSize.width / 2;
      const posY = targetWindow.y - panelSize.height + 20;
      return GuidancePanelAnchorPolicy.clamp(
        { x: posX, y: posY, width: panelSize.width, height: panelSize.height },
        screen,
      );
    }

    if (parentWindow) {
      const midX = parentWindow.x + parentWindow.width / 2;
      const posX = midX - panelSize.width / 2;
      const posY = parentWindow.y - panelSize.height + 16;
      return GuidancePanelAnchorPolicy.clamp(
        { x: posX, y: posY, width: panelSize.width, height: panelSize.height },
        screen,
      );
    }

    const midX = screen.x + screen.width / 2;
    const posX = midX - panelSize.width / 2;
    const posY = screen.y + 80;
    return GuidancePanelAnchorPolicy.clamp(
      { x: posX, y: posY, width: panelSize.width, height: panelSize.height },
      screen,
    );
  }

  private static clamp(rect: Rect, screen: ScreenBounds): Rect {
    let x = rect.x;
    let y = rect.y;

    const minAllowedX = screen.x + 12;
    const maxAllowedX = screen.x + screen.width - rect.width - 12;

    if (maxAllowedX >= minAllowedX) {
      x = Math.min(Math.max(x, minAllowedX), maxAllowedX);
    } else {
      x = minAllowedX;
    }

    const minAllowedY = screen.y + 8;
    const maxAllowedY = screen.y + screen.height - rect.height - 8;

    if (maxAllowedY >= minAllowedY) {
      y = Math.min(Math.max(y, minAllowedY), maxAllowedY);
    } else {
      y = minAllowedY;
    }

    return { x, y, width: rect.width, height: rect.height };
  }

  static convertToCocoa(quartzBounds: Rect, primaryScreenHeight: number): Rect {
    const flippedY = primaryScreenHeight - quartzBounds.y - quartzBounds.height;
    return {
      x: quartzBounds.x,
      y: flippedY,
      width: quartzBounds.width,
      height: quartzBounds.height,
    };
  }
}
