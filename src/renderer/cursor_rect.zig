//! The cursor rectangle handed to custom shaders.
//!
//! Ghostty reports the cursor as (left, +Y edge, width, height), so that a
//! shader finds its centre with `y - h * 0.5` whichever way up the graphics
//! API's coordinates run. Getting that rectangle right means reporting where
//! the cursor is *drawn*, which is not simply where its cell sits:
//!
//!   * the whole grid is displaced while a smooth scroll is in flight, the
//!     cursor along with it, and
//!   * each corner of the cursor carries its own spring offset while it
//!     travels to a new cell, so a moving cursor is stretched away from the
//!     cell it belongs to.
//!
//! Leave either out and a shader that follows the cursor — a glow riding the
//! write position, say — trails behind the thing it is following. Streamed
//! output is the worst case, because it scrolls continuously: the rectangle
//! is then wrong for as long as text keeps arriving.

const std = @import("std");

pub const Input = struct {
    /// Left and top edge of the cell the cursor is in, in grid pixels with
    /// +Y down, before any animation is applied.
    cell_x: f32,
    cell_y: f32,

    /// Cell height, for turning the Y bearing into an edge.
    cell_height: f32,

    /// Height of the whole drawable. Only used when +Y is up.
    screen_height: f32,

    /// The cursor glyph's bearings. The Y bearing is the distance from the
    /// bottom of the cell to the top of the glyph.
    bearing_x: f32,
    bearing_y: f32,

    /// The cursor glyph's size, which is what we report as the rectangle's
    /// width and height.
    glyph_width: f32,
    glyph_height: f32,

    /// How far the grid is displaced by a smooth scroll in flight. Positive
    /// draws the grid lower. See `projectionMatrix`.
    grid_offset_y: f32 = 0,

    /// Per-corner spring offsets in grid pixels, top-left, top-right,
    /// bottom-right, bottom-left. See `CornerCursor.offsets`.
    corner_offsets: [4][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
};

/// The rectangle to hand a custom shader, in the shader's own coordinates.
pub fn compute(comptime y_is_down: bool, in: Input) [4]f32 {
    // The cursor stretches while it travels, each corner on its own spring.
    // A shader gets one rectangle, so report the middle of that stretch.
    var dx: f32 = 0;
    var dy: f32 = 0;
    for (in.corner_offsets) |c| {
        dx += c[0];
        dy += c[1];
    }
    dx /= 4;
    dy /= 4;

    // Add the X bearing to get the -X (left) edge of the cursor.
    const pixel_x = in.cell_x + in.bearing_x + dx;

    // Both displacements are in grid pixels with +Y down, so they have to be
    // applied before any flip, and the flip then gets their sign right.
    var pixel_y = in.cell_y + in.grid_offset_y + dy;

    // If +Y is up in our shaders, flip to the top edge of the cell relative
    // to the *bottom* of the screen.
    if (!y_is_down) pixel_y = in.screen_height - pixel_y;

    // How we deal with the Y bearing depends on which direction is "up",
    // since we want our final `pixel_y` to be the +Y edge of the cursor.
    if (y_is_down) {
        // The Y bearing is the distance from the bottom of the cell to the
        // top of the glyph, so add the cell height, subtract the bearing and
        // add the glyph height to land on the +Y (bottom) edge.
        pixel_y += in.cell_height;
        pixel_y -= in.bearing_y;
        pixel_y += in.glyph_height;
    } else {
        // Reversed, we want the *top* edge, so subtract the cell height and
        // add the bearing.
        pixel_y -= in.cell_height;
        pixel_y += in.bearing_y;
    }

    return .{ pixel_x, pixel_y, in.glyph_width, in.glyph_height };
}

/// The centre of a rectangle, the way every cursor shader finds it.
fn centre(rect: [4]f32) [2]f32 {
    return .{ rect[0] + rect[2] * 0.5, rect[1] - rect[3] * 0.5 };
}

/// A block cursor sits in a 10x20 cell at column 3, row 4, with the sprite
/// filling the cell: the Y bearing is the cell height and so is the glyph.
fn blockCursor() Input {
    return .{
        .cell_x = 3 * 10,
        .cell_y = 4 * 20,
        .cell_height = 20,
        .screen_height = 400,
        .bearing_x = 0,
        .bearing_y = 20,
        .glyph_width = 10,
        .glyph_height = 20,
    };
}

test "a settled block cursor reports the cell it is in" {
    const r = compute(true, blockCursor());
    // Left edge, and the +Y (bottom) edge of row 4.
    try std.testing.expectEqual(@as(f32, 30), r[0]);
    try std.testing.expectEqual(@as(f32, 100), r[1]);
    try std.testing.expectEqual(@as(f32, 10), r[2]);
    try std.testing.expectEqual(@as(f32, 20), r[3]);
}

test "y - h/2 lands in the middle of the cell, which is what shaders rely on" {
    const c = centre(compute(true, blockCursor()));
    try std.testing.expectEqual(@as(f32, 35), c[0]);
    try std.testing.expectEqual(@as(f32, 90), c[1]);
}

test "a scroll in flight carries the rectangle with the grid" {
    var in = blockCursor();
    in.grid_offset_y = 7;
    const r = compute(true, in);
    // A positive offset draws the grid lower, so the rectangle moves down
    // with it. This is the case that breaks during streamed output, where
    // the screen is scrolling for as long as text keeps arriving.
    try std.testing.expectEqual(@as(f32, 107), r[1]);
}

test "a scroll in flight carries the rectangle with the grid, +Y up" {
    var in = blockCursor();
    in.grid_offset_y = 7;
    const settled = compute(false, blockCursor());
    const scrolled = compute(false, in);
    // Drawn lower on screen is a *smaller* +Y when +Y points up.
    try std.testing.expectEqual(settled[1] - 7, scrolled[1]);
}

test "the rectangle follows the cursor's corner springs" {
    var in = blockCursor();
    const off: [2]f32 = .{ 4, -6 };
    in.corner_offsets = @splat(off);
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 34), r[0]);
    try std.testing.expectEqual(@as(f32, 94), r[1]);
}

test "a stretching cursor reports the middle of the stretch" {
    var in = blockCursor();
    // Leading corners have arrived, trailing corners are still behind.
    in.corner_offsets = .{ .{ 0, 0 }, .{ 0, 0 }, .{ -8, 0 }, .{ -8, 0 } };
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 30 - 4), r[0]);
}

test "both displacements apply together" {
    var in = blockCursor();
    in.grid_offset_y = 7;
    const off: [2]f32 = .{ 0, 3 };
    in.corner_offsets = @splat(off);
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 110), r[1]);
}

test "a settled cursor is unmoved, which is the behaviour that used to hold" {
    // Everything at rest must produce exactly what the old inline code did,
    // or this fix would move the cursor for every shader that was already
    // aligned when nothing is animating.
    const r = compute(true, blockCursor());
    var in = blockCursor();
    in.grid_offset_y = 0;
    in.corner_offsets = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    try std.testing.expectEqual(r, compute(true, in));
}

test "a bar cursor reports its own narrow rectangle, not the cell" {
    var in = blockCursor();
    in.glyph_width = 2;
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 2), r[2]);
    // Still bottom-aligned with the cell.
    try std.testing.expectEqual(@as(f32, 100), r[1]);
}

test "an underline cursor sits at the bottom of the cell" {
    var in = blockCursor();
    in.glyph_height = 2;
    in.bearing_y = 2; // the glyph's top is 2px above the cell bottom
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 100), r[1]);
    try std.testing.expectEqual(@as(f32, 99), centre(r)[1]);
}

test "the write head is reported as a whole cell" {
    // The write head has no glyph of its own, so it is reported with the
    // bearing and size of the cell it sits in. A shader then treats it
    // exactly like a block cursor and does not need to know which it got.
    var in = blockCursor();
    in.bearing_x = 0;
    in.bearing_y = in.cell_height;
    in.glyph_width = 10;
    in.glyph_height = in.cell_height;
    const r = compute(true, in);
    try std.testing.expectEqual(@as(f32, 30), r[0]);
    try std.testing.expectEqual(@as(f32, 100), r[1]);
    try std.testing.expectEqual(@as(f32, 90), centre(r)[1]);
}

test "+Y up and +Y down describe the same rectangle on screen" {
    const down = compute(true, blockCursor());
    const up = compute(false, blockCursor());
    // The centre is the same distance from opposite edges of a 400px screen.
    try std.testing.expectEqual(400 - centre(down)[1], centre(up)[1]);
}
