//! Animation primitives for smooth cursor and scroll motion.
//!
//! A critically damped spring, which is what makes this motion read as
//! motion rather than as lag: it carries velocity, so it eases in and out,
//! and a new target part-way through blends with the movement already in
//! flight instead of restarting it.
//!
//! The model follows Neovide's, by way of the ghostty-pixel-scroll fork
//! (github.com/parkers0405/ghostty-pixel-scroll), which is where this
//! feature's feel comes from.

const std = @import("std");

/// A damped spring travelling towards rest.
///
/// `position` is the distance still to travel, so zero is "arrived". Give
/// it ground to cover with `add`, then `update` each frame.
pub const Spring = struct {
    /// Distance still to travel. Zero means at rest.
    position: f32 = 0,

    /// Current velocity, in units per second.
    velocity: f32 = 0,

    /// Advance the spring by `dt` seconds. `length` is roughly how long a
    /// move takes to settle, and `zeta` is the damping ratio: 1 is
    /// critically damped (no overshoot, the fastest settle without it),
    /// below 1 overshoots and springs back.
    ///
    /// Returns true while still moving.
    pub fn update(self: *Spring, dt: f32, length: f32, zeta: f32) bool {
        // A move shorter than a frame has already happened.
        if (length <= dt) {
            self.reset();
            return false;
        }

        if (self.position == 0) return false;

        // Chosen so the spring arrives within ~2% over `length`.
        const omega = 4.0 / (zeta * length);

        // Analytical solution for a critically damped harmonic oscillator,
        // with the current position and velocity as initial conditions.
        const a = self.position;
        const b = self.position * omega + self.velocity;
        const c = @exp(-omega * dt);

        self.position = (a + b * dt) * c;
        self.velocity = c * (-a * omega - b * dt * omega + b);

        // Close enough to home that another frame would not show.
        if (@abs(self.position) < 0.01) {
            self.reset();
            return false;
        }

        return true;
    }

    /// Give the spring more ground to cover, keeping the velocity it
    /// already has. This is what lets a second scroll part-way through the
    /// first blend with it rather than restart it.
    pub fn add(self: *Spring, delta: f32) void {
        self.position += delta;
    }

    /// Stop dead at rest.
    pub fn reset(self: *Spring) void {
        self.position = 0;
        self.velocity = 0;
    }

    /// Whether the spring is still travelling.
    pub fn active(self: *const Spring) bool {
        return self.position != 0;
    }
};

test "spring settles" {
    var s: Spring = .{};
    s.add(100);
    try std.testing.expect(s.active());

    // 0.3s of animation at 120Hz should be home, or near enough.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (!s.update(1.0 / 120.0, 0.3, 1.0)) break;
    }
    try std.testing.expect(!s.active());
}

test "critically damped spring does not overshoot" {
    var s: Spring = .{};
    s.add(100);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = s.update(1.0 / 120.0, 0.3, 1.0);
        // Never crosses zero: no overshoot when critically damped.
        try std.testing.expect(s.position >= -0.01);
    }
}

test "a new target blends with movement in flight" {
    var s: Spring = .{};
    s.add(100);
    _ = s.update(1.0 / 120.0, 0.3, 1.0);
    const v_before = s.velocity;
    s.add(100);
    // Velocity survives the new target rather than resetting.
    try std.testing.expectEqual(v_before, s.velocity);
}

/// A cursor that stretches as it travels.
///
/// The cursor is a quad, and each of its four corners is sprung
/// separately. The corners facing the way it is going arrive first, near
/// enough to instantly, and the ones behind hold back, so the quad smears
/// out of the cell it was in and gathers itself back into the cell it
/// lands on. That stretch is the whole effect; a cursor that slides
/// rigidly reads as a cursor that is late.
///
/// Positions here are offsets from where the cursor has already been
/// placed, in pixels, so zero is "arrived" and a renderer can add them to
/// the corners of the quad it would have drawn anyway.
pub const CornerCursor = struct {
    /// Where each corner sits relative to the cursor's centre, in units of
    /// the cursor's own size. Order: top-left, top-right, bottom-right,
    /// bottom-left.
    const relative: [4][2]f32 = .{
        .{ -0.5, -0.5 },
        .{ 0.5, -0.5 },
        .{ 0.5, 0.5 },
        .{ -0.5, 0.5 },
    };

    /// How long a move takes at the default setting. The configured
    /// duration scales the lengths below relative to this.
    const default_length: f32 = 0.10;

    /// A cell or two along the same row is typing, not travelling, and
    /// wants to be over with sooner.
    const typing_length: f32 = 0.04;

    /// How much of the animation the trailing corners hold back for. This
    /// is the stretch: at 0 every corner moves together and the cursor
    /// slides rigidly.
    const trail: f32 = 0.8;

    const Corner = struct {
        x: Spring = .{},
        y: Spring = .{},

        /// How long this corner has to arrive, set per move from its rank.
        length: f32 = default_length,
    };

    corners: [4]Corner = @splat(.{}),

    /// Carry the cursor `cells_x`, `cells_y` cells — positive is right and
    /// down — in one piece, every corner travelling together over
    /// `duration`.
    ///
    /// This is for a cursor that the grid moved rather than one that moved
    /// itself: scrolling slides the cursor along with the text it sits on,
    /// and text does not stretch. Pass the duration the grid is scrolling
    /// over, so the two keep step.
    pub fn follow(
        self: *CornerCursor,
        cells_x: f32,
        cells_y: f32,
        cell_width: f32,
        cell_height: f32,
        duration: f32,
    ) void {
        if (duration <= 0) {
            self.reset();
            return;
        }

        // Offsets are measured from where the cursor is going, so a move
        // to the right leaves the corners sitting to the left of it.
        for (&self.corners) |*c| {
            c.x.add(-cells_x * cell_width);
            c.y.add(-cells_y * cell_height);
            c.length = duration;
        }
    }

    /// Move the cursor by `cells_x`, `cells_y` cells — positive is right
    /// and down — ranking the corners by how much each one faces the
    /// direction of travel.
    pub fn move(
        self: *CornerCursor,
        cells_x: f32,
        cells_y: f32,
        cell_width: f32,
        cell_height: f32,
        duration: f32,
    ) void {
        if (duration <= 0) {
            self.reset();
            return;
        }

        // Every corner has the same ground to cover; they differ in how
        // long they are given to cover it.
        for (&self.corners) |*c| {
            c.x.add(-cells_x * cell_width);
            c.y.add(-cells_y * cell_height);
        }

        // The way home is the offset negated — which is the direction of
        // travel, in-flight movement and all — and a corner leads if it
        // points that way.
        var alignment: [4]f32 = undefined;
        for (&self.corners, 0..) |*c, i| {
            alignment[i] = dot(
                normalize(.{ -c.x.position, -c.y.position }),
                normalize(relative[i]),
            );
        }

        const base = scale: {
            const typing = @abs(cells_x) <= 2.001 and @abs(cells_y) < 0.001;
            const length = if (typing)
                @min(default_length, typing_length)
            else
                default_length;
            break :scale length * (duration / default_length);
        };
        const leading = base * (1.0 - trail);
        const trailing = base;

        for (&self.corners, 0..) |*c, i| {
            // Rank by alignment, ties going to the earlier corner so that
            // a straight move up, down or sideways — where two corners
            // face the same way — still picks one of each.
            var rank: usize = 0;
            for (alignment, 0..) |a, j| {
                if (j == i) continue;
                if (a < alignment[i] or (a == alignment[i] and j < i)) rank += 1;
            }

            c.length = switch (rank) {
                0 => trailing,
                1 => (leading + trailing) / 2.0,
                else => leading,
            };
        }
    }

    /// Advance every corner by `dt` seconds. Returns true while any of
    /// them is still travelling.
    pub fn update(self: *CornerCursor, dt: f32, zeta: f32) bool {
        if (dt <= 0) return self.active();

        var moving = false;
        for (&self.corners) |*c| {
            if (c.x.update(dt, c.length, zeta)) moving = true;
            if (c.y.update(dt, c.length, zeta)) moving = true;
        }
        return moving;
    }

    /// The offset of each corner from its settled position, in pixels.
    /// Order: top-left, top-right, bottom-right, bottom-left.
    pub fn offsets(self: *const CornerCursor) [4][2]f32 {
        var result: [4][2]f32 = undefined;
        for (&self.corners, 0..) |*c, i| {
            result[i] = .{ c.x.position, c.y.position };
        }
        return result;
    }

    /// Whether any corner is still travelling.
    pub fn active(self: *const CornerCursor) bool {
        for (&self.corners) |*c| {
            if (c.x.active() or c.y.active()) return true;
        }
        return false;
    }

    /// Put every corner back in its cell.
    pub fn reset(self: *CornerCursor) void {
        for (&self.corners) |*c| {
            c.x.reset();
            c.y.reset();
        }
    }

    fn normalize(v: [2]f32) [2]f32 {
        const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
        if (len < 0.001) return .{ 0, 0 };
        return .{ v[0] / len, v[1] / len };
    }

    fn dot(a: [2]f32, b: [2]f32) f32 {
        return a[0] * b[0] + a[1] * b[1];
    }
};

test "a travelling cursor stretches" {
    var c: CornerCursor = .{};

    // A jump to the right: the corners on the right lead.
    c.move(10, 0, 10, 20, 0.1);
    _ = c.update(1.0 / 120.0, 1.0);

    const offsets = c.offsets();
    const trailing = @abs(offsets[0][0]); // top-left
    const leading = @abs(offsets[1][0]); // top-right
    try std.testing.expect(leading < trailing);
}

test "a travelling cursor gathers itself back into a cell" {
    var c: CornerCursor = .{};
    c.move(0, 12, 10, 20, 0.1);

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (!c.update(1.0 / 120.0, 1.0)) break;
    }

    try std.testing.expect(!c.active());
    for (c.offsets()) |o| {
        try std.testing.expectEqual(@as(f32, 0), o[0]);
        try std.testing.expectEqual(@as(f32, 0), o[1]);
    }
}

test "a cursor with animation off does not move" {
    var c: CornerCursor = .{};
    c.move(5, 5, 10, 20, 0);
    try std.testing.expect(!c.active());
}
