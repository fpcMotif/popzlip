import { describe, expect, test } from "bun:test";
import { GuidancePanelAnchorPolicy, type ScreenBounds } from "../src/guidance-policy.ts";
import { AccessibilityGrantCoordinator, type GuidancePort } from "../src/permission.ts";
import type { Rect } from "../src/types.ts";

describe("GuidancePanelAnchorPolicy", () => {
  const screen: ScreenBounds = { x: 0, y: 0, width: 1440, height: 900 };
  const panelSize = { width: 380, height: 110 };

  test("centered target window positions HUD directly below with overlap", () => {
    const target: Rect = { x: 400, y: 300, width: 640, height: 480 };
    const frame = GuidancePanelAnchorPolicy.computeFrame(target, null, screen, panelSize);

    expect(frame.width).toBe(380);
    expect(frame.height).toBe(110);
    expect(frame.x).toBe(530);
    expect(frame.y).toBe(210);
  });

  test("target window near bottom clamps within screen bounds", () => {
    const target: Rect = { x: 400, y: 40, width: 640, height: 480 };
    const frame = GuidancePanelAnchorPolicy.computeFrame(target, null, screen, panelSize);

    expect(frame.x).toBe(530);
    expect(frame.y).toBe(8);
  });

  test("target window near right clamps within screen bounds", () => {
    const target: Rect = { x: 1200, y: 300, width: 400, height: 400 };
    const frame = GuidancePanelAnchorPolicy.computeFrame(target, null, screen, panelSize);

    expect(frame.x + frame.width).toBeLessThanOrEqual(screen.width - 12);
    expect(frame.width).toBe(380);
  });

  test("target window near left clamps within screen bounds", () => {
    const target: Rect = { x: -100, y: 300, width: 400, height: 400 };
    const frame = GuidancePanelAnchorPolicy.computeFrame(target, null, screen, panelSize);

    expect(frame.x).toBeGreaterThanOrEqual(screen.x + 12);
    expect(frame.width).toBe(380);
  });

  test("fallback to parent window when target is missing", () => {
    const parent: Rect = { x: 200, y: 200, width: 600, height: 400 };
    const frame = GuidancePanelAnchorPolicy.computeFrame(null, parent, screen, panelSize);

    expect(frame.x).toBe(310);
    expect(frame.y).toBe(106);
  });

  test("fallback to screen center when both target and parent are missing", () => {
    const frame = GuidancePanelAnchorPolicy.computeFrame(null, null, screen, panelSize);

    expect(frame.x).toBe(530);
    expect(frame.y).toBe(80);
  });

  test("quartz to cocoa coordinate conversion inverts Y from top-left", () => {
    const quartzRect: Rect = { x: 100, y: 100, width: 400, height: 300 };
    const cocoaRect = GuidancePanelAnchorPolicy.convertToCocoa(quartzRect, 900);

    expect(cocoaRect.x).toBe(100);
    expect(cocoaRect.y).toBe(500);
    expect(cocoaRect.width).toBe(400);
    expect(cocoaRect.height).toBe(300);
  });
});

describe("AccessibilityGrantCoordinator", () => {
  const screen: ScreenBounds = { x: 0, y: 0, width: 1440, height: 900 };

  test("initial phase is idle", () => {
    const coordinator = new AccessibilityGrantCoordinator({
      autoPresentPanel: false,
    });
    expect(coordinator.phase).toBe("idle");
  });

  test("beginGrantFlow when already granted transitions directly to granted and calls onGranted", () => {
    let grantedCalls = 0;
    let settingsCalls = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => true,
      openSettings: () => {
        settingsCalls++;
        return true;
      },
      onGranted: () => {
        grantedCalls++;
      },
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    expect(coordinator.phase).toBe("granted");
    expect(grantedCalls).toBe(1);
    expect(settingsCalls).toBe(0);
  });

  test("beginGrantFlow when not granted opens settings, presents guidance, and starts polling", () => {
    let settingsCalls = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => false,
      openSettings: () => {
        settingsCalls++;
        return true;
      },
      screenProvider: () => screen,
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    expect(coordinator.phase).toBe("presentingGuidance");
    expect(settingsCalls).toBe(1);

    coordinator.beginGrantFlow();
    expect(settingsCalls).toBe(1);

    coordinator.dismiss();
  });
});

describe("AccessibilityGrantCoordinator polling", () => {
  const screen: ScreenBounds = { x: 0, y: 0, width: 1440, height: 900 };

  test("poll detects grant transitions to granted and calls onGranted", () => {
    let granted = false;
    let grantedCalls = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => granted,
      openSettings: () => true,
      onGranted: () => {
        grantedCalls++;
      },
      screenProvider: () => screen,
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    expect(coordinator.phase).toBe("presentingGuidance");
    expect(grantedCalls).toBe(0);

    coordinator.poll();
    expect(coordinator.phase).toBe("presentingGuidance");
    expect(grantedCalls).toBe(0);

    granted = true;
    coordinator.poll();
    expect(coordinator.phase).toBe("granted");
    expect(grantedCalls).toBe(1);

    coordinator.dismiss();
  });
});

describe("AccessibilityGrantCoordinator anchoring", () => {
  const screen: ScreenBounds = { x: 0, y: 0, width: 1440, height: 900 };

  test("poll updates anchor frame when target window moves", () => {
    let currentTarget: Rect | null = { x: 400, y: 300, width: 640, height: 480 };

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => false,
      openSettings: () => true,
      targetWindowLocator: () => currentTarget,
      screenProvider: () => screen,
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    const initialFrame = GuidancePanelAnchorPolicy.computeFrame(currentTarget, null, screen);
    coordinator.currentFrame = initialFrame;
    expect(coordinator.currentFrame.x).toBe(530);
    expect(coordinator.currentFrame.y).toBe(210);

    currentTarget = { x: 600, y: 350, width: 640, height: 480 };
    coordinator.poll();
    const updatedFrame = GuidancePanelAnchorPolicy.computeFrame(currentTarget, null, screen);
    expect(updatedFrame.x).toBe(730);
    expect(updatedFrame.y).toBe(260);

    coordinator.dismiss();
  });

  test("dismiss cancels polling and transitions to dismissed", () => {
    let dismissedCalls = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => false,
      openSettings: () => true,
      onDismissed: () => {
        dismissedCalls++;
      },
      screenProvider: () => screen,
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    expect(coordinator.phase).toBe("presentingGuidance");

    coordinator.dismiss();
    expect(coordinator.phase).toBe("dismissed");
    expect(dismissedCalls).toBe(1);

    coordinator.poll();
    expect(coordinator.phase).toBe("dismissed");
  });
});

function fakePort(calls: string[]): GuidancePort {
  return {
    createPanel: () => calls.push("create"),
    showPanel: () => calls.push("show"),
    setPanelFrame: () => calls.push("frame"),
    setPanelPhase: (phase) => calls.push(`phase:${phase}`),
    hidePanel: () => calls.push("hide"),
    isPanelVisible: () => true,
    setDismissHandler: () => calls.push("dismiss-handler"),
    setActivationHandler: () => calls.push("activation-handler"),
    locateSettingsWindow: () => null,
    openAccessibilitySettings: () => true,
    isTrusted: () => false,
    screenWidth: () => 1440,
    screenHeight: () => 900,
  };
}

describe("AccessibilityGrantCoordinator scheduling", () => {
  test("polls through the injected schedule and hides the HUD after the grant", () => {
    const pending: (() => void)[] = [];
    const calls: string[] = [];
    let granted = false;
    let dismissedCalls = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      port: fakePort(calls),
      isGranted: () => granted,
      schedule: (_delayMs, run) => pending.push(run),
      onDismissed: () => {
        dismissedCalls++;
      },
    });

    coordinator.beginGrantFlow();
    expect(pending.length).toBe(1);

    pending.shift()?.();
    expect(coordinator.phase).toBe("presentingGuidance");
    expect(pending.length).toBe(1);

    granted = true;
    pending.shift()?.();
    expect(coordinator.phase).toBe("granted");
    expect(calls).toContain("phase:1");
    expect(calls).not.toContain("hide");

    pending.shift()?.();
    expect(coordinator.phase).toBe("dismissed");
    expect(calls).toContain("hide");
    expect(dismissedCalls).toBe(1);
    expect(pending.length).toBe(0);
  });

  test("dismiss cancels a poll that is already scheduled", () => {
    const pending: (() => void)[] = [];
    let pollChecks = 0;

    const coordinator = new AccessibilityGrantCoordinator({
      isGranted: () => {
        pollChecks++;
        return false;
      },
      openSettings: () => true,
      schedule: (_delayMs, run) => pending.push(run),
      autoPresentPanel: false,
    });

    coordinator.beginGrantFlow();
    const checksBeforeDismiss = pollChecks;
    coordinator.dismiss();
    pending.shift()?.();

    expect(pollChecks).toBe(checksBeforeDismiss);
    expect(pending.length).toBe(0);
  });
});
