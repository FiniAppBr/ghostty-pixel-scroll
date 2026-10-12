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
    /// The shortest wait for an echo before deciding one is not coming,
    /// in seconds. The real wait follows the measured round trip, the way
    /// TCP sets its retransmit timer, so a link that is slow or jittery
    /// waits longer rather than having every late echo read as a password
    /// prompt. This is only the floor under that.
    timeout: f32 = 0.15,

    /// The longest wait, however bad the link has been measured to be.
    max_timeout: f32 = 1.0,

    /// Consecutive confirmed echoes before drawing ahead for the first
    /// time. The cost of being wrong is higher than the cost of a few slow
    /// keystrokes at the start of a session, so this is deliberately not 1.
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

    /// Where it will land, in the active screen's coordinates.
    x: u16,
    y: u16,

    /// When it was typed, in seconds on the caller's clock.
    at: f32,

    /// Whether it is far enough from the margin to draw at all. Whether it
    /// is drawn *now* also depends on how much the far end is trusted,
    /// which can change while it is in flight; see `Engine.drawing`.
    drawable: bool,
};

/// Predictions in flight are bounded by the round trip times how fast
/// anyone types, so a fixed queue avoids allocating on the key path. If
/// it ever fills, that itself is evidence the far end is not keeping up,
/// and the right response is to stop predicting rather than to grow.
pub const capacity = 32;

/// A key that is not a plain character, and so cannot be predicted.
pub const Interruption = enum {
    /// Edits the line in place: backspace, delete, the arrow keys. What is
    /// in flight can no longer be placed, but whatever is reading the keys
    /// is the same thing that was echoing a moment ago.
    edit,

    /// May hand the keys to something else entirely: return, tab, escape,
    /// a control or alt chord. The next prompt could be a password prompt,
    /// so trust has to be shown again before anything typed there is drawn.
    boundary,
};

pub const Engine = struct {
    config: Config = .{},

    epoch: Epoch = .observing,

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// Consecutive confirmations while observing.
    hits: u8 = 0,

    /// Whether anything typed since the last `boundary` has come back.
    /// This is mosh's epoch: a run of typing is drawn only once the far
    /// end has echoed part of that same run, so the first character after
    /// return waits one round trip and everything after it is immediate.
    /// That is what keeps a password typed at a fresh prompt off the
    /// screen, even mid-session with trust long established.
    run_trusted: bool = false,

    /// Smoothed round trip and its mean deviation, in seconds, measured
    /// from keypress to confirmed echo. Null until the first echo.
    srtt: ?f32 = null,
    rttvar: f32 = 0,

    /// Drop everything in flight. Rather than work out which predictions
    /// survive a cursor move or an erase, none of them do.
    pub fn flush(self: *Engine) void {
        self.len = 0;
    }

    /// A key that types no character was pressed.
    pub fn interrupt(self: *Engine, kind: Interruption) void {
        self.flush();
        if (kind == .boundary) self.run_trusted = false;
    }

    /// Give up on predicting and drop what is in flight, but keep watching.
    fn demote(self: *Engine, to: Epoch) void {
        self.flush();
        self.hits = 0;
        self.run_trusted = false;
        self.epoch = to;
    }

    /// How long the oldest prediction may wait for its echo: the smoothed
    /// round trip plus four deviations, as TCP's retransmit timer has it,
    /// plus a little for the far end's own processing.
    pub fn timeout(self: *const Engine) f32 {
        const srtt = self.srtt orelse
            return @max(self.config.timeout, @min(0.5, self.config.max_timeout));
        const t = srtt + 4 * self.rttvar + 0.03;
        return @max(self.config.timeout, @min(self.config.max_timeout, t));
    }

    /// Whether predictions are drawn right now.
    pub fn drawing(self: *const Engine) bool {
        // Silence is the password guard, and nothing overrides it.
        if (self.epoch == .silent) return false;

        // Eager mode skips earning trust, both the session's and the run's.
        if (self.config.eager) return true;

        return self.epoch == .predicting and self.run_trusted;
    }

    /// A character was typed. Returns true if it is drawn at once.
    ///
    /// `x`/`y` are where the cursor is now, `cols` the width of the screen.
    /// Callers must filter to plain printable characters first: control
    /// characters, escapes and editing keys arrive as an `interrupt`.
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

        // The terminal has not seen anything still in flight, so its
        // cursor is still where the first of them goes. Each one after
        // that lands one cell further on.
        var at_x = x;
        var at_y = y;
        if (self.len > 0) {
            const last = self.entries[self.len - 1];
            at_x = last.x +| 1;
            at_y = last.y;
        }

        // Near the margin the next character's position depends on the
        // far end's wrap behaviour, so stop before guessing wrong. This
        // only declines to *draw*: the entry is still tracked, so the
        // echo still confirms.
        const room = cols -| self.config.margin;
        self.entries[self.len] = .{
            .cp = cp,
            .x = at_x,
            .y = at_y,
            .at = now,
            .drawable = at_x < room,
        };
        self.len += 1;

        return self.drawing() and at_x < room;
    }

    /// A printable codepoint arrived from the far end.
    /// Reconcile against a character the far end actually printed, and
    /// where it printed it.
    ///
    /// Matching on position rather than on order is the whole point. A
    /// full-screen program does not echo: it repaints, walking the cursor
    /// all over the screen on its way to the cell it is updating. Matching
    /// a queue against the byte stream in order meant every one of those
    /// moves looked like a surprise, so predictions were abandoned before
    /// the echo could arrive and the engine never earned the right to draw
    /// anything at all. A cell, on the other hand, either ends up holding
    /// what we said it would or it does not.
    ///
    /// Measured against a real Claude Code session: typing one character
    /// comes back as
    ///
    ///     ESC[?25l ESC[7D ESC[3B CR ESC[7C ESC[3A x CRLF CRLF CRLF ...
    ///
    /// Six cursor moves before the character, and the character lands on
    /// exactly the cell the cursor was on when it was typed.
    pub fn printed(self: *Engine, cp: u21, x: u16, y: u16, now: f32) Outcome {
        if (self.len == 0) return .ignored;

        // Everything written to a cell we never claimed is the program
        // going about its business, and says nothing either way.
        const hit: usize = for (self.entries[0..self.len], 0..) |e, i| {
            if (e.x == x and e.y == y) break i;
        } else return .ignored;

        if (self.entries[hit].cp != cp) {
            // A cell we claimed came back holding something else, so what
            // is on screen cannot be trusted.
            self.demote(.observing);
            return .mismatch;
        }

        self.sample(now - self.entries[hit].at);

        // Confirmed. Anything predicted before it has been overtaken: the
        // far end has reached this cell, so the cells before it are
        // settled whether or not we watched each one land.
        const drop = hit + 1;
        self.len -= drop;
        for (0..self.len) |i| self.entries[i] = self.entries[i + drop];

        // Echo works for this run of typing, so whatever is still in
        // flight from it can be drawn, and so can what comes after.
        self.run_trusted = true;

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

    /// Fold one measured round trip into the estimate (RFC 6298).
    fn sample(self: *Engine, rtt_: f32) void {
        const rtt = @max(0, rtt_);
        if (self.srtt) |srtt| {
            self.rttvar = 0.75 * self.rttvar + 0.25 * @abs(srtt - rtt);
            self.srtt = 0.875 * srtt + 0.125 * rtt;
        } else {
            self.srtt = rtt;
            self.rttvar = rtt / 2;
        }
    }

    /// Called each frame. Abandons anything that has waited too long.
    pub fn tick(self: *Engine, now: f32) void {
        if (self.len == 0) return;
        if (now - self.entries[0].at < self.timeout()) return;

        if (self.run_trusted and self.epoch == .predicting) {
            // This run was echoing a moment ago, so this is not a password
            // prompt: the character landed somewhere we did not expect, a
            // wrap or a redraw. Take back what was drawn, and draw again
            // as soon as one echo shows we know where things land.
            self.flush();
            self.run_trusted = false;
            return;
        }

        // Typed and never answered: what a password prompt looks like
        // from here.
        self.demote(.silent);
    }

    /// The characters currently drawn ahead of the far end, oldest first.
    /// This is exactly what the renderer should be showing.
    pub fn drawn(self: *const Engine, buf: *[capacity]Entry) []const Entry {
        if (!self.drawing()) return buf[0..0];
        var n: usize = 0;
        for (self.entries[0..self.len]) |e| {
            if (!e.drawable) continue;
            buf[n] = e;
            n += 1;
        }
        return buf[0..n];
    }

    /// Whether anything is on screen that the far end has not confirmed.
    pub fn hasDrawn(self: *const Engine) bool {
        if (!self.drawing()) return false;
        for (self.entries[0..self.len]) |e| if (e.drawable) return true;
        return false;
    }
};

/// Whether a keypress is one whose effect on the screen we can place, and
/// if so which character it puts there. Null means it is not: the caller
/// should abandon what is in flight rather than guess past it.
///
/// This lives here, apart from the key event types, so that the decision
/// can be tested directly. It is the decision that matters most: getting
/// it wrong is what would draw a character that never arrives, or worse,
/// draw one at a prompt that is not echoing.
pub fn classify(
    utf8: []const u8,
    release: bool,
    ctrl: bool,
    alt: bool,
    super: bool,
) ?u21 {
    // A release puts nothing on screen.
    if (release) return null;

    // These turn the key into a command rather than a character. Shift is
    // deliberately absent: that is just capitals.
    if (ctrl or alt or super) return null;

    // Keys that produce no text — arrows, function keys, escape.
    if (utf8.len == 0) return null;

    // Exactly one codepoint, or we cannot say what lands where.
    const seq = std.unicode.utf8ByteSequenceLength(utf8[0]) catch return null;
    if (seq != utf8.len) return null;

    const cp = std.unicode.utf8Decode(utf8) catch return null;

    // Control characters and delete each move the cursor their own way:
    // return, tab, backspace. None of them simply occupy the next cell.
    if (cp < 0x20 or cp == 0x7f) return null;

    return cp;
}

/// Drive `e` to the predicting epoch the honest way, by echoing back what
/// it is told. Leaves the current run trusted, as typing would.
fn warmUp(e: *Engine, now: f32) void {
    var i: usize = 0;
    while (i < e.config.confirm_threshold) : (i += 1) {
        _ = e.typed('a', 0, 0, 80, now);
        _ = e.printed('a', 0, 0, now + 0.05);
    }
}

test "classify accepts a plain character" {
    try std.testing.expectEqual(@as(?u21, 'a'), classify("a", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, 'A'), classify("A", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, ' '), classify(" ", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, '/'), classify("/", false, false, false, false));

    // Non-ASCII is still a character that occupies the next cell.
    try std.testing.expectEqual(@as(?u21, 'ç'), classify("ç", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, 'ã'), classify("ã", false, false, false, false));
}

test "classify refuses keys that are commands rather than characters" {
    // ctrl-c, alt-f, cmd-v: these do things, they do not type.
    try std.testing.expectEqual(@as(?u21, null), classify("c", false, true, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("f", false, false, true, false));
    try std.testing.expectEqual(@as(?u21, null), classify("v", false, false, false, true));

    // Shift is not one of them.
    try std.testing.expectEqual(@as(?u21, 'A'), classify("A", false, false, false, false));
}

test "classify refuses keys that move the cursor their own way" {
    // Return, tab, backspace, escape, and delete.
    try std.testing.expectEqual(@as(?u21, null), classify("\r", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\n", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\t", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\x08", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\x1b", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\x7f", false, false, false, false));
}

test "classify refuses keys that produce no text at all" {
    // Arrows and function keys arrive with an empty utf8.
    try std.testing.expectEqual(@as(?u21, null), classify("", false, false, false, false));
}

test "classify refuses a release" {
    try std.testing.expectEqual(@as(?u21, null), classify("a", true, false, false, false));
}

test "classify refuses anything that is not exactly one codepoint" {
    // A paste or a dead-key sequence is more than one cell's worth.
    try std.testing.expectEqual(@as(?u21, null), classify("ab", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("hello", false, false, false, false));

    // Truncated or invalid UTF-8 must not decode to something plausible.
    try std.testing.expectEqual(@as(?u21, null), classify("\xc3", false, false, false, false));
    try std.testing.expectEqual(@as(?u21, null), classify("\xff", false, false, false, false));
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

test "characters typed ahead of their echo land in successive cells" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // The cursor has not moved for any of these: the terminal has seen
    // none of them yet. They still go one after another.
    try std.testing.expect(e.typed('h', 10, 3, 80, 1.0));
    try std.testing.expect(e.typed('i', 10, 3, 80, 1.01));
    try std.testing.expect(e.typed('!', 10, 3, 80, 1.02));

    var buf: [capacity]Entry = undefined;
    const d = e.drawn(&buf);
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqual(@as(u16, 10), d[0].x);
    try std.testing.expectEqual(@as(u16, 11), d[1].x);
    try std.testing.expectEqual(@as(u16, 12), d[2].x);

    // And each echo, landing where it should, confirms its own entry.
    try std.testing.expectEqual(Outcome.confirmed, e.printed('h', 10, 3, 1.05));
    try std.testing.expectEqual(Outcome.confirmed, e.printed('i', 11, 3, 1.06));
    try std.testing.expectEqual(Outcome.confirmed, e.printed('!', 12, 3, 1.07));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
}

test "a repeated character typed ahead is not mistaken for its neighbour" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // "aa": the second used to be recorded on the first one's cell, so
    // the first echo confirmed it and the second echo matched nothing,
    // leaving a ghost 'a' to time out and switch prediction off.
    _ = e.typed('a', 4, 1, 80, 1.0);
    _ = e.typed('a', 4, 1, 80, 1.01);
    try std.testing.expectEqual(Outcome.confirmed, e.printed('a', 4, 1, 1.05));
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expectEqual(Outcome.confirmed, e.printed('a', 5, 1, 1.06));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "a confirmed prediction leaves the queue" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    try std.testing.expectEqual(Outcome.confirmed, e.printed('x', 5, 2, 0.05));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expect(!e.hasDrawn());
}

test "a mismatch drops everything and stops predicting" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    _ = e.typed('y', 5, 2, 80, 0);

    // The far end sent something else entirely.
    try std.testing.expectEqual(Outcome.mismatch, e.printed('z', 5, 2, 0.05));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expectEqual(Epoch.observing, e.epoch);
}

test "after return, nothing is drawn until that prompt has echoed" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Return may land at any prompt, a password prompt included. Trust in
    // the session is not trust in whatever is now reading the keys.
    e.interrupt(.boundary);
    try std.testing.expect(!e.typed('h', 0, 5, 80, 1.0));
    try std.testing.expect(!e.typed('u', 0, 5, 80, 1.01));
    try std.testing.expect(!e.hasDrawn());

    // The first echo shows this prompt echoes: what is still in flight
    // appears, and typing from here on is drawn at once.
    try std.testing.expectEqual(Outcome.confirmed, e.printed('h', 0, 5, 1.05));
    try std.testing.expect(e.hasDrawn());
    try std.testing.expect(e.typed('n', 0, 5, 80, 1.06));
}

test "a password typed after return never reaches the screen" {
    var e: Engine = .{};
    warmUp(&e, 0);

    e.interrupt(.boundary);
    var t: f32 = 1.0;
    for ("hunter2") |c| {
        try std.testing.expect(!e.typed(c, 10, 5, 80, t));
        try std.testing.expect(!e.hasDrawn());
        e.tick(t);
        t += 0.12;
    }
    e.tick(t + 1);
    try std.testing.expectEqual(Epoch.silent, e.epoch);
    try std.testing.expect(!e.hasDrawn());

    // Still nothing while the prompt stays silent.
    try std.testing.expect(!e.typed('x', 10, 5, 80, t + 2));
}

test "an edit key keeps the run trusted" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 5, 2, 80, 0);
    e.interrupt(.edit);
    try std.testing.expect(!e.hasDrawn());
    try std.testing.expectEqual(@as(usize, 0), e.len);

    // Backspace did not change what is reading the keys.
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
    try std.testing.expect(e.typed('y', 5, 2, 80, 0.1));
}

test "a late echo on a trusted run is not a password prompt" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // A Wi-Fi stall holds one echo far past the timeout.
    try std.testing.expect(e.typed('s', 3, 1, 80, 1.0));
    e.tick(1.0 + e.timeout() + 0.01);

    // What was drawn is taken back, but the session stays predicting,
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
    try std.testing.expect(!e.hasDrawn());

    // and one echo is all it takes to draw again.
    _ = e.typed('t', 3, 1, 80, 2.0);
    try std.testing.expect(!e.hasDrawn());
    try std.testing.expectEqual(Outcome.confirmed, e.printed('t', 3, 1, 2.05));
    try std.testing.expect(e.typed('u', 4, 1, 80, 2.06));
}

test "the timeout follows the measured round trip" {
    var e: Engine = .{};

    // A slow but steady link: 180ms every time. The fixed 150ms timeout
    // this replaces would have called every one of these a password.
    var t: f32 = 0;
    var i: u16 = 0;
    while (i < 20) : (i += 1) {
        _ = e.typed('a', i, 0, 80, t);
        e.tick(t + 0.17);
        try std.testing.expectEqual(Outcome.confirmed, e.printed('a', i, 0, t + 0.18));
        t += 0.3;
    }
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
    try std.testing.expect(e.timeout() > 0.2);

    // And it never grows past the cap, however bad things get.
    e.srtt = 5;
    try std.testing.expect(e.timeout() <= e.config.max_timeout);

    // Nor shrinks under the floor on a fast link.
    e.srtt = 0.001;
    e.rttvar = 0;
    try std.testing.expect(e.timeout() >= e.config.timeout);
}

test "nothing is drawn near the right margin" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Two cells from the edge, where a wrap would land the character
    // somewhere we cannot predict.
    try std.testing.expect(!e.typed('x', 78, 0, 80, 0));
    e.flush();
    try std.testing.expect(!e.typed('x', 79, 0, 80, 0));
    e.flush();

    // Comfortably inside, it is drawn as usual.
    try std.testing.expect(e.typed('x', 40, 0, 80, 0));
}

test "typing ahead stops drawing at the margin" {
    var e: Engine = .{};
    warmUp(&e, 0);

    try std.testing.expect(e.typed('a', 77, 0, 80, 0));
    try std.testing.expect(!e.typed('b', 77, 0, 80, 0)); // lands on 78
    var buf: [capacity]Entry = undefined;
    try std.testing.expectEqual(@as(usize, 1), e.drawn(&buf).len);
}

test "an untracked margin character still confirms" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Undrawn because of the margin, but still expected back, so echo
    // accounting does not desynchronise across a wrap.
    try std.testing.expect(!e.typed('x', 79, 0, 80, 0));
    try std.testing.expectEqual(Outcome.confirmed, e.printed('x', 79, 0, 0.05));
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
    try std.testing.expectEqual(Outcome.ignored, e.printed('q', 40, 10, 0));
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
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
    e.tick(1.0 + e.timeout() + 0.01);
    try std.testing.expectEqual(Epoch.silent, e.epoch);

    // Eagerness does not override silence. This is the guard that keeps
    // passwords off the screen and it outranks every other setting.
    try std.testing.expect(!e.typed('e', 0, 0, 80, 3.0));
    try std.testing.expect(!e.hasDrawn());
}

test "timeout does not fire while echoes keep arriving" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('a', 0, 0, 80, 1.0);
    _ = e.printed('a', 0, 0, 1.05);
    _ = e.typed('b', 1, 0, 80, 1.1);

    // The queue's oldest entry is recent even though the session is old.
    e.tick(1.15);
    try std.testing.expectEqual(Epoch.predicting, e.epoch);
    try std.testing.expect(e.hasDrawn());
}

test "a repaint writing other cells leaves a prediction standing" {
    var e: Engine = .{};
    warmUp(&e, 0);

    // Typed into a full-screen program's input box at column 7.
    try std.testing.expect(e.typed('x', 7, 5, 80, 0));

    // The program repaints its box on the way there, touching cells that
    // have nothing to do with us.
    try std.testing.expectEqual(Outcome.ignored, e.printed('h', 2, 5, 0.01));
    try std.testing.expectEqual(Outcome.ignored, e.printed('e', 3, 5, 0.01));
    try std.testing.expectEqual(Outcome.ignored, e.printed('>', 0, 5, 0.01));
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expect(e.hasDrawn());
    try std.testing.expectEqual(Epoch.predicting, e.epoch);

    // And then the character lands where we said it would.
    try std.testing.expectEqual(Outcome.confirmed, e.printed('x', 7, 5, 0.05));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "a later cell confirming settles the ones before it" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('a', 7, 5, 80, 0);
    _ = e.typed('b', 7, 5, 80, 0);

    // A repaint redraws the line in one go, so only the last cell is seen
    // arriving. Reaching cell 8 means cell 7 is settled too.
    try std.testing.expectEqual(Outcome.confirmed, e.printed('b', 8, 5, 0.05));
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "a cell we claimed coming back wrong is still a mismatch" {
    var e: Engine = .{};
    warmUp(&e, 0);

    _ = e.typed('x', 7, 5, 80, 0);

    // Position matching must not weaken this: a wrong character in a cell
    // we drew into is exactly the case worth catching.
    try std.testing.expectEqual(Outcome.mismatch, e.printed('z', 7, 5, 0.05));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expectEqual(Epoch.observing, e.epoch);
}

/// A small deterministic PRNG, so the link simulation below is the same
/// on every run.
const Lcg = struct {
    s: u64,
    fn next(self: *Lcg) f32 {
        self.s = self.s *% 6364136223846793005 +% 1442695040888963407;
        return @as(f32, @floatFromInt(self.s >> 40)) / @as(f32, 1 << 24);
    }
};

test "typing over a jittery link is drawn at once" {
    // The link this was written against: Wi-Fi to a VPS, measured at
    // 24-120ms with the odd 200ms stall. Type a few sentences at a brisk
    // 12 characters a second, with echoes arriving out of step with the
    // keys, and count how many keystrokes appeared the instant they were
    // pressed. Under the old engine this was close to none: typing faster
    // than the round trip put every second character on the wrong cell,
    // and the first stall shut prediction off.
    var e: Engine = .{};
    var rng: Lcg = .{ .s = 42 };

    const Pending = struct { cp: u21, x: u16, at: f32 };
    var inflight: [256]Pending = undefined;
    var n_inflight: usize = 0;

    var cursor: u16 = 2;
    var t: f32 = 0;
    var drawn_now: usize = 0;
    var typed_count: usize = 0;

    var key: usize = 0;
    while (key < 400) : (key += 1) {
        // Deliver every echo that has arrived by now, in order.
        while (n_inflight > 0 and inflight[0].at <= t) {
            const p = inflight[0];
            _ = e.printed(p.cp, p.x, 0, p.at);
            cursor = p.x + 1;
            for (0..n_inflight - 1) |i| inflight[i] = inflight[i + 1];
            n_inflight -= 1;
        }
        e.tick(t);

        // Wrap to a fresh line well before the margin, as an editor's
        // input box would, with a return to begin the next sentence.
        if (cursor > 60 and n_inflight == 0) {
            e.interrupt(.boundary);
            cursor = 2;
        }

        const cp: u21 = 'a' + @as(u21, @intCast(key % 26));
        const rtt: f32 = if (rng.next() < 0.03)
            0.2
        else
            0.024 + rng.next() * 0.1;

        // Echo travels in order: one cannot overtake the one before it.
        var arrive = t + rtt;
        if (n_inflight > 0) arrive = @max(arrive, inflight[n_inflight - 1].at);
        const x = if (n_inflight > 0) inflight[n_inflight - 1].x + 1 else cursor;

        if (e.typed(cp, cursor, 0, 80, t)) drawn_now += 1;
        typed_count += 1;
        inflight[n_inflight] = .{ .cp = cp, .x = x, .at = arrive };
        n_inflight += 1;

        t += 0.06 + rng.next() * 0.05;
    }

    const ratio = @as(f32, @floatFromInt(drawn_now)) /
        @as(f32, @floatFromInt(typed_count));
    try std.testing.expect(ratio > 0.9);
    try std.testing.expect(e.epoch != .silent);
}
