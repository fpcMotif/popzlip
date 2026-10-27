//! c_api.zig — C-compatible exported API for XCTest verification and native callers
const std = @import("std");
const types = @import("types.zig");
const actions = @import("actions.zig");
const placement = @import("placement.zig");
const macos = @import("macos.zig");

var g_allocator = std.heap.page_allocator;
var g_actions: []types.Action = &.{};
var g_current_text: ?[]const u8 = null;

export fn popclip_init() void {
    // Initialization of engine
    g_actions = &.{};
}

export fn popclip_analyze_selection(text_ptr: [*:0]const u8) c_int {
    const text = std.mem.span(text_ptr);
    g_current_text = text;

    if (g_actions.len > 0) {
        g_allocator.free(g_actions);
        g_actions = &.{};
    }

    if (text.len == 0) {
        return 0;
    }

    const sel = types.Selection{
        .text = text,
        .has_selection = true,
        .can_paste = true,
    };

    g_actions = actions.getActionsForSelection(g_allocator, sel) catch &.{};
    return @intCast(g_actions.len);
}

export fn popclip_get_engine_allocated_bytes() usize {
    var total: usize = @sizeOf(types.Action) * g_actions.len;
    for (g_actions) |act| {
        total += act.label.len + act.id.len;
        if (act.payload) |p| total += p.len;
    }
    return total;
}

export fn popclip_get_action_id(index: c_int) ?[*:0]const u8 {
    if (index < 0 or @as(usize, @intCast(index)) >= g_actions.len) return null;
    const act = g_actions[@as(usize, @intCast(index))];
    const null_terminated = g_allocator.dupeZ(u8, act.id) catch return null;
    return null_terminated.ptr;
}

export fn popclip_get_action_label(index: c_int) ?[*:0]const u8 {
    if (index < 0 or @as(usize, @intCast(index)) >= g_actions.len) return null;
    const act = g_actions[@as(usize, @intCast(index))];
    const null_terminated = g_allocator.dupeZ(u8, act.label) catch return null;
    return null_terminated.ptr;
}

export fn popclip_get_action_kind(index: c_int) c_int {
    if (index < 0 or @as(usize, @intCast(index)) >= g_actions.len) return -1;
    const act = g_actions[@as(usize, @intCast(index))];
    return @intCast(@intFromEnum(act.kind));
}

export fn popclip_get_action_payload(index: c_int) ?[*:0]const u8 {
    if (index < 0 or @as(usize, @intCast(index)) >= g_actions.len) return null;
    const act = g_actions[@as(usize, @intCast(index))];
    if (act.payload) |p| {
        const null_terminated = g_allocator.dupeZ(u8, p) catch return null;
        return null_terminated.ptr;
    }
    return null;
}

export fn popclip_calculate_placement(
    sel_x: f64,
    sel_y: f64,
    sel_w: f64,
    sel_h: f64,
    screen_w: f64,
    screen_h: f64,
    out_x: *f64,
    out_y: *f64,
    out_arrow_below: *c_int,
) void {
    const screen = placement.ScreenBounds{
        .width = screen_w,
        .height = screen_h,
        .menu_bar_height = 32,
        .margin = 12,
    };
    const sel = types.Rect{ .x = sel_x, .y = sel_y, .width = sel_w, .height = sel_h };
    // PopClip standard window height is 28.0px
    const p = placement.calculatePlacement(sel, 160.0, 28.0, screen);
    out_x.* = p.x;
    out_y.* = p.y;
    out_arrow_below.* = if (p.arrow_below) 1 else 0;
}

export fn popclip_evaluate_math(expr_ptr: [*:0]const u8, out_val: *f64) c_int {
    const expr = std.mem.span(expr_ptr);
    if (actions.evaluateMath(g_allocator, expr) catch null) |val| {
        out_val.* = val;
        return 1;
    }
    return 0;
}

export fn popclip_is_url(text_ptr: [*:0]const u8) c_int {
    const text = std.mem.span(text_ptr);
    return if (actions.isUrl(text)) 1 else 0;
}

export fn popclip_is_email(text_ptr: [*:0]const u8) c_int {
    const text = std.mem.span(text_ptr);
    return if (actions.isEmail(text)) 1 else 0;
}

export fn popclip_transform_text(
    text_ptr: [*:0]const u8,
    transform_kind: c_int,
    out_buf: [*]u8,
    max_len: c_int,
) c_int {
    const text = std.mem.span(text_ptr);
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const transformed = switch (transform_kind) {
        0 => actions.toUpper(allocator, text) catch return -1,
        1 => actions.toLower(allocator, text) catch return -1,
        2 => actions.toTitleCase(allocator, text) catch return -1,
        3 => actions.toMarkdownBold(allocator, text) catch return -1,
        4 => actions.toMarkdownItalic(allocator, text) catch return -1,
        5 => actions.toMarkdownCode(allocator, text) catch return -1,
        else => return -1,
    };

    if (transformed.len >= @as(usize, @intCast(max_len))) return -1;
    @memcpy(out_buf[0..transformed.len], transformed);
    out_buf[transformed.len] = 0;
    return @intCast(transformed.len);
}

export fn popclip_get_memory_rss_bytes() u64 {
    return macos.getProcessRssBytes();
}

export fn popclip_get_memory_rss_mb() f64 {
    return macos.getProcessRssMB();
}

export fn popclip_parse_yaml(yaml_ptr: [*:0]const u8, out_name: [*]u8, max_len: c_int) c_int {
    const yaml = std.mem.span(yaml_ptr);
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();

    if (actions.parseYamlExtension(arena.allocator(), yaml) catch null) |ext| {
        if (ext.name.len >= @as(usize, @intCast(max_len))) return -1;
        @memcpy(out_name[0..ext.name.len], ext.name);
        out_name[ext.name.len] = 0;
        return @intCast(ext.name.len);
    }
    return 0;
}
const config_mod = @import("config.zig");
var g_config = config_mod.Config{};

export fn popclip_append_clipboard_text(
    current_ptr: ?[*:0]const u8,
    text_ptr: [*:0]const u8,
    out_buf: [*]u8,
    max_len: c_int,
) c_int {
    const text = std.mem.span(text_ptr);
    const current = if (current_ptr) |cp| std.mem.span(cp) else null;
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();

    const res = actions.appendClipboard(arena.allocator(), current, text) catch return -1;
    if (res.len >= @as(usize, @intCast(max_len))) return -1;
    @memcpy(out_buf[0..res.len], res);
    out_buf[res.len] = 0;
    return @intCast(res.len);
}

export fn popclip_config_get(key_ptr: [*:0]const u8, out_buf: [*]u8, max_len: c_int) c_int {
    const key = std.mem.span(key_ptr);
    if (g_config.get(key)) |val| {
        if (val.len >= @as(usize, @intCast(max_len))) return -1;
        @memcpy(out_buf[0..val.len], val);
        out_buf[val.len] = 0;
        return @intCast(val.len);
    }
    return 0;
}

export fn popclip_config_set(key_ptr: [*:0]const u8, val_ptr: [*:0]const u8) c_int {
    const key = std.mem.span(key_ptr);
    const val = std.mem.span(val_ptr);
    const success = g_config.set(g_allocator, key, val) catch return -1;
    return if (success) 1 else 0;
}
