#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <stdint.h>
#import <string.h>
#import <sys/sysctl.h>
#import <unistd.h>

typedef void (*pz_event_cb)(int32_t kind, double x, double y, int32_t detail, void *ctx);
typedef void (*pz_click_cb)(int32_t action_id, void *ctx);
typedef void (*pz_timer_cb)(int32_t timer_id, void *ctx);

enum { PZ_MOUSE_DOWN = 1, PZ_MOUSE_DRAGGED = 2, PZ_MOUSE_UP = 3, PZ_SCROLL = 4, PZ_KEY_DOWN = 5 };

static pz_event_cb g_event_cb = NULL;
static void *g_event_ctx = NULL;
static pz_click_cb g_click_cb = NULL;
static void *g_click_ctx = NULL;
static pz_timer_cb g_timer_cb = NULL;
static void *g_timer_ctx = NULL;

static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_tap_source = NULL;
static NSPanel *g_panel = nil;
static NSView *g_panel_content = nil;
static NSArray<NSPasteboardItem *> *g_saved_items = nil;
static NSColor *g_label_color = nil;

static NSString *pz_string(const uint8_t *bytes, size_t len) {
    if (len == 0) return @"";
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

static int32_t pz_copy_out(NSString *str, uint8_t *out, size_t cap) {
    if (!str) return 0;
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > cap) return -(int32_t)data.length;
    memcpy(out, data.bytes, data.length);
    return (int32_t)data.length;
}

void pz_settings_show(void);

@interface PZAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation PZAppDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    pz_settings_show();
    return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!AXIsProcessTrusted()) {
        pz_settings_show();
    }
}
@end

static PZAppDelegate *g_app_delegate = nil;

void pz_app_init(void) {
    [NSApplication sharedApplication];
    if (!g_app_delegate) {
        g_app_delegate = [[PZAppDelegate alloc] init];
        NSApp.delegate = g_app_delegate;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void pz_app_run(void) {
    [NSApp run];
}

void pz_app_quit(void) {
    [NSApp stop:nil];
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                      timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [NSApp postEvent:wake atStart:YES];
}

double pz_rss_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (double)info.resident_size;
}

double pz_now_ms(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

bool pz_is_trusted(void) {
    return AXIsProcessTrusted();
}

void pz_set_timer_handler(pz_timer_cb cb, void *ctx) {
    g_timer_cb = cb;
    g_timer_ctx = ctx;
}

void pz_schedule(double delay_ms, int32_t timer_id) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay_ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (g_timer_cb) g_timer_cb(timer_id, g_timer_ctx);
    });
}

void pz_sleep_ms(double ms) {
    usleep((useconds_t)(ms * 1000.0));
}

static bool pz_is_screencapture_active(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0 || size == 0) return false;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return false;
    bool active = false;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            const char *name = procs[i].kp_proc.p_comm;
            if (strcmp(name, "screencapture") == 0 || strcmp(name, "screencaptureui") == 0 ||
                strcmp(name, "Screenshot") == 0) {
                active = true;
                break;
            }
        }
    }
    free(procs);
    return active;
}

static CGEventRef pz_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }
    if (!g_event_cb) return event;
    CGPoint pt = CGEventGetLocation(event);
    switch (type) {
        case kCGEventLeftMouseDown:
            if (pz_is_screencapture_active()) return event;
            g_event_cb(PZ_MOUSE_DOWN, pt.x, pt.y, 0, g_event_ctx);
            break;
        case kCGEventLeftMouseDragged:
            g_event_cb(PZ_MOUSE_DRAGGED, pt.x, pt.y, 0, g_event_ctx);
            break;
        case kCGEventLeftMouseUp:
            if (pz_is_screencapture_active()) return event;
            g_event_cb(PZ_MOUSE_UP, pt.x, pt.y,
                       (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventClickState), g_event_ctx);
            break;
        case kCGEventScrollWheel:
            g_event_cb(PZ_SCROLL, pt.x, pt.y, 0, g_event_ctx);
            break;
        case kCGEventKeyDown:
            g_event_cb(PZ_KEY_DOWN, pt.x, pt.y,
                       (int32_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), g_event_ctx);
            break;
        default:
            break;
    }
    return event;
}

bool pz_monitor_start(pz_event_cb cb, void *ctx) {
    g_event_cb = cb;
    g_event_ctx = ctx;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventScrollWheel) |
                       CGEventMaskBit(kCGEventKeyDown);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask,
                             pz_tap_callback, NULL);
    if (!g_tap) return false;
    g_tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    return true;
}

int32_t pz_frontmost_pid(void) {
    if (pz_is_screencapture_active()) return -1;
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return front ? front.processIdentifier : -1;
}

int32_t pz_self_pid(void) {
    return getpid();
}

static AXUIElementRef pz_ax_focused_element(AXUIElementRef app) {
    AXUIElementRef focused = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess &&
        focused) {
        return focused;
    }
    AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess &&
        focused) {
        return focused;
    }
    return NULL;
}

static bool pz_ax_has_empty_or_non_text_focus(AXUIElementRef app) {
    AXUIElementRef focused = pz_ax_focused_element(app);
    if (!focused) return false;
    bool skip = false;
    CFTypeRef roleRef = NULL;
    if (AXUIElementCopyAttributeValue(focused, kAXRoleAttribute, &roleRef) == kAXErrorSuccess && roleRef) {
        if (CFGetTypeID(roleRef) == CFStringGetTypeID()) {
            NSString *role = (__bridge NSString *)roleRef;
            if ([role isEqualToString:@"AXOutline"] || [role isEqualToString:@"AXTable"] ||
                [role isEqualToString:@"AXList"] || [role isEqualToString:@"AXImage"]) {
                skip = true;
            } else if ([role isEqualToString:@"AXTextArea"] || [role isEqualToString:@"AXTextField"] ||
                       [role isEqualToString:@"AXComboBox"] || [role isEqualToString:@"AXSearchField"]) {
                CFTypeRef selected = NULL;
                if (AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, &selected) == kAXErrorSuccess &&
                    selected) {
                    if (CFGetTypeID(selected) == CFStringGetTypeID() &&
                        [(__bridge NSString *)selected length] == 0) {
                        skip = true;
                    }
                    CFRelease(selected);
                }
            }
        }
        CFRelease(roleRef);
    }
    CFRelease(focused);
    return skip;
}

int32_t pz_ax_selected_text(int32_t pid, uint8_t *out, size_t cap) {
    @autoreleasepool {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementRef focused = pz_ax_focused_element(app);
        int32_t result = 0;
        if (focused) {
            CFTypeRef selected = NULL;
            if (AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, &selected) == kAXErrorSuccess &&
                selected) {
                if (CFGetTypeID(selected) == CFStringGetTypeID()) {
                    result = pz_copy_out((__bridge NSString *)selected, out, cap);
                }
                CFRelease(selected);
            }
            CFRelease(focused);
        }
        CFRelease(app);
        return result;
    }
}

static AXUIElementRef pz_find_copy_item(AXUIElementRef app) {
    CFTypeRef bar = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, &bar) != kAXErrorSuccess || !bar) return NULL;
    CFTypeRef menus = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue((AXUIElementRef)bar, kAXChildrenAttribute, &menus) == kAXErrorSuccess && menus) {
        NSArray *top = (__bridge NSArray *)menus;
        NSUInteger order[] = {3, 2, 4, 1, 5};
        for (size_t k = 0; k < sizeof(order) / sizeof(order[0]) && !found; k++) {
            if (order[k] >= top.count) continue;
            CFTypeRef subs = NULL;
            if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)top[order[k]], kAXChildrenAttribute, &subs) !=
                    kAXErrorSuccess ||
                !subs)
                continue;
            NSArray *subArr = (__bridge NSArray *)subs;
            if (subArr.count > 0) {
                CFTypeRef items = NULL;
                if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)subArr[0], kAXChildrenAttribute, &items) ==
                        kAXErrorSuccess &&
                    items) {
                    for (id item in (__bridge NSArray *)items) {
                        CFTypeRef title = NULL;
                        AXUIElementCopyAttributeValue((__bridge AXUIElementRef)item, kAXTitleAttribute, &title);
                        NSString *t = (__bridge NSString *)title;
                        BOOL isCopy = t && ([t isEqualToString:@"Copy"] || [t isEqualToString:@"拷贝"] ||
                                            [t isEqualToString:@"复制"]);
                        if (title) CFRelease(title);
                        if (isCopy) {
                            found = (AXUIElementRef)CFRetain((__bridge CFTypeRef)item);
                            break;
                        }
                    }
                    CFRelease(items);
                }
            }
            CFRelease(subs);
        }
        CFRelease(menus);
    }
    CFRelease(bar);
    return found;
}

void pz_pb_snapshot(void);

int32_t pz_press_copy_menu(int32_t pid) {
    @autoreleasepool {
        if (pz_is_screencapture_active()) return 0;
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        if (pz_ax_has_empty_or_non_text_focus(app)) {
            CFRelease(app);
            return 0;
        }
        AXUIElementRef item = pz_find_copy_item(app);
        CFRelease(app);
        if (!item) return -1;
        CFTypeRef enabled = NULL;
        AXUIElementCopyAttributeValue(item, kAXEnabledAttribute, &enabled);
        BOOL on = enabled ? [(__bridge NSNumber *)enabled boolValue] : NO;
        if (enabled) CFRelease(enabled);
        if (on) {
            pz_pb_snapshot();
            AXUIElementPerformAction(item, kAXPressAction);
        }
        CFRelease(item);
        return on ? 1 : 0;
    }
}

int32_t pz_pb_change_count(void) {
    return (int32_t)[[NSPasteboard generalPasteboard] changeCount];
}

int32_t pz_pb_read(uint8_t *out, size_t cap) {
    @autoreleasepool {
        return pz_copy_out([[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString], out, cap);
    }
}

void pz_pb_write(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:pz_string(bytes, len) forType:NSPasteboardTypeString];
    }
}

void pz_pb_snapshot(void) {
    NSMutableArray<NSPasteboardItem *> *copies = [NSMutableArray array];
    for (NSPasteboardItem *item in [NSPasteboard generalPasteboard].pasteboardItems) {
        NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) [copy setData:data forType:type];
        }
        [copies addObject:copy];
    }
    g_saved_items = copies;
}

void pz_pb_restore(void) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (g_saved_items.count > 0) [pb writeObjects:g_saved_items];
    g_saved_items = nil;
}

bool pz_open_url(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:pz_string(bytes, len)];
        return url ? [[NSWorkspace sharedWorkspace] openURL:url] : false;
    }
}

bool pz_run_applescript(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:pz_string(bytes, len)];
        NSDictionary *error = nil;
        [script executeAndReturnError:&error];
        return error == nil;
    }
}

bool pz_run_shell(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
        task.arguments = @[ @"-c", pz_string(bytes, len) ];
        return [task launchAndReturnError:nil];
    }
}

double pz_screen_width(void) {
    NSScreen *primary = NSScreen.screens.firstObject;
    return primary ? primary.frame.size.width : 1920.0;
}

double pz_screen_height(void) {
    NSScreen *primary = NSScreen.screens.firstObject;
    return primary ? primary.frame.size.height : 1080.0;
}

double pz_menu_bar_height(void) {
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) return 24.0;
    return NSMaxY(primary.frame) - NSMaxY(primary.visibleFrame);
}

double pz_text_width(const uint8_t *bytes, size_t len, double size, bool bold) {
    @autoreleasepool {
        NSFont *font = bold ? [NSFont systemFontOfSize:size weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:size];
        return ceil([pz_string(bytes, len) sizeWithAttributes:@{NSFontAttributeName : font}].width);
    }
}

@interface PZButtonTarget : NSObject
@end

@implementation PZButtonTarget
- (void)clicked:(NSButton *)sender {
    if (g_click_cb) g_click_cb((int32_t)sender.tag, g_click_ctx);
}
@end

static PZButtonTarget *g_target = nil;

void pz_set_click_handler(pz_click_cb cb, void *ctx) {
    g_click_cb = cb;
    g_click_ctx = ctx;
}

static NSColor *pz_rgba(double r, double g, double b, double a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

void pz_panel_create(double radius, double r, double g, double b, double a) {
    if (g_panel) return;
    g_target = [[PZButtonTarget alloc] init];
    g_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 160, 32)
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    g_panel.opaque = NO;
    g_panel.backgroundColor = NSColor.clearColor;
    g_panel.hasShadow = YES;
    g_panel.level = NSPopUpMenuWindowLevel;
    g_panel.hidesOnDeactivate = NO;
    g_panel.becomesKeyOnlyIfNeeded = YES;
    g_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    g_panel_content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 160, 32)];
    g_panel_content.wantsLayer = YES;
    g_panel_content.layer.cornerRadius = radius;
    g_panel_content.layer.masksToBounds = YES;
    g_panel_content.layer.backgroundColor = pz_rgba(r, g, b, a).CGColor;
    g_panel.contentView = g_panel_content;
    g_label_color = NSColor.whiteColor;
}

void pz_panel_set_label_color(double r, double g, double b, double a) {
    g_label_color = pz_rgba(r, g, b, a);
}

void pz_panel_clear(void) {
    for (NSView *v in [g_panel_content.subviews copy]) [v removeFromSuperview];
}

void pz_panel_add_button(int32_t action_id, const uint8_t *label, size_t len, double x, double y, double w, double h,
                         double font_size) {
    NSRect bounds = g_panel_content.bounds;
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, bounds.size.height - y - h, w, h)];
    button.bordered = NO;
    button.tag = action_id;
    button.target = g_target;
    button.action = @selector(clicked:);
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:font_size weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : g_label_color
    };
    button.attributedTitle = [[NSAttributedString alloc] initWithString:pz_string(label, len) attributes:attrs];
    [g_panel_content addSubview:button];
}

void pz_panel_add_separator(double x, double y, double h, double r, double g, double b, double a) {
    NSRect bounds = g_panel_content.bounds;
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(x, bounds.size.height - y - h, 1, h)];
    line.wantsLayer = YES;
    line.layer.backgroundColor = pz_rgba(r, g, b, a).CGColor;
    [g_panel_content addSubview:line];
}

void pz_panel_set_frame(double x, double y, double w, double h) {
    double cocoaY = pz_screen_height() - y - h;
    [g_panel setFrame:NSMakeRect(x, cocoaY, w, h) display:NO];
    g_panel_content.frame = NSMakeRect(0, 0, w, h);
}

void pz_panel_show(void) {
    [g_panel orderFrontRegardless];
}

void pz_panel_hide(void) {
    [g_panel orderOut:nil];
}

bool pz_panel_visible(void) {
    return g_panel.visible;
}

bool pz_panel_press(int32_t action_id) {
    NSButton *button = [g_panel_content viewWithTag:action_id];
    if (![button isKindOfClass:[NSButton class]]) return false;
    [button performClick:nil];
    return true;
}
typedef void (*pz_action_cb)(int32_t action_id, void *ctx);

static pz_action_cb g_guidance_dismiss_cb = NULL;
static void *g_guidance_dismiss_ctx = NULL;
static pz_action_cb g_activation_cb = NULL;
static void *g_activation_ctx = NULL;

void pz_set_guidance_dismiss_handler(pz_action_cb cb, void *ctx) {
    g_guidance_dismiss_cb = cb;
    g_guidance_dismiss_ctx = ctx;
}

void pz_set_activation_handler(pz_action_cb cb, void *ctx) {
    g_activation_cb = cb;
    g_activation_ctx = ctx;
    static BOOL registered = NO;
    if (!registered) {
        registered = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if (g_activation_cb) g_activation_cb(0, g_activation_ctx);
        }];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                                                        object:nil
                                                                         queue:[NSOperationQueue mainQueue]
                                                                    usingBlock:^(NSNotification *note) {
            if (g_activation_cb) g_activation_cb(0, g_activation_ctx);
        }];
    }
}

static NSURL *pz_get_bundle_url(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *bundleURL = bundle.bundleURL;
    if ([bundleURL.pathExtension isEqualToString:@"app"]) {
        return bundleURL;
    }
    NSString *execPath = [[NSProcessInfo processInfo] arguments].firstObject;
    if (execPath) {
        NSURL *curr = [NSURL fileURLWithPath:execPath].URLByResolvingSymlinksInPath;
        while (curr.path.length > 1) {
            if ([curr.pathExtension isEqualToString:@"app"]) {
                return curr;
            }
            curr = curr.URLByDeletingLastPathComponent;
        }
    }
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *buildApp = [cwd stringByAppendingPathComponent:@"build/PopzlipTS.app"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:buildApp]) {
        return [NSURL fileURLWithPath:buildApp];
    }
    NSString *userApp = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Popzlip.app"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:userApp]) {
        return [NSURL fileURLWithPath:userApp];
    }
    NSString *sysApp = @"/Applications/Popzlip.app";
    if ([[NSFileManager defaultManager] fileExistsAtPath:sysApp]) {
        return [NSURL fileURLWithPath:sysApp];
    }
    return bundleURL;
}

static pz_action_cb g_guidance_timer_cb = NULL;
static void *g_guidance_timer_ctx = NULL;

void pz_set_guidance_timer_handler(pz_action_cb cb, void *ctx) {
    g_guidance_timer_cb = cb;
    g_guidance_timer_ctx = ctx;
}

void pz_guidance_schedule(double delay_ms, int32_t timer_id) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay_ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (g_guidance_timer_cb) g_guidance_timer_cb(timer_id, g_guidance_timer_ctx);
    });
}

bool pz_locate_settings_window(uint8_t *out, size_t cap) {
    if (cap < 32) return false;
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID
    );
    if (!windowList) return false;

    NSArray *windows = (__bridge_transfer NSArray *)windowList;
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    if (primaryHeight <= 0) primaryHeight = 900.0;

    NSArray<NSString *> *processNames = @[@"System Settings", @"System Preferences"];

    for (NSDictionary *info in windows) {
        NSNumber *layer = info[(id)kCGWindowLayer];
        if (layer == nil || [layer intValue] != 0) continue;

        NSNumber *alpha = info[(id)kCGWindowAlpha];
        if (alpha != nil && [alpha doubleValue] <= 0.5) continue;

        NSString *owner = info[(id)kCGWindowOwnerName];
        if (!owner) continue;

        BOOL matches = NO;
        for (NSString *name in processNames) {
            if ([owner rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
                matches = YES;
                break;
            }
        }
        if (!matches) continue;

        NSDictionary *boundsDict = info[(id)kCGWindowBounds];
        if (!boundsDict) continue;

        CGRect quartzRect;
        if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)boundsDict, &quartzRect)) continue;
        if (quartzRect.size.width <= 100 || quartzRect.size.height <= 100) continue;

        double cocoaY = primaryHeight - quartzRect.origin.y - quartzRect.size.height;
        double *d = (double *)out;
        d[0] = quartzRect.origin.x;
        d[1] = cocoaY;
        d[2] = quartzRect.size.width;
        d[3] = quartzRect.size.height;
        return true;
    }
    return false;
}

bool pz_open_accessibility_settings(void) {
    NSURL *primary = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"];
    if (primary && [[NSWorkspace sharedWorkspace] openURL:primary]) {
        return true;
    }
    NSURL *fallback = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (fallback && [[NSWorkspace sharedWorkspace] openURL:fallback]) {
        return true;
    }
    return false;
}

@interface PZDraggableCardView : NSView <NSDraggingSource>
@property (nonatomic, strong) NSURL *bundleURL;
@end

@implementation PZDraggableCardView {
    NSPoint _mouseDownPoint;
}

- (NSView *)hitTest:(NSPoint)point {
    return NSPointInRect([self convertPoint:point fromView:self.superview], self.bounds) ? self : nil;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    _mouseDownPoint = [event locationInWindow];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint current = [event locationInWindow];
    if (hypot(current.x - _mouseDownPoint.x, current.y - _mouseDownPoint.y) < 3.0) return;
    if (!self.bundleURL) return;

    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:self.bundleURL];
    NSRect dragFrame = self.bounds;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:dragFrame];
    if (rep) {
        [self cacheDisplayInRect:dragFrame toBitmapImageRep:rep];
        NSImage *snapshot = [[NSImage alloc] initWithSize:dragFrame.size];
        [snapshot addRepresentation:rep];
        [item setDraggingFrame:dragFrame contents:snapshot];
    }
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy | NSDragOperationGeneric;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
    [[NSColor colorWithWhite:1.0 alpha:0.08] setFill];
    [path fill];
    [[NSColor colorWithWhite:1.0 alpha:0.12] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}
@end

void pz_guidance_panel_hide(void);

@interface PZGuidanceTarget : NSObject
- (void)guidanceDismiss:(id)sender;
@end

@implementation PZGuidanceTarget
- (void)guidanceDismiss:(id)sender {
    pz_guidance_panel_hide();
    if (g_guidance_dismiss_cb) {
        g_guidance_dismiss_cb(0, g_guidance_dismiss_ctx);
    }
}
@end

static NSPanel *g_guidance_panel = nil;
static NSView *g_guidance_view = nil;
static NSView *g_granted_view = nil;
static PZGuidanceTarget *g_guidance_target = nil;
static PZDraggableCardView *g_guidance_card = nil;

void pz_guidance_panel_create(const uint8_t *bytes, size_t len) {
    if (g_guidance_panel) return;

    g_guidance_target = [[PZGuidanceTarget alloc] init];
    g_guidance_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 110)
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    g_guidance_panel.opaque = NO;
    g_guidance_panel.backgroundColor = NSColor.clearColor;
    g_guidance_panel.hasShadow = YES;
    g_guidance_panel.level = NSPopUpMenuWindowLevel;
    g_guidance_panel.hidesOnDeactivate = NO;
    g_guidance_panel.becomesKeyOnlyIfNeeded = YES;
    g_guidance_panel.movableByWindowBackground = YES;
    g_guidance_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                          NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 380, 110)];
    effect.material = NSVisualEffectMaterialHUDWindow;
    effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effect.state = NSVisualEffectStateActive;
    effect.wantsLayer = YES;
    effect.layer.cornerRadius = 16.0;
    effect.layer.masksToBounds = YES;
    effect.layer.borderWidth = 1.0;
    effect.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    g_guidance_panel.contentView = effect;

    NSString *urlStr = pz_string(bytes, len);
    NSURL *bundleURL = nil;
    if (urlStr.length > 0) {
        bundleURL = [urlStr hasPrefix:@"file://"] ? [NSURL URLWithString:urlStr] : [NSURL fileURLWithPath:urlStr];
    }
    if (!bundleURL) {
        bundleURL = pz_get_bundle_url();
    }
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Popzlip";

    // Guidance subview
    g_guidance_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 110)];

    NSImageView *arrow = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 82, 14, 14)];
    if (@available(macOS 11.0, *)) {
        arrow.image = [NSImage imageWithSystemSymbolName:@"arrow.up" accessibilityDescription:@"Arrow"];
        arrow.contentTintColor = [NSColor colorWithSRGBRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    }
    [g_guidance_view addSubview:arrow];

    NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:@"Drag %@ into the Accessibility list", appName]];
    title.frame = NSMakeRect(32, 80, 305, 18);
    title.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    title.textColor = [NSColor labelColor];
    [g_guidance_view addSubview:title];

    NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(348, 80, 18, 18)];
    closeBtn.bordered = NO;
    if (@available(macOS 11.0, *)) {
        closeBtn.image = [NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"];
        closeBtn.contentTintColor = [NSColor secondaryLabelColor];
    } else {
        closeBtn.title = @"✕";
    }
    closeBtn.target = g_guidance_target;
    closeBtn.action = @selector(guidanceDismiss:);
    [g_guidance_view addSubview:closeBtn];

    g_guidance_card = [[PZDraggableCardView alloc] initWithFrame:NSMakeRect(14, 34, 352, 36)];
    g_guidance_card.bundleURL = bundleURL;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 7, 22, 22)];
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:bundleURL.path] ?: [NSApp applicationIconImage];
    icon.wantsLayer = YES;
    icon.layer.cornerRadius = 5.0;
    icon.layer.masksToBounds = YES;
    [g_guidance_card addSubview:icon];

    NSTextField *nameLabel = [NSTextField labelWithString:appName];
    nameLabel.frame = NSMakeRect(38, 9, 200, 18);
    nameLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    nameLabel.textColor = [NSColor labelColor];
    [g_guidance_card addSubview:nameLabel];

    NSImageView *handle = [[NSImageView alloc] initWithFrame:NSMakeRect(324, 9, 18, 18)];
    if (@available(macOS 11.0, *)) {
        handle.image = [NSImage imageWithSystemSymbolName:@"line.3.horizontal" accessibilityDescription:@"Drag handle"];
        handle.contentTintColor = [NSColor tertiaryLabelColor];
    }
    [g_guidance_card addSubview:handle];
    [g_guidance_view addSubview:g_guidance_card];

    NSTextField *sub = [NSTextField labelWithString:[NSString stringWithFormat:@"Or click + in System Settings and choose %@", appName]];
    sub.frame = NSMakeRect(14, 12, 352, 16);
    sub.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    sub.textColor = [NSColor tertiaryLabelColor];
    [g_guidance_view addSubview:sub];

    [effect addSubview:g_guidance_view];

    // Granted subview
    g_granted_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 110)];
    g_granted_view.hidden = YES;

    NSImageView *check = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 42, 26, 26)];
    if (@available(macOS 11.0, *)) {
        check.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"Granted"];
        check.contentTintColor = [NSColor systemGreenColor];
    }
    [g_granted_view addSubview:check];

    NSTextField *gTitle = [NSTextField labelWithString:@"Accessibility Access Granted"];
    gTitle.frame = NSMakeRect(58, 54, 300, 20);
    gTitle.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    gTitle.textColor = [NSColor labelColor];
    [g_granted_view addSubview:gTitle];

    NSTextField *gSub = [NSTextField labelWithString:@"You're ready to use Popzlip."];
    gSub.frame = NSMakeRect(58, 34, 300, 16);
    gSub.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    gSub.textColor = [NSColor secondaryLabelColor];
    [g_granted_view addSubview:gSub];

    [effect addSubview:g_granted_view];
}

void pz_guidance_panel_show(double x, double y, double w, double h) {
    if (!g_guidance_panel) return;
    [g_guidance_panel setFrame:NSMakeRect(x, y, w, h) display:YES];
    [g_guidance_panel orderFrontRegardless];
}

void pz_guidance_panel_set_frame(double x, double y, double w, double h, bool animate) {
    if (!g_guidance_panel) return;
    [g_guidance_panel setFrame:NSMakeRect(x, y, w, h) display:YES animate:(BOOL)animate];
}

void pz_settings_refresh_permission(void);

void pz_guidance_panel_set_phase(int32_t phase) {
    if (phase == 0) {
        g_guidance_view.hidden = NO;
        g_granted_view.hidden = YES;
    } else {
        g_guidance_view.hidden = YES;
        g_granted_view.hidden = NO;
    }
    pz_settings_refresh_permission();
}

void pz_guidance_panel_hide(void) {
    if (!g_guidance_panel) return;
    [g_guidance_panel orderOut:nil];
}

bool pz_guidance_panel_visible(void) {
    return g_guidance_panel != nil && g_guidance_panel.visible;
}

static pz_action_cb g_simulate_cb = NULL;
static void *g_simulate_ctx = NULL;

void pz_set_simulate_handler(pz_action_cb cb, void *ctx) {
    g_simulate_cb = cb;
    g_simulate_ctx = ctx;
}

@interface PZSettingsTarget : NSObject <NSWindowDelegate>
- (void)statusShowSettings:(id)sender;
- (void)statusShowPermissions:(id)sender;
- (void)statusSimulate:(id)sender;
- (void)statusQuit:(id)sender;
- (void)grantClicked:(id)sender;
- (void)testGuidanceClicked:(id)sender;
- (void)simulateClicked:(id)sender;
- (void)quitClicked:(id)sender;
@end

static PZSettingsTarget *g_settings_target = nil;
static NSWindow *g_settings_window = nil;
static NSTextField *g_settings_perm_label = nil;
static NSImageView *g_settings_perm_icon = nil;
static NSButton *g_settings_grant_btn = nil;
static NSTextField *g_settings_active_label = nil;
static PZDraggableCardView *g_settings_drag_card = nil;
static NSStatusItem *g_status_item = nil;

void pz_settings_refresh_permission(void) {
    if (!g_settings_window) return;
    BOOL trusted = AXIsProcessTrusted();
    if (trusted) {
        g_settings_perm_label.stringValue = @"Accessibility Access Granted ✓";
        g_settings_perm_label.textColor = [NSColor systemGreenColor];
        if (@available(macOS 11.0, *)) {
            g_settings_perm_icon.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"Granted"];
            g_settings_perm_icon.contentTintColor = [NSColor systemGreenColor];
        }
        g_settings_grant_btn.title = @"Open System Settings…";
        g_settings_active_label.stringValue = @"● Daemon Active in Background";
        g_settings_active_label.textColor = [NSColor systemGreenColor];
    } else {
        g_settings_active_label.stringValue = @"● Waiting for Accessibility";
        g_settings_active_label.textColor = [NSColor systemOrangeColor];
        g_settings_perm_label.stringValue = @"Accessibility Access Required";
        g_settings_perm_label.textColor = [NSColor systemOrangeColor];
        if (@available(macOS 11.0, *)) {
            g_settings_perm_icon.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:@"Required"];
            g_settings_perm_icon.contentTintColor = [NSColor systemOrangeColor];
        }
        g_settings_grant_btn.title = @"Grant Access…";
    }
}

@implementation PZSettingsTarget

- (void)statusShowSettings:(id)sender {
    pz_settings_show();
}

- (void)statusShowPermissions:(id)sender {
    pz_settings_show();
    [self grantClicked:nil];
}

- (void)statusSimulate:(id)sender {
    if (g_simulate_cb) g_simulate_cb(0, g_simulate_ctx);
}

- (void)statusQuit:(id)sender {
    [NSApp terminate:nil];
}

- (void)grantClicked:(id)sender {
    pz_open_accessibility_settings();
    pz_guidance_panel_create(NULL, 0);
    pz_guidance_panel_set_phase(0);
    double rect[4] = {0};
    if (pz_locate_settings_window((uint8_t *)rect, sizeof(rect))) {
        pz_guidance_panel_show(rect[0] + rect[2] / 2.0 - 190.0, rect[1] - 90.0, 380, 110);
    } else if (g_settings_window) {
        NSRect sf = g_settings_window.frame;
        pz_guidance_panel_show(sf.origin.x + sf.size.width / 2.0 - 190.0, sf.origin.y - 100.0, 380, 110);
    } else {
        pz_guidance_panel_show(530, 80, 380, 110);
    }
}

- (void)testGuidanceClicked:(id)sender {
    pz_guidance_panel_create(NULL, 0);
    pz_guidance_panel_set_phase(0);
    if (g_settings_window) {
        NSRect sf = g_settings_window.frame;
        pz_guidance_panel_show(sf.origin.x + sf.size.width / 2.0 - 190.0, sf.origin.y - 100.0, 380, 110);
    } else {
        pz_guidance_panel_show(530, 80, 380, 110);
    }
}

- (void)simulateClicked:(id)sender {
    if (g_simulate_cb) g_simulate_cb(0, g_simulate_ctx);
}

- (void)quitClicked:(id)sender {
    [NSApp terminate:nil];
}

@end

static void pz_settings_init_views(void) {
    if (g_settings_window) return;
    g_settings_target = [[PZSettingsTarget alloc] init];

    g_settings_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 400)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    g_settings_window.title = @"Popzlip Settings";
    g_settings_window.delegate = g_settings_target;
    g_settings_window.releasedWhenClosed = NO;
    [g_settings_window center];

    NSView *content = g_settings_window.contentView;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 332, 48, 48)];
    NSURL *bundleURL = pz_get_bundle_url();
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:bundleURL.path] ?: [NSApp applicationIconImage];
    [content addSubview:icon];

    NSTextField *title = [NSTextField labelWithString:@"Popzlip TS"];
    title.frame = NSMakeRect(82, 354, 250, 22);
    title.font = [NSFont systemFontOfSize:17.0 weight:NSFontWeightBold];
    [content addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:@"Lightweight PopClip alternative with instant text actions"];
    subtitle.frame = NSMakeRect(82, 334, 350, 18);
    subtitle.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    subtitle.textColor = [NSColor secondaryLabelColor];
    [content addSubview:subtitle];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(24, 320, 432, 1)];
    sep1.boxType = NSBoxSeparator;
    [content addSubview:sep1];

    NSView *permBox = [[NSView alloc] initWithFrame:NSMakeRect(24, 175, 432, 135)];
    permBox.wantsLayer = YES;
    permBox.layer.cornerRadius = 10.0;
    permBox.layer.masksToBounds = YES;
    permBox.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.04].CGColor;
    permBox.layer.borderWidth = 1.0;
    permBox.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;

    NSTextField *permHeader = [NSTextField labelWithString:@"ACCESSIBILITY PERMISSION"];
    permHeader.frame = NSMakeRect(14, 108, 300, 16);
    permHeader.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    permHeader.textColor = [NSColor secondaryLabelColor];
    [permBox addSubview:permHeader];

    g_settings_perm_icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 76, 20, 20)];
    [permBox addSubview:g_settings_perm_icon];

    g_settings_perm_label = [NSTextField labelWithString:@"Checking accessibility status..."];
    g_settings_perm_label.frame = NSMakeRect(40, 76, 230, 20);
    g_settings_perm_label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    [permBox addSubview:g_settings_perm_label];

    g_settings_grant_btn = [[NSButton alloc] initWithFrame:NSMakeRect(284, 72, 134, 28)];
    g_settings_grant_btn.title = @"Grant Access…";
    g_settings_grant_btn.bezelStyle = NSBezelStyleRounded;
    g_settings_grant_btn.target = g_settings_target;
    g_settings_grant_btn.action = @selector(grantClicked:);
    [permBox addSubview:g_settings_grant_btn];

    g_settings_drag_card = [[PZDraggableCardView alloc] initWithFrame:NSMakeRect(14, 26, 404, 36)];
    g_settings_drag_card.bundleURL = bundleURL;

    NSImageView *cardIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 7, 22, 22)];
    cardIcon.image = icon.image;
    cardIcon.wantsLayer = YES;
    cardIcon.layer.cornerRadius = 5.0;
    cardIcon.layer.masksToBounds = YES;
    [g_settings_drag_card addSubview:cardIcon];

    NSTextField *cardLabel = [NSTextField labelWithString:@"Drag Popzlip directly into System Settings"];
    cardLabel.frame = NSMakeRect(38, 9, 320, 18);
    cardLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    cardLabel.textColor = [NSColor labelColor];
    [g_settings_drag_card addSubview:cardLabel];

    NSImageView *cardHandle = [[NSImageView alloc] initWithFrame:NSMakeRect(376, 9, 18, 18)];
    if (@available(macOS 11.0, *)) {
        cardHandle.image = [NSImage imageWithSystemSymbolName:@"line.3.horizontal" accessibilityDescription:@"Drag handle"];
        cardHandle.contentTintColor = [NSColor tertiaryLabelColor];
    }
    [g_settings_drag_card addSubview:cardHandle];
    [permBox addSubview:g_settings_drag_card];

    NSTextField *hintLabel = [NSTextField labelWithString:@"Tip: Drop the card above into System Settings > Accessibility, or click Grant Access."];
    hintLabel.frame = NSMakeRect(14, 6, 404, 14);
    hintLabel.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightRegular];
    hintLabel.textColor = [NSColor tertiaryLabelColor];
    [permBox addSubview:hintLabel];

    [content addSubview:permBox];

    NSView *testBox = [[NSView alloc] initWithFrame:NSMakeRect(24, 75, 432, 85)];
    testBox.wantsLayer = YES;
    testBox.layer.cornerRadius = 10.0;
    testBox.layer.masksToBounds = YES;
    testBox.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.04].CGColor;
    testBox.layer.borderWidth = 1.0;
    testBox.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;

    NSTextField *testHeader = [NSTextField labelWithString:@"TESTING & VERIFICATION"];
    testHeader.frame = NSMakeRect(14, 60, 300, 16);
    testHeader.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    testHeader.textColor = [NSColor secondaryLabelColor];
    [testBox addSubview:testHeader];

    NSButton *simBtn = [[NSButton alloc] initWithFrame:NSMakeRect(14, 18, 190, 32)];
    simBtn.title = @"Simulate Selection Popup";
    simBtn.bezelStyle = NSBezelStyleRounded;
    simBtn.target = g_settings_target;
    simBtn.action = @selector(simulateClicked:);
    [testBox addSubview:simBtn];

    NSButton *testGuidanceBtn = [[NSButton alloc] initWithFrame:NSMakeRect(216, 18, 202, 32)];
    testGuidanceBtn.title = @"Test Permission Drag HUD";
    testGuidanceBtn.bezelStyle = NSBezelStyleRounded;
    testGuidanceBtn.target = g_settings_target;
    testGuidanceBtn.action = @selector(testGuidanceClicked:);
    [testBox addSubview:testGuidanceBtn];

    [content addSubview:testBox];

    NSTextField *ver = [NSTextField labelWithString:@"Popzlip TS v0.2.0"];
    ver.frame = NSMakeRect(24, 22, 140, 18);
    ver.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    ver.textColor = [NSColor tertiaryLabelColor];
    [content addSubview:ver];

    g_settings_active_label = [NSTextField labelWithString:@""];
    g_settings_active_label.frame = NSMakeRect(170, 22, 180, 18);
    g_settings_active_label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    [content addSubview:g_settings_active_label];

    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(360, 16, 96, 28)];
    quitBtn.title = @"Quit";
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.target = g_settings_target;
    quitBtn.action = @selector(quitClicked:);
    [content addSubview:quitBtn];
}

void pz_settings_show(void) {
    pz_settings_init_views();
    pz_settings_refresh_permission();
    [NSApp activateIgnoringOtherApps:YES];
    [g_settings_window makeKeyAndOrderFront:nil];
}

void pz_settings_hide(void) {
    if (g_settings_window) {
        [g_settings_window orderOut:nil];
    }
}

bool pz_settings_visible(void) {
    return g_settings_window != nil && g_settings_window.visible;
}

void pz_status_item_create(void) {
    if (g_status_item) return;
    if (!g_settings_target) g_settings_target = [[PZSettingsTarget alloc] init];

    g_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = g_status_item.button;
    if (button) {
        if (@available(macOS 11.0, *)) {
            button.image = [NSImage imageWithSystemSymbolName:@"selection.pin.in.out" accessibilityDescription:@"Popzlip"];
            if (!button.image) {
                button.image = [NSImage imageWithSystemSymbolName:@"text.badge.checkmark" accessibilityDescription:@"Popzlip"];
            }
        }
        if (!button.image) {
            button.title = @"Popzlip";
        }
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Popzlip"];

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"Popzlip TS (Active)" action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:@selector(statusShowSettings:) keyEquivalent:@","];
    settingsItem.target = g_settings_target;
    [menu addItem:settingsItem];

    NSMenuItem *permItem = [[NSMenuItem alloc] initWithTitle:@"Accessibility Permission…" action:@selector(statusShowPermissions:) keyEquivalent:@""];
    permItem.target = g_settings_target;
    [menu addItem:permItem];

    NSMenuItem *simItem = [[NSMenuItem alloc] initWithTitle:@"Simulate Selection Popup" action:@selector(statusSimulate:) keyEquivalent:@"s"];
    simItem.target = g_settings_target;
    [menu addItem:simItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Popzlip" action:@selector(statusQuit:) keyEquivalent:@"q"];
    quitItem.target = g_settings_target;
    [menu addItem:quitItem];

    g_status_item.menu = menu;
}
