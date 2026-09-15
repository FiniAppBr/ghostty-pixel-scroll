//! Local echo prediction.
//!
//! Over a link with a round trip, every typed character waits for the far
//! end to echo it back before it appears. mosh solves this by predicting
//! the echo, but it has to own the whole screen to do so, which costs the
//! scrollback that smooth scrolling scrolls through. A terminal does not
//! have that problem: it already owns the screen, so it can draw a
//! character the moment it is typed and reconcile when the echo lands,
//! leaving the connection underneath an ordinary stream whose lines scroll
//! into scrollback as usual.
//!
//! This file is only the decision of *whether and what* to predict. It
//! touches no terminal state and does no drawing, so it can be reasoned
//! about — and tested — on its own.
//!
//! The whole design is biased towards not predicting. A prediction that
//! turns out wrong is a character that appears and then changes under the
//! reader, which is more distracting than the lag it saves. Worse, a
//! prediction made at a password prompt puts a password on screen. So
//! every uncertainty resolves to silence, and predicting has to be earned
//! by watching the far end echo correctly first.

const std = @import("std");
const assert = std.debug.assert;

/// How much the far end has earned our trust.
pub const Epoch = enum {
    /// Not drawing ahead. Keys are sent and we watch whether they come
    /// back, which is how predicting is earned in the first place.
    observing,

    /// Echo has been seen working often enough to draw ahead of it.
    predicting,

    /// Typing stopped coming back at all, which is what a password prompt
    /// looks like from here. Nothing is drawn, and nothing will be until
    /// echo is seen again.
    silent,
};

/// What an arriving codepoint did to the queue.
pub const Outcome = enum {
    /// It matched the oldest thing we were waiting for.
    confirmed,

    /// It was not what we were waiting for, so everything in flight is
    /// suspect and has been dropped.
    mismatch,

    /// We were not waiting for anything; ordinary output from the far end.
    ignored,
};

pub const Config = struct {
    /// Seconds to wait for an echo before deciding one is not coming.
    /// Needs to be comfortably above the round trip or ordinary slowness
    /// reads as a password prompt; 150ms against a ~50ms link.
    timeout: f32 = 0.15,

    /// Consecutive confirmed echoes before drawing ahead. The cost of
    /// being wrong is higher than the cost of a few slow keystrokes at
    /// the start of a session, so this is deliberately not 1.
    confirm_threshold: u8 = 3,

    /// Do not predict within this many cells of the right margin. What
    /// happens at a wrap depends on the far end's autowrap mode and on
    /// whether the line is continued, which is more than can be guessed.
    margin: u16 = 2,

    /// Draw without first watching the far end echo correctly. This skips
    /// earning trust, not the password guard: once typing has gone
    /// unanswered, nothing is drawn regardless of this.
    eager: bool = false,
};

/// One character we are waiting to see come back.
pub const Entry = struct {
    cp: u21,

    /// Where it would be on screen. Only meaningful when `drawn`.
    x: u16,
    y: u16,

    /// When it was typed, in seconds on the caller's clock.
    at: f32,

    /// Whether this is actually on screen. Entries made while observing
    /// are tracked but not drawn: they exist to learn whether echo works.
    drawn: bool,
};

/// Predictions in flight are bounded by the round trip times how fast
/// anyone types, so a fixed queue avoids allocating on the key path. If
/// it ever fills, that itself is evidence the far end is not keeping up,
/// and the right response is to stop predicting rather than to grow.
pub const capacity = 32;

pub const Engine = struct {
    config: Config = .{},

    epoch: Epoch = .observing,

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// Consecutive confirmations while observing.
    hits: u8 = 0,

    /// Drop everything in flight. Called for anything that is not a plain
    /// printable arriving where we expected one: an escape sequence, a
    /// cursor move, a resize. Rather than work out which predictions
    /// survive such a thing, none of them do.
    pub fn flush(self: *Engine) void {
        self.len = 0;
    }

    /// Give up on predicting and drop what is in flight, but keep watching.
    fn demote(self: *Engine, to: Epoch) void {
        self.flush();
        self.hits = 0;
        self.epoch = to;
    }

    /// A character was typed. Returns true if the caller should draw it
    /// ahead of the far end.
    ///
    /// `x`/`y` are where the cursor is now, `cols` the width of the screen.
    /// Callers must filter to plain printable characters first: control
    /// characters, escapes and editing keys are the caller's business and
    /// must arrive here as a `flush` instead.
    pub fn typed(
        self: *Engine,
        cp: u21,
        x: u16,
        y: u16,
        cols: u16,
        now: f32,
    ) bool {
        // A queue this full means echoes are not coming back in any
        // reasonable time. Stop guessing.
        if (self.len >= capacity) {
            self.demote(.observing);
            return false;
        }

        // Near the margin the next character's position depends on the
        // far end's wrap behaviour, so stop before guessing wrong. Note
        // this only declines to *draw*: the entry is still tracked, so
        // echo confirmation keeps working across the wrap.
        const room = cols -| self.config.margin;
        const trusted = switch (self.epoch) {
            .predicting => true,
            // Eager mode skips earning trust, but never overrides silence:
            // that is the password guard, and it is not negotiable.
            .observing => self.config.eager,
            .silent => false,
        };
        const draw = trusted and x < room;

        self.entries[self.len] = .{
            .cp = cp,
            .x = x,
            .y = y,
            .at = now,
            .drawn = draw,
        };
        self.len += 1;

        return draw;
    }

    /// A printable codepoint arrived from the far end.
    pub fn echoed(self: *Engine, cp: u21) Outcome {
        if (self.len == 0) return .ignored;

        if (self.entries[0].cp != cp) {
            // What came back is not what we typed. Either we mispredicted
            // or the far end is doing something of its own; either way
            // what is on screen cannot be trusted.
            self.demote(.observing);
            return .mismatch;
        }

        // Confirmed: drop it from the front.
        self.len -= 1;
        for (0..self.len) |i| self.entries[i] = self.entries[i + 1];

        switch (self.epoch) {
            // Seeing echo at all is what brings us back from a password
            // prompt, but it only returns us to watching, not to drawing.
            .silent => self.epoch = .observing,

            .observing => {
                self.hits +|= 1;
                if (self.hits >= self.config.confirm_threshold) {
                    self.epoch = .predicting;
                    self.hits = 0;
                }
            },

            .predicting => {},
        }

        return .confirmed;
    }

    /// Called each frame. Abandons anything that has waited too long,
    /// which is how a password prompt is recognised: characters were
    /// typed and nothing came back.
    pub fn tick(self: *Engine, now: f32) void {
        if (self.len == 0) return;
        if (now - self.entries[0].at < self.config.timeout) return;
        self.demote(.silent);
    }

    /// The characters currently drawn ahead of the far end, oldest first.
    /// Entries tracked while not predicting are not included, so this is
    /// exactly what the renderer should be showing.
    pub fn drawn(self: *const Engine, buf: *[capacity]Entry) []const Entry {
        var n: usize = 0;
        for (self.entries[0..self.len]) |e| {
            if (!e.drawn) continue;
            buf[n] = e;
            n += 1;
        }
        return buf[0..n];
    }

    /// Whether anything is on screen that the far end has not confirmed.
    pub fn hasDrawn(self: *const Engine) bool {
        for (self.entries[0..self.len]) |e| if (e.drawn) return true;
        return false;
    }
};

/// Drive `e` to the predicting epoch the honest way, by echoing back what
/// it is told. Used by the tests below.
fn warmUp(e: *Engine, now: f32) void {
    var i: usize = 0;
    while (i < e.config.confirm_threshold) : (i += 1) {
        _ = e.typed('a', 0, 0, 80, now);
        _ = e.echoed('a');
    }
}

test "nothing is drawn until echo has been seen working" {
    var e: Engine = .{};

    // The first characters go out undrawn: we have no evidence yet that
    // anything comes back.
    try std.testing.expect(!e.typed('h', 0, 0, 80, 0));
    try std.testing.expectEqual(Epoch.observing, e.epoch);
    try std.testing.expect(!e.hasDrawn());
}

test "predicting is earned by consecutive confirmations" {
    var e: Engine = .{};
    warmUp(&e, 0);
    try std.testing.expectEqual(Epoch.predicting, e.epoch);

    // Now, and only now, a keystroke is drawn immediately.
    try std.testing.expect(e.typed('x', 5, 2, 80, 0));
    try std.testing.expect(e.hasDrawn());
}

test "a confirmed prediction leaves the queue" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    try std.testing.expectEqual(Outcome.confirmed, e.echoed('x'));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expect(!e.hasDrawn());
}

test "a mismatch drops everything and stops predicting" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    _ = e.typed('y', 6, 2, 80, 0);

    // The far end sent something else entirely.
    try std.testing.expectEqual(Outcome.mismatch, e.echoed('z'));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expectEqual(Epoch.observing, e.epoch);
}

test "silence is treated as a password prompt" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('s', 0, 0, 80, 1.0);
    try std.testing.expect(e.hasDrawn());

    // Nothing comes back for longer than the timeout.
    e.tick(1.0 + e.config.timeout + 0.01);

    try std.testing.expectEqual(Epoch.silent, e.epoch);
    try std.testing.expect(!e.hasDrawn());
}

test "a password prompt keeps predictions off even as typing continues" {
    var e: Engine = .{};
    warmUp(&e, 0);
    _ = e.typed('s', 0, 0, 80, 1.0);
    e.tick(1.0 + e.config.timeout + 0.01);
    try std.testing.expectEqual(Epoch.silent, e.epoch);

    // The rest of the password must not appear on screen.
    try std.testing.expect(!e.typed('e', 0, 0, 80, 1.2));
    try std.testing.expect(!e.typed('c', 0, 0, 80, 1.3));
    try std.testing.expect(!e.hasDrawn());
}

test "echo returning ends the silence but does not resume drawing at once" {
    var e: Engine = .{};
    warmUp(&e, 0);
    _ = e.typed('s', 0, 0, 80, 1.0);
    e.tick(1.0 + e.config.timeout + 0.01);

    // Past the prompt, the shell echoes again.
    _ = e.typed('l', 0, 0, 80, 2.0);
    try std.testing.expectEqual(Outcome.confirmed, e.echoed('l'));

    // Back to watching, not straight back to drawing: trust is re-earned.
    try std.testing.expectEqual(Epoch.observing, e.epoch);
    try std.testing.expect(!e.hasDrawn());
}

test "an escape sequence abandons what is in flight" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    _ = e.typed('y', 6, 2, 80, 0);
    try std.testing.expect(e.hasDrawn());

    e.flush();
    try std.testing.expect(!e.hasDrawn());
    try std.testing.expectEqual(@as(usize, 0), e.len);

    // A flush is not a loss of trust: the far end did nothing wrong.
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
}

test "nothing is drawn near the right margin" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Two cells from the edge, where a wrap would land the character
    // somewhere we cannot predict.
    try std.testing.expect(!e.typed('x', 79, 0, 80, 0));
    try std.testing.expect(!e.typed('x', 78, 0, 80, 0));

    // Comfortably inside, it is drawn as usual.
    try std.testing.expect(e.typed('x', 40, 0, 80, 0));
}

test "an untracked margin character still confirms" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Undrawn because of the margin, but still expected back, so echo
    // accounting does not desynchronise across a wrap.
    try std.testing.expect(!e.typed('x', 79, 0, 80, 0));
    try std.testing.expectEqual(Outcome.confirmed, e.echoed('x'));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "a full queue stops predicting rather than growing" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Type far more than can be in flight, with nothing coming back.
    var i: usize = 0;
    while (i < capacity + 1) : (i += 1) _ = e.typed('x', 0, 0, 80, 0);

    try std.testing.expect(e.len <= capacity);
    try std.testing.expectEqual(Epoch.observing, e.epoch);
    try std.testing.expect(!e.hasDrawn());
}

test "output arriving when nothing was typed is ignored" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // A program writing on its own must not be mistaken for an echo.
    try std.testing.expectEqual(Outcome.ignored, e.echoed('q'));
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
}

test "confirmations are ordered" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('a', 0, 0, 80, 0);
    _ = e.typed('b', 1, 0, 80, 0);
    _ = e.typed('c', 2, 0, 80, 0);

    // Echo arrives in the order it was typed.
    try std.testing.expectEqual(Outcome.confirmed, e.echoed('a'));
    try std.testing.expectEqual(Outcome.confirmed, e.echoed('b'));
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expectEqual(@as(u21, 'c'), e.entries[0].cp);
}

test "drawn reports only what is on screen, in order" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('a', 0, 0, 80, 0);
    _ = e.typed('b', 79, 0, 80, 0); // margin: tracked, not drawn
    _ = e.typed('c', 2, 0, 80, 0);

    var buf: [capacity]Entry = undefined;
    const d = e.drawn(&buf);
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqual(@as(u21, 'a'), d[0].cp);
    try std.testing.expectEqual(@as(u21, 'c'), d[1].cp);
}

test "eager mode draws without waiting to earn it" {
    var e: Engine = .{ .config = .{ .eager = true } };

    // No warm-up: the first keystroke is already on screen.
    try std.testing.expect(e.typed('x', 0, 0, 80, 0));
    try std.testing.expectEqual(Epoch.observing, e.epoch);
}

test "eager mode still refuses at a password prompt" {
    var e: Engine = .{ .config = .{ .eager = true } };

    _ = e.typed('s', 0, 0, 80, 1.0);
    e.tick(1.0 + e.config.timeout + 0.01);
    try std.testing.expectEqual(Epoch.silent, e.epoch);

    // Eagerness does not override silence. This is the guard that keeps
    // passwords off the screen and it outranks every other setting.
    try std.testing.expect(!e.typed('e', 0, 0, 80, 1.2));
    try std.testing.expect(!e.hasDrawn());
}

test "timeout does not fire while echoes keep arriving" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('a', 0, 0, 80, 1.0);
    _ = e.echoed('a');
    _ = e.typed('b', 1, 0, 80, 1.1);

    // The queue's oldest entry is recent even though the session is old.
    e.tick(1.15);
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
    try std.testing.expect(e.hasDrawn());
}
