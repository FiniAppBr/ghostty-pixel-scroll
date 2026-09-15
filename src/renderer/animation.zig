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
