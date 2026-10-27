//! config.zig — Persistent configuration management for PopClip Zig
const std = @import("std");

pub const Config = struct {
    search_engine: []const u8 = "https://www.google.com/search?q={query}",
    terminal_app: []const u8 = "Terminal",
    theme: []const u8 = "dark",
    enable_append: bool = true,
    enable_notes: bool = true,
    enable_math: bool = true,

    pub fn get(self: Config, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "search_engine")) return self.search_engine;
        if (std.mem.eql(u8, key, "terminal_app")) return self.terminal_app;
        if (std.mem.eql(u8, key, "theme")) return self.theme;
        if (std.mem.eql(u8, key, "enable_append")) return if (self.enable_append) "true" else "false";
        if (std.mem.eql(u8, key, "enable_notes")) return if (self.enable_notes) "true" else "false";
        if (std.mem.eql(u8, key, "enable_math")) return if (self.enable_math) "true" else "false";
        return null;
    }

    pub fn set(self: *Config, allocator: std.mem.Allocator, key: []const u8, val: []const u8) !bool {
        if (std.mem.eql(u8, key, "search_engine")) {
            self.search_engine = try allocator.dupe(u8, val);
            return true;
        } else if (std.mem.eql(u8, key, "terminal_app")) {
            self.terminal_app = try allocator.dupe(u8, val);
            return true;
        } else if (std.mem.eql(u8, key, "theme")) {
            self.theme = try allocator.dupe(u8, val);
            return true;
        } else if (std.mem.eql(u8, key, "enable_append")) {
            self.enable_append = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
            return true;
        } else if (std.mem.eql(u8, key, "enable_notes")) {
            self.enable_notes = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
            return true;
        } else if (std.mem.eql(u8, key, "enable_math")) {
            self.enable_math = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
            return true;
        }
        return false;
    }
};

test "config get and set work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{};
    try std.testing.expectEqualStrings("https://www.google.com/search?q={query}", cfg.get("search_engine").?);
    try std.testing.expectEqualStrings("dark", cfg.get("theme").?);

    _ = try cfg.set(allocator, "theme", "light");
    try std.testing.expectEqualStrings("light", cfg.get("theme").?);

    _ = try cfg.set(allocator, "enable_math", "false");
    try std.testing.expectEqualStrings("false", cfg.get("enable_math").?);
}
