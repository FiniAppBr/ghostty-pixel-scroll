//! URLs that a program hard-wrapped itself.
//!
//! A TUI such as Claude Code lays out its own text, so a URL longer than the
//! space left on a row is cut at the right edge, a real newline is written,
//! and the rest carries on at the start of the next row behind an indent.
//! The terminal never sees a soft wrap, so copying the URL or clicking it
//! yields the first fragment, or both fragments with "\n   " in the middle.
//!
//! This recognises that shape on screen: a row that ends at (or within a
//! few cells of) the right edge on a URL, followed by a row that opens with
//! more URL characters. Rows that are entirely URL continue the chain.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
const Selection = @import("Selection.zig");
const Cell = @import("page.zig").Cell;

/// How far short of the right edge a row may end and still count as cut
/// there. Claude Code keeps a column or so of margin.
const edge_slack = 3;

/// Upper bound on rows in one chain, so a pathological screen of
/// edge-to-edge URL text can't turn a click into a long walk.
const max_chain = 64;

fn isUrlCell(cell: Cell) bool {
    if (cell.wide != .narrow) return false;
    const cp = cell.codepoint();
    return cp > 0x20 and cp < 0x7f;
}

fn isBlank(cell: Cell) bool {
    const cp = cell.codepoint();
    return cp == 0 or cp == ' ';
}

fn rowCells(pin: Pin) []const Cell {
    return pin.node.page().getCells(pin.rowAndCell().row);
}

const Bounds = struct { first: usize, last: usize };

/// The first and last non-blank cells of a row.
fn bounds(cells: []const Cell) ?Bounds {
    var first: ?usize = null;
    var last: usize = 0;
    for (cells, 0..) |cell, x| {
        if (isBlank(cell)) continue;
        if (first == null) first = x;
        last = x;
    }
    return .{ .first = first orelse return null, .last = last };
}

/// Start of the run of URL cells that ends at `last`.
fn tokenStart(cells: []const Cell, last: usize) usize {
    var x = last;
    while (x > 0 and isUrlCell(cells[x - 1])) x -= 1;
    return x;
}

fn hasScheme(cells: []const Cell) bool {
    if (cells.len < 3) return false;
    for (0..cells.len - 2) |i| {
        if (cells[i].codepoint() == ':' and
            cells[i + 1].codepoint() == '/' and
            cells[i + 2].codepoint() == '/') return true;
    }
    return false;
}

/// Whether the row at `pin` ends in a URL that the program broke onto the
/// next row.
pub fn continues(pin: Pin) bool {
    var p = pin;
    for (0..max_chain) |_| {
        const rac = p.rowAndCell();
        // A soft wrap is the terminal's own and already joins.
        if (rac.row.wrap) return false;

        const cells = rowCells(p);
        const b = bounds(cells) orelse return false;
        if (b.last + 1 + edge_slack < cells.len) return false;
        if (!isUrlCell(cells[b.last])) return false;

        const next = p.down(1) orelse return false;
        const next_cells = rowCells(next);
        const nb = bounds(next_cells) orelse return false;
        if (!isUrlCell(next_cells[nb.first])) return false;

        const start = tokenStart(cells, b.last);
        if (hasScheme(cells[start .. b.last + 1])) return true;

        // No scheme here, so this row is only part of a URL if all of it
        // is URL and the row above carried one into it.
        if (start != b.first) return false;
        p = p.up(1) orelse return false;
    }
    return false;
}

/// The row a hard-wrapped URL running through `pin`'s row starts on, or
/// `pin`'s own row if no URL was carried into it.
pub fn head(pin: Pin) Pin {
    var p = pin;
    for (0..max_chain) |_| {
        const up = p.up(1) orelse break;
        if (!continues(up)) break;
        p = up;
    }
    return p;
}

/// Given the last cell of a link match, returns the last cell of the URL
/// once the rows it was broken onto are followed. Returns `end` unchanged
/// when the URL wasn't broken.
pub fn extendEnd(end: Pin) Pin {
    var p = end;
    for (0..max_chain) |_| {
        const cells = rowCells(p);
        const b = bounds(cells) orelse break;
        // The match has to end in the row's trailing run of URL cells. Not
        // necessarily on its last cell: the link regex drops a trailing "."
        // and the like, which may be where the row got cut.
        if (p.x < tokenStart(cells, b.last) or p.x > b.last) break;
        if (!continues(p)) break;

        var next = p.down(1).?;
        const next_cells = rowCells(next);
        const nb = bounds(next_cells).?;
        var x = nb.first;
        while (x + 1 < next_cells.len and isUrlCell(next_cells[x + 1])) x += 1;
        next.x = @intCast(x);
        p = next;
    }
    return p;
}

/// Removes the line breaks, and the indent after each, that a URL was cut
/// at. `text` must be the plain text the formatter wrote for `sel` with
/// unwrap on, so its newlines line up one-to-one with the hard row ends the
/// selection crosses. Works in place; returns the shortened text.
pub fn joinSelection(screen: *const Screen, sel: Selection, text: [:0]u8) [:0]u8 {
    if (sel.rectangle) return text;
    var row: ?Pin = sel.topLeft(screen);

    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '\n') {
            text[w] = c;
            w += 1;
            i += 1;
            continue;
        }

        // Find the row this newline ends: soft-wrapped rows wrote none.
        while (row) |r| {
            if (!r.rowAndCell().row.wrap) break;
            row = r.down(1);
        }
        const join = if (row) |r| continues(r) else false;
        row = if (row) |r| r.down(1) else null;

        i += 1;
        if (join) {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        } else {
            text[w] = '\n';
            w += 1;
        }
    }

    text[w] = 0;
    return text[0..w :0];
}

/// A link's text with the breaks it was cut at taken out. Inside a single
/// link a newline is never meant, so every "\n" and the indent after it
/// goes. Returns a new allocation.
pub fn joinLink(alloc: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            i += 1;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
            continue;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

// Claude Code's shape, at 30 columns: the URL fills the row to the edge and
// carries on behind a two-space indent.
const claude_text =
    "- Canyon: https://dev.example\n" ++
    "  .town/?dev=1&name=Luiz&spaw\n" ++
    "  n=proving-canyon\n" ++
    "next line of prose here";

fn testPin(s: *Screen, x: usize, y: usize) Pin {
    return s.pages.pin(.{ .active = .{
        .x = @intCast(x),
        .y = @intCast(y),
    } }).?;
}

test "continues across a chain of rows" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 6, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(claude_text);

    try testing.expect(continues(testPin(&s, 0, 0)));
    try testing.expect(continues(testPin(&s, 0, 1)));
    try testing.expect(!continues(testPin(&s, 0, 2)));
    try testing.expect(!continues(testPin(&s, 0, 3)));

    const h = head(testPin(&s, 5, 2));
    try testing.expectEqual(@as(usize, 0), h.y);
}

test "prose that ends short of the edge is left alone" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("see https://example.com\n  and more text");
    try testing.expect(!continues(testPin(&s, 0, 0)));
}

test "a full row of words that isn't a URL is left alone" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("this row is full of plain word\n  continued");
    try testing.expect(!continues(testPin(&s, 0, 0)));
}

test "extendEnd follows the URL to its last row" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 6, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(claude_text);

    const end = extendEnd(testPin(&s, 28, 0));
    try testing.expectEqual(@as(usize, 2), end.y);
    try testing.expectEqual(@as(usize, 17), end.x);

    // A match that doesn't reach the row's end isn't extended.
    const short = extendEnd(testPin(&s, 3, 0));
    try testing.expectEqual(@as(usize, 0), short.y);
}

test "joinSelection drops the cut and keeps real line breaks" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 6, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(claude_text);

    const sel = Selection.init(testPin(&s, 0, 0), testPin(&s, 22, 3), false);
    const raw = try s.selectionString(alloc, .{ .sel = sel, .trim = true });
    defer alloc.free(raw);
    const buf = try alloc.dupeZ(u8, raw);
    defer alloc.free(buf);

    try testing.expectEqualStrings(
        "- Canyon: https://dev.example.town/?dev=1&name=Luiz&spawn=proving-canyon\n" ++
            "next line of prose here",
        joinSelection(&s, sel, buf),
    );
}

test "joinSelection starting mid-URL" {
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 30, .rows = 6, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(claude_text);

    const sel = Selection.init(testPin(&s, 10, 0), testPin(&s, 17, 2), false);
    const raw = try s.selectionString(alloc, .{ .sel = sel, .trim = true });
    defer alloc.free(raw);
    const buf = try alloc.dupeZ(u8, raw);
    defer alloc.free(buf);

    try testing.expectEqualStrings(
        "https://dev.example.town/?dev=1&name=Luiz&spawn=proving-canyon",
        joinSelection(&s, sel, buf),
    );
}

test "joinLink" {
    const alloc = testing.allocator;
    const out = try joinLink(alloc, "https://a.b/c\n  d?e=1\n  f");
    defer alloc.free(out);
    try testing.expectEqualStrings("https://a.b/cd?e=1f", out);
}
