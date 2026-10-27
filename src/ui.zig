//! ui.zig — NanoUI floating popup toolbar for PopClip
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const types = @import("types.zig");
const actions = @import("actions.zig");
const macos = @import("macos.zig");

pub const PopClipState = struct {
    allocator: std.mem.Allocator,
    selected_text: []const u8 = "",
    actions_list: []types.Action = &.{},
    status_msg: ?[]const u8 = null,
    window: ?*nanoui.Window = null,
    app: ?*nanoui.App = null,

    pub fn setSelection(self: *PopClipState, text: []const u8) void {
        self.selected_text = text;
        const sel = types.Selection{
            .text = text,
            .has_selection = text.len > 0,
            .can_paste = true,
        };
        self.actions_list = actions.getActionsForSelection(self.allocator, sel) catch &.{};
    }

    pub fn view(s: *PopClipState, c: *ui.Context) void {
        const th = c.theme;

        // PopClip pill container: 28px height, rounded corners, dark glass aesthetic
        ui.row(c, .{
            .height = .{ .px = 28 },
            .align_items = .center,
            .justify = .center,
            .padding = .{ .top = 2, .bottom = 2, .left = 6, .right = 6 },
            .gap = 4,
            .background = th.surface.alpha(0.85),
            .border = th.border.alpha(0.3),
        });
        defer ui.end(c);

        if (s.actions_list.len == 0) {
            ui.text(c, "No selection", .{ .size = 12, .color = th.muted });
            return;
        }

        for (s.actions_list) |act| {
            const btn = ui.button(c, act.label, .{
                .variant = .ghost,
                .size = 12,
            });

            if (btn.clicked) {
                s.executeAction(act);
            }
        }
    }

    pub fn executeAction(self: *PopClipState, act: types.Action) void {
        switch (act.kind) {
            .copy => {
                nanoui.clipboard.writeText(self.selected_text);
                self.dismiss();
            },
            .cut => {
                nanoui.clipboard.writeText(self.selected_text);
                self.dismiss();
            },
            .paste => {
                self.dismiss();
            },
            .append_clipboard => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const current = nanoui.clipboard.readText(arena.allocator()) catch null;
                const appended = actions.appendClipboard(arena.allocator(), current, self.selected_text) catch return;
                nanoui.clipboard.writeText(appended);
                self.dismiss();
            },
            .terminal => {
                macos.runShellScript(self.selected_text) catch {};
                self.dismiss();
            },
            .notes => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const script = std.fmt.allocPrint(arena.allocator(), "tell application \"Notes\" to tell default account to make new note with properties {{body:\"{s}\"}}", .{self.selected_text}) catch return;
                const cmd = std.fmt.allocPrint(arena.allocator(), "osascript -e '{s}'", .{script}) catch return;
                macos.runShellScript(cmd) catch {};
                self.dismiss();
            },
            .search => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const encoded_url = std.fmt.allocPrint(alloc, "https://www.google.com/search?q={s}", .{self.selected_text}) catch return;
                macos.openUrl(encoded_url) catch {};
                self.dismiss();
            },
            .open_url => {
                if (act.payload) |u| {
                    macos.openUrl(u) catch {};
                } else {
                    macos.openUrl(self.selected_text) catch {};
                }
                self.dismiss();
            },
            .email => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const mail_url = std.fmt.allocPrint(alloc, "mailto:{s}", .{self.selected_text}) catch return;
                macos.openUrl(mail_url) catch {};
                self.dismiss();
            },
            .calculate => {
                if (act.payload) |p| {
                    nanoui.clipboard.writeText(p);
                }
                self.dismiss();
            },
            .upper_case => {
                if (actions.toUpper(self.allocator, self.selected_text) catch null) |res| {
                    defer self.allocator.free(res);
                    nanoui.clipboard.writeText(res);
                }
                self.dismiss();
            },
            .lower_case => {
                if (actions.toLower(self.allocator, self.selected_text) catch null) |res| {
                    defer self.allocator.free(res);
                    nanoui.clipboard.writeText(res);
                }
                self.dismiss();
            },
            .title_case => {
                if (actions.toTitleCase(self.allocator, self.selected_text) catch null) |res| {
                    defer self.allocator.free(res);
                    nanoui.clipboard.writeText(res);
                }
                self.dismiss();
            },
            .markdown_bold => {
                if (actions.toMarkdownBold(self.allocator, self.selected_text) catch null) |res| {
                    defer self.allocator.free(res);
                    nanoui.clipboard.writeText(res);
                }
                self.dismiss();
            },
            .markdown_code => {
                if (actions.toMarkdownCode(self.allocator, self.selected_text) catch null) |res| {
                    defer self.allocator.free(res);
                    nanoui.clipboard.writeText(res);
                }
                self.dismiss();
            },
            .dictionary => {
                macos.openDictionary(self.selected_text) catch {};
                self.dismiss();
            },
            .word_count => {
                self.dismiss();
            },
            else => {
                self.dismiss();
            },
        }
    }

    pub fn dismiss(self: *PopClipState) void {
        if (self.window) |w| {
            w.hide();
        }
    }
};
