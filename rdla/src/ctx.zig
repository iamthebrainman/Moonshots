//! ctx.zig - deterministic token vectors and total-context accumulation.
//! A unit's left bundle is the sum over every occurrence of (neighbour vector XOR position role),
//! for neighbours before it; the right bundle likewise for neighbours after it. Counters are
//! plain i32 sums, so the result is a pure function of the tape: independent of shard layout.
const std = @import("std");

pub const WORDS = 8;
pub const D = WORDS * 64;
pub const Vec = [WORDS]u64;

fn mix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn seedVec(h: u64) Vec {
    var v: Vec = undefined;
    var s = h;
    for (&v) |*w| {
        s = mix(s);
        w.* = s;
    }
    return v;
}

pub fn role(offset: i32) Vec {
    return seedVec(0x524F4C45_00000000 +% @as(u64, @bitCast(@as(i64, offset))));
}

pub const GLOSS_ROLE: u64 = 0x474C4F53_53000001;

pub fn bind(a: Vec, b: Vec) Vec {
    var r: Vec = undefined;
    for (&r, a, b) |*x, p, q| x.* = p ^ q;
    return r;
}

pub const Acc = struct {
    alloc: std.mem.Allocator,
    keys: []u64, // 0 = empty
    count: []u32,
    left: []i32,
    right: []i32,
    mask: usize,
    used: usize = 0,
    map: ?[]align(std.heap.page_size_min) u8 = null, // set when the arrays live in a mapped file (store.zig)

    pub fn init(alloc: std.mem.Allocator, cap_pow2: u6) !Acc {
        const cap: usize = @as(usize, 1) << cap_pow2;
        const keys = try alloc.alloc(u64, cap);
        @memset(keys, 0);
        const count = try alloc.alloc(u32, cap);
        @memset(count, 0);
        const left = try alloc.alloc(i32, cap * D);
        @memset(left, 0);
        const right = try alloc.alloc(i32, cap * D);
        @memset(right, 0);
        return .{ .alloc = alloc, .keys = keys, .count = count, .left = left, .right = right, .mask = cap - 1 };
    }

    pub fn deinit(self: *Acc) void {
        if (self.map) |m| return std.posix.munmap(m);
        self.alloc.free(self.keys);
        self.alloc.free(self.count);
        self.alloc.free(self.left);
        self.alloc.free(self.right);
    }

    pub fn slot(self: *Acc, h: u64) !usize {
        var i: usize = @intCast(mix(h) & self.mask);
        while (true) : (i = (i + 1) & self.mask) {
            if (self.keys[i] == h) return i;
            if (self.keys[i] == 0) {
                if (self.used * 4 >= (self.mask + 1) * 3) return error.TableFull;
                self.keys[i] = h;
                self.used += 1;
                return i;
            }
        }
    }

    pub fn find(self: *const Acc, h: u64) ?usize {
        var i: usize = @intCast(mix(h) & self.mask);
        while (true) : (i = (i + 1) & self.mask) {
            if (self.keys[i] == h) return i;
            if (self.keys[i] == 0) return null;
        }
    }

    fn addVec(dst: []i32, v: Vec, times: i32) void {
        for (v, 0..) |w, wi| {
            const base = wi * 64;
            var b: usize = 0;
            while (b < 64) : (b += 1) {
                dst[base + b] += if ((w >> @intCast(b)) & 1 == 1) times else -times;
            }
        }
    }

    /// Accumulates the windows of every centre position in [lo, hi) of the global unit sequence.
    pub fn centers(self: *Acc, units: []const u64, lo: usize, hi: usize, window: usize) !void {
        var p = lo;
        while (p < hi) : (p += 1) {
            const s = try self.slot(units[p]);
            self.count[s] += 1;
            var o: usize = 1;
            while (o <= window) : (o += 1) {
                if (p >= o) addVec(self.left[s * D ..][0..D], bind(seedVec(units[p - o]), role(@as(i32, @intCast(o)))), 1);
                if (p + o < units.len) addVec(self.right[s * D ..][0..D], bind(seedVec(units[p + o]), role(@as(i32, @intCast(o)))), 1);
            }
        }
    }

    /// Adds a taught gloss to a unit as `times` attestations, bound to the gloss role.
    pub fn gloss(self: *Acc, unit: u64, tokens: []const u64, times: i32) !void {
        const s = try self.slot(unit);
        const r = seedVec(GLOSS_ROLE);
        for (tokens) |t| {
            _ = try self.slot(t); // gloss words must exist as units so they can be read back
            addVec(self.right[s * D ..][0..D], bind(seedVec(t), r), times);
        }
    }

    /// Like `gloss`, but sizes the attestation count so the gloss stands ~6 standard deviations above the
    /// leakage noise of the unit's existing right-context bundle (never below `floor`). A pure function of
    /// the tape and the idiom list.
    pub fn glossAuto(self: *Acc, unit: u64, tokens: []const u64, floor: i32) !void {
        const s = try self.slot(unit);
        var ss: f64 = 0;
        for (self.right[s * D ..][0..D]) |x| ss += @as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(x));
        const need: i32 = @intFromFloat(@ceil(6.0 * @sqrt(ss) / @as(f64, D)));
        try self.gloss(unit, tokens, @max(floor, need));
    }

    pub fn merge(self: *Acc, other: *const Acc) !void {
        for (other.keys, 0..) |k, i| {
            if (k == 0) continue;
            const s = try self.slot(k);
            self.count[s] += other.count[i];
            for (0..D) |d| {
                self.left[s * D + d] += other.left[i * D + d];
                self.right[s * D + d] += other.right[i * D + d];
            }
        }
    }

    pub fn eql(self: *const Acc, other: *const Acc) bool {
        if (self.used != other.used) return false;
        for (self.keys, 0..) |k, i| {
            if (k == 0) continue;
            const j = other.find(k) orelse return false;
            if (self.count[i] != other.count[j]) return false;
            if (!std.mem.eql(i32, self.left[i * D ..][0..D], other.left[j * D ..][0..D])) return false;
            if (!std.mem.eql(i32, self.right[i * D ..][0..D], other.right[j * D ..][0..D])) return false;
        }
        return true;
    }
};

pub fn cosine(a: []const i32, b: []const i32) f64 {
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        dot += fx * fy;
        na += fx * fx;
        nb += fy * fy;
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

test "ctx: shard layout and merge order cannot change the result" {
    const a = std.testing.allocator;
    var units: [400]u64 = undefined;
    var s: u64 = 7;
    for (&units) |*u| {
        s = mix(s);
        u.* = 1 + s % 23;
    }
    var whole = try Acc.init(a, 6);
    defer whole.deinit();
    try whole.centers(&units, 0, units.len, 4);

    var parts: [3]Acc = undefined;
    const cuts = [_]usize{ 0, 97, 300, 400 };
    for (&parts, 0..) |*p, i| {
        p.* = try Acc.init(a, 6);
        try p.centers(&units, cuts[i], cuts[i + 1], 4);
    }
    defer for (&parts) |*p| p.deinit();

    var m1 = try Acc.init(a, 6);
    defer m1.deinit();
    for (&parts) |*p| try m1.merge(p);
    var m2 = try Acc.init(a, 6);
    defer m2.deinit();
    try m2.merge(&parts[2]);
    try m2.merge(&parts[0]);
    try m2.merge(&parts[1]);
    try std.testing.expect(whole.eql(&m1));
    try std.testing.expect(whole.eql(&m2));
}

test "ctx: operator-like units are asymmetric, content-like are not" {
    const a = std.testing.allocator;
    // unit 1 always followed by 2..4 but preceded by anything; unit 9 appears in mixed contexts
    var units: std.ArrayList(u64) = .empty;
    defer units.deinit(a);
    var s: u64 = 3;
    for (0..300) |_| {
        s = mix(s);
        try units.append(a, 100 + s % 40); // random preceding filler
        try units.append(a, 1);
        try units.append(a, 2 + (mix(s) % 3));
        s = mix(s);
        try units.append(a, 200 + s % 5);
        try units.append(a, 9);
        try units.append(a, 200 + mix(s) % 5);
    }
    var acc = try Acc.init(a, 8);
    defer acc.deinit();
    try acc.centers(units.items, 0, units.items.len, 1);
    const op = acc.find(1).?;
    const ct = acc.find(9).?;
    const asym_op = 1 - cosine(acc.left[op * D ..][0..D], acc.right[op * D ..][0..D]);
    const asym_ct = 1 - cosine(acc.left[ct * D ..][0..D], acc.right[ct * D ..][0..D]);
    try std.testing.expect(asym_op > asym_ct + 0.2);
}

/// Chance-corrected coherence of a bundle built from `n` added unit-vectors: 0 for random noise
/// (E|sum|^2 = n*D), 1 when every addition points the same way.
pub fn coherence(b: []const i32, n: usize) f64 {
    if (n < 2) return 0;
    var ss: f64 = 0;
    for (b) |x| {
        const f: f64 = @floatFromInt(x);
        ss += f * f;
    }
    const nf: f64 = @floatFromInt(n);
    return (ss / (nf * @as(f64, @floatFromInt(D))) - 1) / (nf - 1);
}

test "ctx: coherence is ~0 for noise and ~1 for a repeated vector" {
    const a = std.testing.allocator;
    var acc = try Acc.init(a, 4);
    defer acc.deinit();
    const s = try acc.slot(5);
    var i: u64 = 0;
    while (i < 200) : (i += 1) Acc.addVec(acc.left[s * D ..][0..D], seedVec(1000 + i), 1);
    while (i < 400) : (i += 1) Acc.addVec(acc.right[s * D ..][0..D], seedVec(77), 1);
    try std.testing.expect(@abs(coherence(acc.left[s * D ..][0..D], 200)) < 0.02);
    try std.testing.expect(coherence(acc.right[s * D ..][0..D], 200) > 0.99);
}
