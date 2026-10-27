//! types.zig — Core domain types for PopClip in Zig
const std = @import("std");

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const ActionKind = enum(u32) {
    copy = 0,
    cut = 1,
    paste = 2,
    search = 3,
    open_url = 4,
    email = 5,
    dictionary = 6,
    calculate = 7,
    upper_case = 8,
    lower_case = 9,
    title_case = 10,
    markdown_bold = 11,
    markdown_italic = 12,
    markdown_code = 13,
    markdown_quote = 14,
    word_count = 15,
    terminal = 16,
    append_clipboard = 17,
    notes = 18,
    ai_agent = 19,
    custom_extension = 20,

    pub fn label(self: ActionKind) []const u8 {
        return switch (self) {
            .copy => "Copy",
            .cut => "Cut",
            .paste => "Paste",
            .search => "Search",
            .open_url => "Open URL",
            .email => "Email",
            .dictionary => "Define",
            .calculate => "Calculate",
            .upper_case => "UPPER",
            .lower_case => "lower",
            .title_case => "Title",
            .markdown_bold => "**B**",
            .markdown_italic => "*I*",
            .markdown_code => "`code`",
            .markdown_quote => "> quote",
            .word_count => "Count",
            .terminal => ">_",
            .append_clipboard => "+",
            .notes => "Notes",
            .ai_agent => "AI",
            .custom_extension => "Ext",
        };
    }

    pub fn icon(self: ActionKind) []const u8 {
        return switch (self) {
            .copy => "doc.on.doc",
            .cut => "scissors",
            .paste => "doc.on.clipboard",
            .search => "magnifyingglass",
            .open_url => "safari",
            .email => "envelope",
            .dictionary => "character.book.closed",
            .calculate => "equal.circle",
            .upper_case => "textformat.size.larger",
            .lower_case => "textformat.size.smaller",
            .title_case => "textformat",
            .markdown_bold => "bold",
            .markdown_italic => "italic",
            .markdown_code => "chevron.left.forwardslash.chevron.right",
            .markdown_quote => "quote.opening",
            .word_count => "number",
            .terminal => "terminal",
            .append_clipboard => "plus",
            .notes => "note.text",
            .ai_agent => "sparkles",
            .custom_extension => "puzzlepiece",
        };
    }
};

pub const Action = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8,
    kind: ActionKind,
    payload: ?[]const u8 = null,
};

pub const ActionResultKind = enum {
    none,
    copied,
    replaced_selection,
    opened_url,
    calculated,
    opened_dictionary,
    ran_command,
};

pub const ActionResult = struct {
    kind: ActionResultKind,
    text: ?[]const u8 = null,
};

pub const Selection = struct {
    text: []const u8,
    bounds: ?Rect = null,
    origin_app: ?[]const u8 = null,
    has_selection: bool = true,
    can_paste: bool = false,
};

pub const PopupPlacement = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    arrow_below: bool, // arrow points down to selection below
};
