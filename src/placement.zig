//! placement.zig — Popup placement calculation logic
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const PopupPlacement = types.PopupPlacement;

pub const ScreenBounds = struct {
    width: f64 = 1728,
    height: f64 = 1117,
    menu_bar_height: f64 = 32,
    margin: f64 = 12,
};

/// Calculates popup origin (x, y) and orientation given selection rect and popup dimensions.
pub fn calculatePlacement(
    sel: Rect,
    popup_w: f64,
    popup_h: f64,
    screen: ScreenBounds,
) PopupPlacement {
    // 1. Center horizontally on selection
    var x = sel.x + (sel.width - popup_w) / 2.0;

    // Clamp horizontally to screen bounds
    if (x < screen.margin) {
        x = screen.margin;
    } else if (x + popup_w > screen.width - screen.margin) {
        x = screen.width - screen.margin - popup_w;
    }

    // 2. Vertical placement
    const gap: f64 = 8.0;
    const y_above = sel.y - popup_h - gap;
    var y: f64 = undefined;
    var arrow_below: bool = true;

    if (y_above >= screen.menu_bar_height + screen.margin) {
        // Fits above selection
        y = y_above;
        arrow_below = true;
    } else {
        // Flip below selection
        y = sel.y + sel.height + gap;
        arrow_below = false;

        // If bottom extends off screen, clamp
        if (y + popup_h > screen.height - screen.margin) {
            y = screen.height - screen.margin - popup_h;
        }
    }

    return PopupPlacement{
        .x = x,
        .y = y,
        .width = popup_w,
        .height = popup_h,
        .arrow_below = arrow_below,
    };
}

test "calculatePlacement centers horizontally" {
    const screen = ScreenBounds{ .width = 1000, .height = 800, .menu_bar_height = 30, .margin = 10 };
    const sel = Rect{ .x = 400, .y = 300, .width = 100, .height = 20 };
    const placement = calculatePlacement(sel, 200, 40, screen);

    // sel center is 400 + 50 = 450. popup center is x + 100 -> x = 350
    try std.testing.expectEqual(@as(f64, 350.0), placement.x);
    // placed above: 300 - 40 - 8 = 252
    try std.testing.expectEqual(@as(f64, 252.0), placement.y);
    try std.testing.expect(placement.arrow_below);
}

test "calculatePlacement clamps to left and right margins" {
    const screen = ScreenBounds{ .width = 1000, .height = 800, .menu_bar_height = 30, .margin = 10 };
    // Near left edge
    const sel_left = Rect{ .x = 5, .y = 300, .width = 20, .height = 20 };
    const p_left = calculatePlacement(sel_left, 200, 40, screen);
    try std.testing.expectEqual(@as(f64, 10.0), p_left.x);

    // Near right edge
    const sel_right = Rect{ .x = 980, .y = 300, .width = 20, .height = 20 };
    const p_right = calculatePlacement(sel_right, 200, 40, screen);
    try std.testing.expectEqual(@as(f64, 790.0), p_right.x);
}

test "calculatePlacement flips below if near top of screen" {
    const screen = ScreenBounds{ .width = 1000, .height = 800, .menu_bar_height = 30, .margin = 10 };
    // Very close to top (e.g. y = 35)
    const sel_top = Rect{ .x = 400, .y = 35, .width = 100, .height = 20 };
    const p_top = calculatePlacement(sel_top, 200, 40, screen);

    // Should flip below: 35 + 20 + 8 = 63
    try std.testing.expectEqual(@as(f64, 63.0), p_top.y);
    try std.testing.expect(!p_top.arrow_below);
}
