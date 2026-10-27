#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <stdint.h>
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

void pz_app_init(void) {
    [NSApplication sharedApplication];
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
            g_event_cb(PZ_MOUSE_DOWN, pt.x, pt.y, 0, g_event_ctx);
            break;
        case kCGEventLeftMouseDragged:
            g_event_cb(PZ_MOUSE_DRAGGED, pt.x, pt.y, 0, g_event_ctx);
            break;
        case kCGEventLeftMouseUp:
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
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return front ? front.processIdentifier : -1;
}

int32_t pz_self_pid(void) {
    return getpid();
}

int32_t pz_ax_selected_text(int32_t pid, uint8_t *out, size_t cap) {
    @autoreleasepool {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementRef focused = NULL;
        int32_t result = 0;
        if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess &&
            focused) {
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

int32_t pz_press_copy_menu(int32_t pid) {
    @autoreleasepool {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementRef item = pz_find_copy_item(app);
        CFRelease(app);
        if (!item) return -1;
        CFTypeRef enabled = NULL;
        AXUIElementCopyAttributeValue(item, kAXEnabledAttribute, &enabled);
        BOOL on = enabled ? [(__bridge NSNumber *)enabled boolValue] : NO;
        if (enabled) CFRelease(enabled);
        if (on) AXUIElementPerformAction(item, kAXPressAction);
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
