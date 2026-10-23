//! exhibit_audit.zig - executable versions of the GAPS.txt entries that can be checked in Zig.
//!
//!   zig test audit/exhibit_audit.zig
//!
//! Each test re-implements the exhibit's arithmetic (file and lines cited) and asserts the
//! number that GAPS.txt reports. The same quantities were first measured by compiling the
//! exhibits' own Rust modules unmodified (rustc 1.97.0); every constant asserted below that is
//! marked (Rust) was produced that way, so a pass here means the Zig port reproduces the
//! exhibit's behaviour, not merely that it agrees with itself.
//!
//! This file is evidence for the gaps ledger. It is not part of the SUNZI mechanism.

const std = @import("std");

fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return x;
}

// ---------------------------------------------------------------------
// A1  Slot layout: table.rs:511-522 (#[repr(C)] pub struct Slot)
// ---------------------------------------------------------------------
const Slot = extern struct {
    kind: u8,
    key_len: u8,
    _reserved: [2]u8,
    key: [16]u8,
    value: u64,
    next_pos: u32,
    score: u16,
    _padding: [6]u8,
};

test "A1: a Slot is 48 bytes (not the 32 of table.rs:13 or the 40 of INVARIANTS/persist.rs)" {
    const field_bytes = 1 + 1 + 2 + 16 + 8 + 4 + 2 + 6;
    try std.testing.expectEqual(@as(usize, 40), field_bytes); // the "40" is the sum of the field widths
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Slot)); // (Rust) size_of::<Slot>() = 48
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Slot));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Slot, "value")); // 4 bytes of padding before the u64
    try std.testing.expectEqual(@as(u64, 768), ((1 << 24) * @as(u64, @sizeOf(Slot))) >> 20); // MiB for 2^24 slots
}

// ---------------------------------------------------------------------
// A2  GOLDEN_STEP: table.rs:23-26 and the live golden_step() at table.rs:710-717
// ---------------------------------------------------------------------
test "A2: GOLDEN_STEP is even (not coprime to 2^24), mis-floored, and unused; the live step is odd" {
    const golden_step: u64 = 10_368_890;
    try std.testing.expectEqual(@as(u64, 2), gcd(golden_step, 1 << 24));
    const exact = @as(f64, 1 << 24) / 1.618033988749895;
    try std.testing.expectEqual(@as(u64, 10_368_889), @as(u64, @intFromFloat(@floor(exact)))); // floor, not 10,368,890
    const live: u64 = ((@as(u64, 1 << 24) * 10_368_890) / (1 << 24)) | 1; // golden_step() at full size
    try std.testing.expectEqual(@as(u64, 10_368_891), live);
    try std.testing.expectEqual(@as(u64, 1), gcd(live, 1 << 24));
}

// ---------------------------------------------------------------------
// A3  Fibonacci ceiling: superposition_decoder.rs:40-60 ("spans roughly 0 -> 1.8 trillion")
// ---------------------------------------------------------------------
test "A3: the 2,3-seeded table reaches 3.25e13, not 1.8e12" {
    var fib: [32]u64 = undefined;
    fib[0] = 2;
    fib[1] = 3;
    for (2..32) |i| fib[i] = fib[i - 1] + fib[i - 2];
    try std.testing.expectEqual(@as(u64, 5_702_887), fib[31]);
    try std.testing.expectEqual(@as(u64, 32_522_920_134_769), fib[31] * fib[31]); // (Rust) same value
    // 1.8e12 is F(31)^2 of the unseeded 1,1 sequence
    var plain: [32]u64 = undefined;
    plain[0] = 1;
    plain[1] = 1;
    for (2..32) |i| plain[i] = plain[i - 1] + plain[i - 2];
    try std.testing.expect(plain[30] * plain[30] > 1_700_000_000_000 and plain[30] * plain[30] < 1_900_000_000_000);
}

// ---------------------------------------------------------------------
// A4  hash_methods.rs: Tribonacci / Original / PhiRatio / SilverRatio address-space usage
// ---------------------------------------------------------------------
const PHI: f64 = 1.6180339887498948482;
const SILVER_C: f64 = 2.4142135623730950488;
const TRIBONACCI_C: f64 = 1.8392867552141612;

fn hashTribonacci(bytes: []const u8, mask: u64) u64 { // hash_methods.rs:417-426
    const sz: f64 = @floatFromInt(mask + 1);
    var acc: f64 = 1.0;
    for (bytes) |b| {
        acc = acc / TRIBONACCI_C + @as(f64, @floatFromInt(b));
        if (acc > sz) acc /= TRIBONACCI_C;
    }
    return @as(u64, @intFromFloat(acc)) & mask;
}

fn carouselSeed(byte: u8) u64 { // hash_methods.rs:333-337
    const char_id: u64 = byte & 0x1F;
    const cart: u64 = (byte >> 5) & 0x07;
    return 2 + char_id + cart * 32;
}

fn hashOriginal(bytes: []const u8, mask: u64) u64 { // hash_methods.rs:340-349
    var acc: u64 = 1;
    for (bytes, 0..) |b, i| {
        const seed = @max(carouselSeed(b), 1);
        if (i % 2 == 0) {
            acc *%= seed;
        } else {
            acc = @max(acc / seed, 1);
        }
    }
    return acc & mask;
}

fn hashRatio(bytes: []const u8, mask: u64, divisor: f64) u64 { // hash_methods.rs:352-357 and 410-415
    const sz: f64 = @floatFromInt(mask + 1);
    var acc: f64 = 0.0;
    for (bytes) |b| acc = (acc + @as(f64, @floatFromInt(b))) / divisor;
    const frac = @abs(acc - @floor(acc));
    return @as(u64, @intFromFloat(frac * sz)) & mask;
}

const Usage = struct { strings: u64, distinct: u64, min: u64, max: u64 };

/// Every lowercase string of length 1..4, carousel-encoded (a..z = bytes 0..25), as the table hashes them.
fn usage(comptime which: enum { tribonacci, original, phi, silver }) !Usage {
    const mask: u64 = (1 << 24) - 1;
    const bits = try std.heap.page_allocator.alloc(u8, 1 << 21); // 2^24 bits
    defer std.heap.page_allocator.free(bits);
    @memset(bits, 0);
    var u = Usage{ .strings = 0, .distinct = 0, .min = std.math.maxInt(u64), .max = 0 };
    var len: usize = 1;
    while (len <= 4) : (len += 1) {
        var idx: [4]u8 = @splat(0);
        while (true) {
            const s = idx[0..len];
            const a: u64 = switch (which) {
                .tribonacci => hashTribonacci(s, mask),
                .original => hashOriginal(s, mask),
                .phi => hashRatio(s, mask, PHI),
                .silver => hashRatio(s, mask, SILVER_C),
            };
            u.strings += 1;
            const byte: usize = @intCast(a >> 3);
            const bit: u3 = @intCast(a & 7);
            if (bits[byte] & (@as(u8, 1) << bit) == 0) {
                bits[byte] |= @as(u8, 1) << bit;
                u.distinct += 1;
            }
            u.min = @min(u.min, a);
            u.max = @max(u.max, a);
            var p: usize = len;
            var carry = true;
            while (carry and p > 0) {
                p -= 1;
                idx[p] += 1;
                if (idx[p] < 26) carry = false else idx[p] = 0;
            }
            if (carry) break;
        }
    }
    return u;
}

test "A4: over all 475,254 lowercase strings of length 1-4 the exhibit's hashes use almost none of their 2^24 addresses" {
    const trib = try usage(.tribonacci);
    try std.testing.expectEqual(@as(u64, 475_254), trib.strings);
    try std.testing.expectEqual(@as(u64, 51), trib.distinct); // (Rust) 51
    try std.testing.expectEqual(@as(u64, 0), trib.min);
    try std.testing.expectEqual(@as(u64, 50), trib.max); // (Rust) range [0, 50]
    // why: lowercase carousel bytes are <= 25 and acc = acc/c + b is a leaky integrator, so acc <= 25/(1-1/c)
    const bound = 25.0 / (1.0 - 1.0 / TRIBONACCI_C);
    try std.testing.expect(bound < 55.0 and @as(f64, @floatFromInt(trib.max)) <= bound);

    const orig = try usage(.original);
    try std.testing.expectEqual(@as(u64, 189), orig.distinct); // (Rust) 189
    try std.testing.expectEqual(@as(u64, 1), orig.min);
    try std.testing.expectEqual(@as(u64, 351), orig.max);

    const phi = try usage(.phi);
    try std.testing.expectEqual(@as(u64, 177), phi.distinct); // (Rust) 177
    const silver = try usage(.silver);
    try std.testing.expectEqual(@as(u64, 501), silver.distinct); // (Rust) 501
    std.debug.print("\n[A4] 475,254 strings -> distinct addresses: Tribonacci {d} (range 0..{d}), Original {d}, PhiRatio {d}, SilverRatio {d}  (of 16,777,216)\n", .{ trib.distinct, trib.max, orig.distinct, phi.distinct, silver.distinct });
}

test "A4b: PhiRatio's address depends on ONE integer, because phi^2 = phi + 1" {
    // acc' = (acc + c)/phi. Write acc = a + b/phi with integers a, b. Then
    // acc' = (a + c)/phi + b/phi^2 = b + (a + c - b)/phi, so (a, b) -> (b, a + c - b).
    // The fractional part of a + b/phi is the fractional part of b/phi: only b matters.
    var seen = try std.heap.page_allocator.alloc(bool, 4096);
    defer std.heap.page_allocator.free(seen);
    @memset(seen, false);
    var distinct_b: usize = 0;
    var len: usize = 1;
    while (len <= 4) : (len += 1) {
        var idx: [4]u8 = @splat(0);
        while (true) {
            var a: i64 = 0;
            var b: i64 = 0;
            for (idx[0..len]) |c| {
                const na = b;
                const nb = a + @as(i64, c) - b;
                a = na;
                b = nb;
            }
            const slot: usize = @intCast(b + 2048);
            if (!seen[slot]) {
                seen[slot] = true;
                distinct_b += 1;
            }
            var p: usize = len;
            var carry = true;
            while (carry and p > 0) {
                p -= 1;
                idx[p] += 1;
                if (idx[p] < 26) carry = false else idx[p] = 0;
            }
            if (carry) break;
        }
    }
    // 475,254 strings collapse to 176 values of the single integer b. The float evaluation splits one of
    // them across a 2^-24 rounding boundary, which is why the exhibit's code shows 177 distinct addresses.
    try std.testing.expectEqual(@as(usize, 176), distinct_b);
    const phi = try usage(.phi);
    try std.testing.expect(phi.distinct >= distinct_b and phi.distinct <= distinct_b + 2);
}

// ---------------------------------------------------------------------
// A7  table.rs probing: insert (721-761) and get_index (773-794) with golden_step (710-717)
// ---------------------------------------------------------------------
fn hashCarousel(bytes: []const u8, mask: u32) u32 { // table.rs:51-68
    var h: u64 = 0x517cc1b727220a95;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x2545F4914F6CDD1D;
        h ^= h >> 17;
    }
    h ^= h >> 13;
    h *%= 0xC4CEB9FE1A85EC53;
    h ^= h >> 16;
    return @as(u32, @truncate(h)) & mask;
}

/// carousel::encode_string for the characters of "word_<digits>"
fn encodeKey(buf: *[24]u8, i: usize) []const u8 {
    var n: usize = 0;
    for ("word_") |c| {
        buf[n] = if (c == '_') (2 << 5) | 31 else c - 'a';
        n += 1;
    }
    var digits: [12]u8 = undefined;
    var d: usize = 0;
    var x = i;
    if (x == 0) {
        digits[0] = 0;
        d = 1;
    }
    while (x > 0) : (x /= 10) {
        digits[d] = @intCast(x % 10);
        d += 1;
    }
    while (d > 0) {
        d -= 1;
        buf[n] = (2 << 5) | digits[d]; // cartridge 2: digits
        n += 1;
    }
    return buf[0..n];
}

const MiniTable = struct {
    used: []bool,
    keys: [][16]u8,
    lens: []u8,
    mask: u32,
    step: u32,
    max_probe_depth: usize,

    fn init(alloc: std.mem.Allocator, bits: u5) !MiniTable {
        const size: usize = @as(usize, 1) << bits;
        const used = try alloc.alloc(bool, size);
        @memset(used, false);
        const keys = try alloc.alloc([16]u8, size);
        const lens = try alloc.alloc(u8, size);
        const step: u32 = @as(u32, @intCast((@as(u64, size) * 10_368_890 / (1 << 24)))) | 1; // table.rs:711-716
        return .{ .used = used, .keys = keys, .lens = lens, .mask = @intCast(size - 1), .step = step, .max_probe_depth = 0 };
    }

    fn deinit(self: *MiniTable, alloc: std.mem.Allocator) void {
        alloc.free(self.used);
        alloc.free(self.keys);
        alloc.free(self.lens);
    }

    fn matches(self: *const MiniTable, idx: u32, key: []const u8) bool { // Slot::key_matches
        const n = @min(key.len, 16);
        return self.lens[idx] == n and std.mem.eql(u8, self.keys[idx][0..n], key[0..n]);
    }

    fn insert(self: *MiniTable, key: []const u8) void {
        var idx = hashCarousel(key, self.mask);
        var probes: usize = 0;
        while (true) {
            if (!self.used[idx]) {
                self.used[idx] = true;
                const n = @min(key.len, 16);
                @memcpy(self.keys[idx][0..n], key[0..n]);
                self.lens[idx] = @intCast(n);
                self.max_probe_depth = @max(self.max_probe_depth, probes);
                return;
            }
            if (self.matches(idx, key)) return;
            idx = (idx +% self.step) & self.mask;
            probes += 1;
        }
    }

    fn found(self: *const MiniTable, key: []const u8) bool { // get_index with max_probes = 128
        var idx = hashCarousel(key, self.mask);
        var probes: usize = 0;
        while (true) {
            if (!self.used[idx]) return false;
            if (self.matches(idx, key)) return true;
            idx = (idx +% self.step) & self.mask;
            probes += 1;
            if (probes >= 128) return false;
        }
    }
};

test "A7: lookups of inserted keys start failing at high load (the exhibit's probe cap is 128)" {
    const alloc = std.heap.page_allocator;
    const Case = struct { bits: u5, fails: [5]usize, max_depth: usize };
    // (Rust) unfindable keys at load checkpoints 0.50, 0.70, 0.80, 0.90, 0.95, and max_probe_depth
    const cases = [_]Case{
        .{ .bits = 12, .fails = .{ 0, 0, 0, 10, 39 }, .max_depth = 1118 },
        .{ .bits = 16, .fails = .{ 0, 0, 0, 165, 889 }, .max_depth = 2183 },
    };
    const checkpoints = [_]f64{ 0.50, 0.70, 0.80, 0.90, 0.95 };
    for (cases) |case| {
        const size: usize = @as(usize, 1) << case.bits;
        var t = try MiniTable.init(alloc, case.bits);
        defer t.deinit(alloc);
        var cp: usize = 0;
        var i: usize = 0;
        const limit: usize = @intFromFloat(@as(f64, @floatFromInt(size)) * 0.97);
        var kb: [24]u8 = undefined;
        while (i < limit) : (i += 1) {
            t.insert(encodeKey(&kb, i));
            if (cp < checkpoints.len and @as(f64, @floatFromInt(i + 1)) >= @as(f64, @floatFromInt(size)) * checkpoints[cp]) {
                var bad: usize = 0;
                var j: usize = 0;
                while (j <= i) : (j += 1) {
                    if (!t.found(encodeKey(&kb, j))) bad += 1;
                }
                try std.testing.expectEqual(case.fails[cp], bad);
                cp += 1;
            }
        }
        try std.testing.expectEqual(case.max_depth, t.max_probe_depth);
        std.debug.print("[A7] 2^{d} slots: unfindable at 90% load = {d}, at 95% = {d}; deepest insert probe = {d}\n", .{ case.bits, case.fails[3], case.fails[4], t.max_probe_depth });
    }
}

// ---------------------------------------------------------------------
// A10  settle(): pathway_table.rs:35-38 (compute_error), 43-45 (hebbian_update), 149-202 (settle)
// ---------------------------------------------------------------------
const Settled = struct { energy: f64, iterations: usize, score: u16 };

fn settle(actual: u16, predicted: f32, pre: f32, lr: f32, max_iter: usize, threshold: f64) Settled {
    var score = actual;
    var prev_energy: f64 = std.math.floatMax(f64);
    var total: f64 = 0;
    var i: usize = 0;
    while (i < max_iter) : (i += 1) {
        const err: f32 = @as(f32, @floatFromInt(score)) - predicted; // compute_error
        const energy: f32 = err * err;
        total = energy; // compute_errors: total_energy = sum over tracked slots
        const adjustment: f32 = -err * pre * lr; // hebbian_update
        const new_score = std.math.clamp(@as(f32, @floatFromInt(score)) + adjustment, 0.0, 65535.0);
        score = @intFromFloat(new_score); // `as u16` truncates toward zero
        const delta = @abs(prev_energy - total);
        if (delta < threshold) return .{ .energy = total, .iterations = i + 1, .score = score };
        prev_energy = total;
    }
    return .{ .energy = total, .iterations = max_iter, .score = score };
}

test "A10: settle() stops, by its own test, with the error still there when the prediction is above the score" {
    const under = settle(1000, 1010.0, 0.5, 0.01, 200, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), under.iterations); // (Rust) 2
    try std.testing.expectEqual(@as(f64, 100.0), under.energy); // (Rust) 100.0
    try std.testing.expectEqual(@as(u16, 1000), under.score); // never moved; residual error -10
    const over = settle(1010, 1000.0, 0.5, 0.01, 200, 1e-9);
    try std.testing.expectEqual(@as(usize, 12), over.iterations); // (Rust) 12
    try std.testing.expectEqual(@as(f64, 0.0), over.energy);
    try std.testing.expectEqual(@as(u16, 1000), over.score); // drifted down one unit per iteration
}

// ---------------------------------------------------------------------
// A11  carousel.rs: unknown characters alias ':'
// ---------------------------------------------------------------------
test "A11: the carousel's 'unknown' code is the code of ':'" {
    const cart0 = "abcdefghijklmnopqrstuvwxyz.,!?;:"; // carousel.rs CART_0
    try std.testing.expectEqual(@as(usize, 32), cart0.len);
    const colon: u8 = @intCast(std.mem.indexOfScalar(u8, cart0, ':').?);
    const unknown: u8 = 0b000_11111; // carousel.rs:78
    try std.testing.expectEqual(unknown, colon);
}
