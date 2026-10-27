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

void popzlip_get_screen_size(double *out_w, double *out_h) {
    NSScreen *screen = [NSScreen mainScreen];
    if (screen) {
        *out_w = screen.frame.size.width;
        *out_h = screen.frame.size.height;
    } else {
        *out_w = 1920.0;
        *out_h = 1080.0;
    }
}

void popzlip_show_window_without_focus(void *nswindow) {
    NSWindow *win = (__bridge NSWindow *)nswindow;
    if ([win isKindOfClass:[NSPanel class]]) {
        [(NSPanel *)win setBecomesKeyOnlyIfNeeded:YES];
    }
    [win orderFrontRegardless];
}

static NSArray<NSPasteboardItem *> *snapshotPasteboard(NSPasteboard *pb) {
    NSMutableArray<NSPasteboardItem *> *copies = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) [copy setData:data forType:type];
        }
        [copies addObject:copy];
    }
    return copies;
}

static AXUIElementRef getCopyMenuItem(AXUIElementRef appRef) {
    CFTypeRef menuBarRef = NULL;
    if (AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute, &menuBarRef) != kAXErrorSuccess || !menuBarRef) {
        return NULL;
    }
    CFTypeRef menusRef = NULL;
    if (AXUIElementCopyAttributeValue((AXUIElementRef)menuBarRef, kAXChildrenAttribute, &menusRef) != kAXErrorSuccess || !menusRef) {
        CFRelease(menuBarRef);
        return NULL;
    }
    NSArray *menus = (__bridge NSArray *)menusRef;
    NSUInteger checkIndices[] = {3, 2, 4, 1, 5};
    for (size_t idx = 0; idx < sizeof(checkIndices) / sizeof(checkIndices[0]); idx++) {
        NSUInteger i = checkIndices[idx];
        if (i >= menus.count) continue;
        AXUIElementRef menu = (__bridge AXUIElementRef)menus[i];
        CFTypeRef subRef = NULL;
        if (AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute, &subRef) == kAXErrorSuccess && subRef) {
            NSArray *subs = (__bridge NSArray *)subRef;
            if (subs.count > 0) {
                AXUIElementRef actualMenu = (__bridge AXUIElementRef)subs[0];
                CFTypeRef itemsRef = NULL;
                if (AXUIElementCopyAttributeValue(actualMenu, kAXChildrenAttribute, &itemsRef) == kAXErrorSuccess && itemsRef) {
                    NSArray *items = (__bridge NSArray *)itemsRef;
                    for (id it in items) {
                        CFTypeRef titleRef = NULL;
                        AXUIElementCopyAttributeValue((__bridge AXUIElementRef)it, kAXTitleAttribute, &titleRef);
                        NSString *title = (__bridge NSString *)titleRef;
                        if (title && ([title isEqualToString:@"Copy"] || [title isEqualToString:@"拷贝"] || [title isEqualToString:@"复制"])) {
                            if (titleRef) CFRelease(titleRef);
                            CFRetain((__bridge CFTypeRef)it);
                            CFRelease(itemsRef);
                            CFRelease(subRef);
                            CFRelease(menusRef);
                            CFRelease(menuBarRef);
                            return (__bridge AXUIElementRef)it;
                        }
                        if (titleRef) CFRelease(titleRef);
                    }
                    CFRelease(itemsRef);
                }
            }
            CFRelease(subRef);
        }
    }
    CFRelease(menusRef);
    CFRelease(menuBarRef);
    return NULL;
}

int popzlip_grab_selection(char *out_buf, int max_len) {
    @autoreleasepool {
        NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (!frontApp || frontApp.processIdentifier == getpid()) {
            return 0;
        }

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

        AXUIElementRef copyItem = getCopyMenuItem(appRef);
        if (copyItem) {
            CFTypeRef enabledRef = NULL;
            AXUIElementCopyAttributeValue(copyItem, kAXEnabledAttribute, &enabledRef);
            BOOL enabled = enabledRef ? [(__bridge NSNumber *)enabledRef boolValue] : NO;
            if (enabledRef) CFRelease(enabledRef);

            if (!enabled) {
                CFRelease(copyItem);
                CFRelease(appRef);
                return 0;
            }

            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            NSArray<NSPasteboardItem *> *savedItems = snapshotPasteboard(pb);
            NSInteger initialCount = [pb changeCount];

            AXUIElementPerformAction(copyItem, kAXPressAction);
            CFRelease(copyItem);
            CFRelease(appRef);

            int result = 0;
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
                            result = len;
                        }
                    }
                    break;
                }
            }
            if ([pb changeCount] != initialCount) {
                [pb clearContents];
                if (savedItems.count > 0) [pb writeObjects:savedItems];
            }
            return result;
        }

        CFRelease(appRef);
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                char buf[4096];
                int len = popzlip_grab_selection(buf, sizeof(buf));
                if (len > 0) {
                    g_trigger_cb(pt.x, pt.y, buf, g_user_data);
                }
            });
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
