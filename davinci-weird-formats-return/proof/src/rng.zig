//! rng.zig - SplitMix64, written out in full.
//!
//! The tests need reproducible pseudo-randomness. std.Random's algorithm and
//! import path have both changed between Zig releases, and the determinism
//! claims in PROPOSAL.txt must not depend on a standard-library detail, so the
//! generator is defined here. Output is a pure function of the 64-bit seed.

const std = @import("std");

pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform-ish value in [0, n). Modulo bias is irrelevant for test data.
    pub fn below(self: *SplitMix64, n: u64) u64 {
        std.debug.assert(n != 0);
        return self.next() % n;
    }

    /// Fisher-Yates shuffle of a slice.
    pub fn shuffle(self: *SplitMix64, comptime T: type, items: []T) void {
        var i: usize = items.len;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(self.below(i + 1));
            const tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }
};

test "SplitMix64 reference vector (seed 0)" {
    // First outputs of the published SplitMix64 reference implementation.
    var g = SplitMix64.init(0);
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), g.next());
    try std.testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), g.next());
    try std.testing.expectEqual(@as(u64, 0x06C45D188009454F), g.next());
}
