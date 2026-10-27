//! macos.zig — Native macOS integration (Accessibility, CoreGraphics, Memory Profiling)
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;

// Mach task memory profiling
pub const mach_port_t = u32;
pub const kern_return_t = i32;
pub const task_flavor_t = u32;
pub const natural_t = u32;
pub const mach_msg_type_number_t = natural_t;

pub const MACH_TASK_BASIC_INFO: task_flavor_t = 20;

pub const mach_task_basic_info = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64,
    user_time: extern struct { seconds: i32, microseconds: i32 },
    system_time: extern struct { seconds: i32, microseconds: i32 },
    policy: i32,
    suspend_count: i32,
};

extern "c" fn mach_task_self() mach_port_t;
extern "c" fn task_info(
    target_task: mach_port_t,
    flavor: task_flavor_t,
    task_info_out: ?*anyopaque,
    task_info_outCnt: *mach_msg_type_number_t,
) kern_return_t;

/// Returns current process Resident Set Size (RSS) in bytes.
pub fn getProcessRssBytes() u64 {
    var info: mach_task_basic_info = undefined;
    var count: mach_msg_type_number_t = @sizeOf(mach_task_basic_info) / @sizeOf(natural_t);
    const kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, &info, &count);
    if (kr == 0) {
        return info.resident_size;
    }
    return 0;
}

/// Returns current process RSS formatted in megabytes.
pub fn getProcessRssMB() f64 {
    const bytes = getProcessRssBytes();
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

extern "c" fn system(command: [*:0]const u8) c_int;

// Shell and URL open helpers
pub fn openUrl(url: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s = try std.fmt.allocPrint(alloc, "/usr/bin/open '{s}'", .{url});
    const cmd = try alloc.dupeZ(u8, s);
    _ = system(cmd.ptr);
}

pub fn openDictionary(word: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s = try std.fmt.allocPrint(alloc, "/usr/bin/open 'dict://{s}'", .{word});
    const cmd = try alloc.dupeZ(u8, s);
    _ = system(cmd.ptr);
}

pub fn runShellScript(script: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s = try std.fmt.allocPrint(alloc, "/bin/zsh -c '{s}'", .{script});
    const cmd = try alloc.dupeZ(u8, s);
    _ = system(cmd.ptr);
}

test "getProcessRssBytes reports valid memory size" {
    const rss = getProcessRssBytes();
    try std.testing.expect(rss > 0);
    const mb = getProcessRssMB();
    // A Zig process should consume far less than 10MB
    try std.testing.expect(mb < 10.0);
    std.debug.print("\n[Zig Memory] Current RSS: {d:.2} MB\n", .{mb});
}
