//! actions.zig — Comprehensive PopClip actions, detectors, and executors
const std = @import("std");
const types = @import("types.zig");
const Action = types.Action;
const ActionKind = types.ActionKind;
const ActionResult = types.ActionResult;
const Selection = types.Selection;

// MARK: - URL & Email Detection

pub fn isUrl(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 4) return false;

    if (std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "www.") or
        std.mem.startsWith(u8, trimmed, "ftp://"))
    {
        return true;
    }

    // Check if it's a domain-like pattern (e.g. "github.com", "example.org/path")
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return false;
    const dot_idx = std.mem.indexOfScalar(u8, trimmed, '.') orelse return false;
    if (dot_idx == 0 or dot_idx >= trimmed.len - 2) return false;

    // Check common TLDs
    const tlds = [_][]const u8{ ".com", ".org", ".net", ".io", ".dev", ".ai", ".app", ".me", ".co", ".edu", ".gov", ".cn" };
    for (tlds) |tld| {
        if (std.mem.indexOf(u8, trimmed, tld) != null) return true;
    }
    return false;
}

pub fn isEmail(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 5) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return false;

    const at_idx = std.mem.indexOfScalar(u8, trimmed, '@') orelse return false;
    if (at_idx == 0 or at_idx >= trimmed.len - 3) return false;

    const domain_part = trimmed[at_idx + 1 ..];
    const dot_idx = std.mem.indexOfScalar(u8, domain_part, '.') orelse return false;
    if (dot_idx == 0 or dot_idx >= domain_part.len - 1) return false;

    return true;
}

// MARK: - Math Expression Evaluator

pub const MathError = error{
    InvalidToken,
    MismatchedParentheses,
    DivisionByZero,
    EmptyExpression,
    SyntaxError,
};

pub fn evaluateMath(allocator: std.mem.Allocator, text: []const u8) !?f64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Must contain at least one math operator to qualify as math expression
    var has_operator = false;
    for (trimmed) |c| {
        if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^') {
            has_operator = true;
        } else if (!std.ascii.isDigit(c) and c != '.' and c != '(' and c != ')' and c != ' ' and c != '\t') {
            // Non-math character -> reject
            return null;
        }
    }
    if (!has_operator) return null;

    return evaluateExpression(allocator, trimmed) catch null;
}

fn evaluateExpression(allocator: std.mem.Allocator, expr: []const u8) !f64 {
    var values: std.ArrayListUnmanaged(f64) = .empty;
    defer values.deinit(allocator);

    var ops: std.ArrayListUnmanaged(u8) = .empty;
    defer ops.deinit(allocator);

    var i: usize = 0;
    var expect_operand = true;

    while (i < expr.len) {
        const c = expr[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }

        if (std.ascii.isDigit(c) or (c == '.' and i + 1 < expr.len and std.ascii.isDigit(expr[i + 1])) or
            (c == '-' and expect_operand and i + 1 < expr.len and (std.ascii.isDigit(expr[i + 1]) or expr[i + 1] == '.')))
        {
            // Parse number
            const start = i;
            if (c == '-') i += 1;
            var has_dot = false;
            while (i < expr.len) {
                const ch = expr[i];
                if (std.ascii.isDigit(ch)) {
                    i += 1;
                } else if (ch == '.' and !has_dot) {
                    has_dot = true;
                    i += 1;
                } else {
                    break;
                }
            }
            const num = std.fmt.parseFloat(f64, expr[start..i]) catch return MathError.InvalidToken;
            try values.append(allocator, num);
            expect_operand = false;
        } else if (c == '(') {
            try ops.append(allocator, '(');
            expect_operand = true;
            i += 1;
        } else if (c == ')') {
            while (ops.items.len > 0 and ops.items[ops.items.len - 1] != '(') {
                const op = ops.pop().?;
                try applyOp(&values, op);
            }
            if (ops.items.len == 0) return MathError.MismatchedParentheses;
            _ = ops.pop(); // Pop '('
            expect_operand = false;
            i += 1;
        } else if (isOp(c)) {
            while (ops.items.len > 0 and precedence(ops.items[ops.items.len - 1]) >= precedence(c)) {
                const top_op = ops.items[ops.items.len - 1];
                if (top_op == '(') break;
                _ = ops.pop();
                try applyOp(&values, top_op);
            }
            try ops.append(allocator, c);
            expect_operand = true;
            i += 1;
        } else {
            return MathError.InvalidToken;
        }
    }

    while (ops.items.len > 0) {
        const op = ops.pop().?;
        if (op == '(' or op == ')') return MathError.MismatchedParentheses;
        try applyOp(&values, op);
    }

    if (values.items.len != 1) return MathError.SyntaxError;
    return values.items[0];
}

fn isOp(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^';
}

fn precedence(op: u8) u8 {
    return switch (op) {
        '+', '-' => 1,
        '*', '/', '%' => 2,
        '^' => 3,
        else => 0,
    };
}

fn applyOp(values: *std.ArrayListUnmanaged(f64), op: u8) !void {
    if (values.items.len < 2) return MathError.SyntaxError;
    const b = values.pop().?;
    const a = values.pop().?;
    const res: f64 = switch (op) {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => if (b == 0) return MathError.DivisionByZero else a / b,
        '%' => @mod(a, b),
        '^' => std.math.pow(f64, a, b),
        else => return MathError.InvalidToken,
    };
    try values.append(std.heap.page_allocator, res);
}

// MARK: - Text Transformations

pub fn toUpper(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const res = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| {
        res[i] = std.ascii.toUpper(c);
    }
    return res;
}

pub fn toLower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const res = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| {
        res[i] = std.ascii.toLower(c);
    }
    return res;
}

pub fn toTitleCase(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const res = try allocator.alloc(u8, text.len);
    var cap_next = true;
    for (text, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            if (cap_next) {
                res[i] = std.ascii.toUpper(c);
                cap_next = false;
            } else {
                res[i] = std.ascii.toLower(c);
            }
        } else {
            res[i] = c;
            cap_next = true;
        }
    }
    return res;
}

pub fn toMarkdownBold(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "**{s}**", .{text});
}

pub fn toMarkdownItalic(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "*{s}*", .{text});
}

pub fn toMarkdownCode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "`{s}`", .{text});
}

pub fn toMarkdownQuote(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "> {s}", .{text});
}
pub fn appendClipboard(allocator: std.mem.Allocator, current: ?[]const u8, addition: []const u8) ![]u8 {
    if (current) |c| {
        if (c.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ c, addition });
        }
    }
    return allocator.dupe(u8, addition);
}


// MARK: - Word & Character Stats

pub const TextStats = struct {
    words: usize,
    chars: usize,
    lines: usize,
};

pub fn countStats(text: []const u8) TextStats {
    var words: usize = 0;
    var lines: usize = if (text.len > 0) 1 else 0;
    var in_word = false;

    for (text) |c| {
        if (c == '\n') lines += 1;
        if (std.ascii.isWhitespace(c)) {
            in_word = false;
        } else if (!in_word) {
            words += 1;
            in_word = true;
        }
    }
    return TextStats{
        .words = words,
        .chars = text.len,
        .lines = lines,
    };
}

// MARK: - Extension YAML Parser

pub const YamlExtension = struct {
    name: []const u8,
    icon: ?[]const u8 = null,
    url: ?[]const u8 = null,
    shell_script: ?[]const u8 = null,
    key_combo: ?[]const u8 = null,
};

pub fn parseYamlExtension(allocator: std.mem.Allocator, yaml: []const u8) !?YamlExtension {
    // Check header: #popclip or #xpop
    const trimmed = std.mem.trim(u8, yaml, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "#popclip") and
        !std.mem.startsWith(u8, trimmed, "# popclip") and
        !std.mem.startsWith(u8, trimmed, "#xpop") and
        !std.mem.startsWith(u8, trimmed, "# xpop"))
    {
        return null;
    }

    var name: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var shell_script: ?[]const u8 = null;
    var key_combo: ?[]const u8 = null;

    var line_iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
            const key = std.mem.trim(u8, line[0..colon_idx], " \t");
            var val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t\"");
            if (std.mem.startsWith(u8, val, "\"") and std.mem.endsWith(u8, val, "\"")) {
                val = val[1 .. val.len - 1];
            } else if (std.mem.startsWith(u8, val, "'") and std.mem.endsWith(u8, val, "'")) {
                val = val[1 .. val.len - 1];
            }

            if (std.mem.eql(u8, key, "name")) {
                name = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "icon")) {
                icon = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "url")) {
                url = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "shell script")) {
                shell_script = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "key combo")) {
                key_combo = try allocator.dupe(u8, val);
            }
        }
    }

    if (name) |n| {
        return YamlExtension{
            .name = n,
            .icon = icon,
            .url = url,
            .shell_script = shell_script,
            .key_combo = key_combo,
        };
    }
    return null;
}

// MARK: - Action Determination Engine

pub fn getActionsForSelection(
    allocator: std.mem.Allocator,
    sel: Selection,
) ![]Action {
    var list: std.ArrayListUnmanaged(Action) = .empty;
    errdefer list.deinit(allocator);
    const trimmed = std.mem.trim(u8, sel.text, " \t\r\n");
    if (trimmed.len > 0) {
        // Standard clipboard actions
        try list.append(allocator, .{ .id = "copy", .label = "Copy", .icon = ActionKind.copy.icon(), .kind = .copy });
        try list.append(allocator, .{ .id = "cut", .label = "Cut", .icon = ActionKind.cut.icon(), .kind = .cut });

        // Terminal, Append to Clipboard, and Notes actions (matching Image #1)
        try list.append(allocator, .{ .id = "terminal", .label = ">_", .icon = ActionKind.terminal.icon(), .kind = .terminal });
        try list.append(allocator, .{ .id = "append", .label = "+", .icon = ActionKind.append_clipboard.icon(), .kind = .append_clipboard });
        try list.append(allocator, .{ .id = "notes", .label = "Notes", .icon = ActionKind.notes.icon(), .kind = .notes });

        // Search action
        try list.append(allocator, .{ .id = "search", .label = "Search", .icon = ActionKind.search.icon(), .kind = .search });
        // Contextual: Open URL
        if (isUrl(trimmed)) {
            try list.append(allocator, .{ .id = "open_url", .label = "Open Link", .icon = ActionKind.open_url.icon(), .kind = .open_url, .payload = trimmed });
        }

        // Contextual: Email
        if (isEmail(trimmed)) {
            try list.append(allocator, .{ .id = "email", .label = "Email", .icon = ActionKind.email.icon(), .kind = .email, .payload = trimmed });
        }

        // Contextual: Math evaluation
        if (evaluateMath(allocator, trimmed) catch null) |result| {
            var buf: [64]u8 = undefined;
            const res_str = if (@round(result) == result)
                std.fmt.bufPrint(&buf, "= {d}", .{@as(i64, @intFromFloat(result))}) catch "= 0"
            else
                std.fmt.bufPrint(&buf, "= {d:.4}", .{result}) catch "= 0";

            const payload = try allocator.dupe(u8, res_str);
            try list.append(allocator, .{ .id = "calculate", .label = payload, .icon = ActionKind.calculate.icon(), .kind = .calculate, .payload = payload });
        }

        // Single word: Dictionary / Define
        if (std.mem.indexOfScalar(u8, trimmed, ' ') == null and trimmed.len <= 30) {
            try list.append(allocator, .{ .id = "dictionary", .label = "Define", .icon = ActionKind.dictionary.icon(), .kind = .dictionary });
        }

        // Case transforms
        try list.append(allocator, .{ .id = "upper", .label = "UPPER", .icon = ActionKind.upper_case.icon(), .kind = .upper_case });
        try list.append(allocator, .{ .id = "lower", .label = "lower", .icon = ActionKind.lower_case.icon(), .kind = .lower_case });
        try list.append(allocator, .{ .id = "title", .label = "Title", .icon = ActionKind.title_case.icon(), .kind = .title_case });

        // Markdown formatting
        try list.append(allocator, .{ .id = "md_bold", .label = "**B**", .icon = ActionKind.markdown_bold.icon(), .kind = .markdown_bold });
        try list.append(allocator, .{ .id = "md_code", .label = "`code`", .icon = ActionKind.markdown_code.icon(), .kind = .markdown_code });

        // Word count action
        const stats = countStats(trimmed);
        var count_buf: [64]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}w, {d}c", .{ stats.words, stats.chars }) catch "Count";
        const count_payload = try allocator.dupe(u8, count_str);
        try list.append(allocator, .{ .id = "word_count", .label = count_payload, .icon = ActionKind.word_count.icon(), .kind = .word_count, .payload = count_payload });
    }

    if (sel.can_paste) {
        try list.append(allocator, .{ .id = "paste", .label = "Paste", .icon = ActionKind.paste.icon(), .kind = .paste });
    }

    return list.toOwnedSlice(allocator);
}

// MARK: - Unit Tests

test "isUrl correctly identifies URLs" {
    try std.testing.expect(isUrl("https://github.com/justrach/nanoui"));
    try std.testing.expect(isUrl("http://example.com/test?q=1"));
    try std.testing.expect(isUrl("www.google.com"));
    try std.testing.expect(isUrl("pilotmoon.com/popclip"));
    try std.testing.expect(!isUrl("hello world"));
    try std.testing.expect(!isUrl("just plain text"));
}

test "isEmail correctly identifies emails" {
    try std.testing.expect(isEmail("support@pilotmoon.com"));
    try std.testing.expect(isEmail("dev@nanoui.org"));
    try std.testing.expect(!isEmail("not an email"));
    try std.testing.expect(!isEmail("invalid@domain"));
}

test "evaluateMath calculates expressions correctly" {
    const allocator = std.testing.allocator;
    const res1 = (try evaluateMath(allocator, "12 + 34 * 2")).?;
    try std.testing.expectEqual(@as(f64, 80.0), res1);

    const res2 = (try evaluateMath(allocator, "(100 - 20) / 4")).?;
    try std.testing.expectEqual(@as(f64, 20.0), res2);

    const res3 = (try evaluateMath(allocator, "2 ^ 10")).?;
    try std.testing.expectEqual(@as(f64, 1024.0), res3);

    // Non math text should return null
    try std.testing.expect((try evaluateMath(allocator, "just some text")) == null);
}

test "text transforms work" {
    const allocator = std.testing.allocator;
    const upper = try toUpper(allocator, "hello world");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("HELLO WORLD", upper);

    const title = try toTitleCase(allocator, "hello world from zig");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("Hello World From Zig", title);

    const bold = try toMarkdownBold(allocator, "bolded");
    defer allocator.free(bold);
    try std.testing.expectEqualStrings("**bolded**", bold);
}

test "countStats works" {
    const stats = countStats("The quick brown fox jumps");
    try std.testing.expectEqual(@as(usize, 5), stats.words);
    try std.testing.expectEqual(@as(usize, 25), stats.chars);
}

test "parseYamlExtension parses #popclip snippet" {
    const allocator = std.testing.allocator;
    const snippet =
        \\#popclip
        \\name: Google Search
        \\icon: magnifyingglass
        \\url: https://www.google.com/search?q=***
    ;
    const ext = (try parseYamlExtension(allocator, snippet)).?;
    defer {
        allocator.free(ext.name);
        if (ext.icon) |ic| allocator.free(ic);
        if (ext.url) |u| allocator.free(u);
    }
    try std.testing.expectEqualStrings("Google Search", ext.name);
    try std.testing.expectEqualStrings("magnifyingglass", ext.icon.?);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=***", ext.url.?);
}

test "appendClipboard correctly appends to clipboard" {
    const allocator = std.testing.allocator;
    const res = try appendClipboard(allocator, "First line", "Second line");
    defer allocator.free(res);
    try std.testing.expectEqualStrings("First line\nSecond line", res);

    const empty_res = try appendClipboard(allocator, null, "Only line");
    defer allocator.free(empty_res);
    try std.testing.expectEqualStrings("Only line", empty_res);
}
