#import "event_tap.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <unistd.h>

static CFMachPortRef g_event_tap = NULL;
static CFRunLoopSourceRef g_run_loop_source = NULL;
static SelectionTriggerCallback g_trigger_cb = NULL;
static DismissCallback g_dismiss_cb = NULL;
static void *g_user_data = NULL;

static double g_win_x = 0;
static double g_win_y = 0;
static double g_win_w = 0;
static double g_win_h = 0;
static bool g_win_visible = false;

static double g_down_x = 0;
static double g_down_y = 0;
static bool g_is_dragging = false;
static int g_drag_count = 0;

void popzlip_set_window_frame(double x, double y, double w, double h) {
    g_win_x = x;
    g_win_y = y;
    g_win_w = w;
    g_win_h = h;
}

bool popzlip_is_window_visible(void) {
    return g_win_visible;
}

void popzlip_mark_window_visible(bool visible) {
    g_win_visible = visible;
}

int popzlip_grab_selection(char *out_buf, int max_len) {
    @autoreleasepool {
        NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (frontApp && frontApp.processIdentifier != getpid()) {
            AXUIElementRef appRef = AXUIElementCreateApplication(frontApp.processIdentifier);
            AXUIElementRef focused = NULL;
            if (AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess && focused) {
                CFTypeRef selText = NULL;
                if (AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, &selText) == kAXErrorSuccess && selText) {
                    NSString *str = (__bridge NSString *)selText;
                    if (str.length > 0) {
                        const char *utf = [str UTF8String];
                        int len = (int)strlen(utf);
                        if (len < max_len) {
                            memcpy(out_buf, utf, len);
                            out_buf[len] = 0;
                            CFRelease(selText);
                            CFRelease(focused);
                            CFRelease(appRef);
                            return len;
                        }
                    }
                    CFRelease(selText);
                }
                CFRelease(focused);
            }
            CFRelease(appRef);
        }

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSInteger initialCount = [pb changeCount];

        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef keyDown = CGEventCreateKeyboardEvent(src, 0x08, true);
        CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, keyDown);

        CGEventRef keyUp = CGEventCreateKeyboardEvent(src, 0x08, false);
        CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, keyUp);

        CFRelease(keyDown);
        CFRelease(keyUp);
        CFRelease(src);

        for (int i = 0; i < 15; i++) {
            usleep(5000);
            if ([pb changeCount] != initialCount) {
                NSString *copied = [pb stringForType:NSPasteboardTypeString];
                if (copied && copied.length > 0) {
                    const char *utf = [copied UTF8String];
                    int len = (int)strlen(utf);
                    if (len < max_len) {
                        memcpy(out_buf, utf, len);
                        out_buf[len] = 0;
                        return len;
                    }
                }
            }
        }
    }
    return 0;
}

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventLeftMouseDown) {
        CGPoint pt = CGEventGetLocation(event);
        if (g_win_visible) {
            bool inside = (pt.x >= g_win_x && pt.x <= g_win_x + g_win_w &&
                           pt.y >= g_win_y && pt.y <= g_win_y + g_win_h);
            if (!inside && g_dismiss_cb) {
                g_dismiss_cb(g_user_data);
            }
        }
        g_down_x = pt.x;
        g_down_y = pt.y;
        g_is_dragging = false;
        g_drag_count = 0;
    } else if (type == kCGEventLeftMouseDragged) {
        g_drag_count++;
        if (g_drag_count >= 2) {
            g_is_dragging = true;
        }
    } else if (type == kCGEventLeftMouseUp) {
        CGPoint pt = CGEventGetLocation(event);
        double dx = pt.x - g_down_x;
        double dy = pt.y - g_down_y;
        int64_t clickCount = CGEventGetIntegerValueField(event, kCGMouseEventClickState);

        bool isSelect = (g_is_dragging && (dx * dx + dy * dy >= 16.0)) || (clickCount >= 2);
        g_is_dragging = false;
        g_drag_count = 0;

        if (isSelect && g_trigger_cb) {
            char buf[4096];
            int len = popzlip_grab_selection(buf, sizeof(buf));
            if (len > 0) {
                g_trigger_cb(pt.x, pt.y, buf, g_user_data);
            }
        }
    } else if (type == kCGEventScrollWheel) {
        if (g_win_visible && g_dismiss_cb) {
            g_dismiss_cb(g_user_data);
        }
    } else if (type == kCGEventKeyDown) {
        int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == 0x35 && g_win_visible && g_dismiss_cb) {
            g_dismiss_cb(g_user_data);
        }
    }

    return event;
}

int popzlip_start_event_monitor(SelectionTriggerCallback trigger_cb, DismissCallback dismiss_cb, void *user_data) {
    g_trigger_cb = trigger_cb;
    g_dismiss_cb = dismiss_cb;
    g_user_data = user_data;

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventScrollWheel) |
                       CGEventMaskBit(kCGEventKeyDown);

    g_event_tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        mask,
        eventTapCallback,
        NULL
    );

    if (!g_event_tap) {
        return -1;
    }

    g_run_loop_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_event_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_run_loop_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);

    return 0;
}

void popzlip_stop_event_monitor(void) {
    if (g_event_tap) {
        CGEventTapEnable(g_event_tap, false);
        if (g_run_loop_source) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), g_run_loop_source, kCFRunLoopCommonModes);
            CFRelease(g_run_loop_source);
            g_run_loop_source = NULL;
        }
        CFRelease(g_event_tap);
        g_event_tap = NULL;
    }
}
