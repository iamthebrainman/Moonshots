//! named.zig - addressing a SUNZI store by name, without a dictionary.
//!
//! sunzi.zig addresses facts by prime and says nothing about names. This file is
//! the optional rule that turns a name into a prime so that no name->key table is
//! needed. It is a hash table whose "slots" are primes, and it inherits a hash
//! table's weaknesses; the tests below demonstrate each of them:
//!
//!   N1  key(name, j) = the first prime at or above hash(name, j) inside [lo, lo+span).
//!   N2  the value stored under a key is  fingerprint(name) << 16 | payload.
//!   N3  write: probe j = 0, 1, 2, ... ; use the first key that is absent (insert) or
//!       that holds this name's fingerprint (overwrite). Probing past a key whose
//!       fingerprint differs resolves a collision between two names.
//!   N4  read: probe j = 0, 1, ...; an absent key ends the search ("not found"); a key
//!       with this name's fingerprint is "found".
//!   N5  remove = tombstone (payload 0xFFFF). The key stays, so probe chains stay intact.
//!
//! Costs, all measured in the tests: a false "found" has probability about 2^-12 per
//! colliding probe; two names that collide make the bytes depend on which was written
//! first (canonical form is lost exactly when a collision occurs); real removal is
//! impossible because names are not stored; names cannot be listed.

const std = @import("std");
const sunzi = @import("sunzi.zig");
const primes = @import("primes.zig");

pub const payload_bits = 16;
pub const fp_bits = 12;
pub const tombstone: u32 = 0xFFFF;
const fp_mask: u32 = (1 << fp_bits) - 1;

pub const Error = sunzi.Error || error{TooManyProbes};

fn hash64(name: []const u8, salt: u32) u64 {
    var h: u64 = 0xcbf29ce484222325 ^ (@as(u64, salt) *% 0x9E3779B97F4A7C15);
    for (name) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= h >> 30;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 27;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 31;
    return h;
}

pub fn fingerprint(name: []const u8) u32 {
    return @intCast((hash64(name, 0xFFFF_FFFF) >> 20) & fp_mask);
}

/// The default key range: primes in [2^28, 2^32 - 2^16). 2^28 keeps every 28-bit value below its key.
pub const default_lo: u32 = 1 << 28;
pub const default_span: u64 = (1 << 32) - (1 << 16) - (1 << 28);

pub fn Named(comptime cap: usize, comptime lo: u32, comptime span: u64) type {
    comptime {
        if (lo < (1 << 28)) @compileError("keys must exceed the 28-bit value range");
        if (@as(u64, lo) + span > (1 << 32) - (1 << 12)) @compileError("key range too close to 2^32");
    }
    return struct {
        const Self = @This();
        pub const St = sunzi.Store(cap);

        store: St,
        max_probes: u32,

        pub fn init() Self {
            return .{ .store = St.init(), .max_probes = 64 };
        }

        /// Key number j of a name.
        pub fn keyFor(name: []const u8, j: u32) u32 {
            const start: u32 = lo + @as(u32, @intCast(hash64(name, j) % span));
            return primes.nextPrime(start).?;
        }

        fn fpOf(v: u32) u32 {
            return v >> payload_bits;
        }

        fn packValue(fp: u32, payload: u32) u32 {
            return (fp << payload_bits) | payload;
        }

        pub fn put(self: *Self, name: []const u8, payload: u16) Error!sunzi.PutResult {
            if (payload == tombstone) return error.ValueTooLarge; // reserved
            const fp = fingerprint(name);
            var j: u32 = 0;
            while (j < self.max_probes) : (j += 1) {
                const p = keyFor(name, j);
                if (self.store.get(p)) |v| {
                    if (fpOf(v) == fp) return self.store.put(p, packValue(fp, payload));
                } else {
                    return self.store.put(p, packValue(fp, payload));
                }
            }
            return error.TooManyProbes;
        }

        /// The payload stored for the name, or null. A removed (tombstoned) name reads as null.
        pub fn get(self: *const Self, name: []const u8) ?u16 {
            return self.getAt(name, null);
        }

        /// As get, and also reports which probe number j found it.
        pub fn getAt(self: *const Self, name: []const u8, probe_out: ?*u32) ?u16 {
            const fp = fingerprint(name);
            var j: u32 = 0;
            while (j < self.max_probes) : (j += 1) {
                const p = keyFor(name, j);
                const v = self.store.get(p) orelse return null;
                if (fpOf(v) == fp) {
                    if (probe_out) |o| o.* = j;
                    const payload = v & ((1 << payload_bits) - 1);
                    if (payload == tombstone) return null;
                    return @intCast(payload);
                }
            }
            return null;
        }

        /// Marks the name removed. The key stays in M so that other names whose probe
        /// chains pass through it remain reachable.
        pub fn remove(self: *Self, name: []const u8) Error!bool {
            const fp = fingerprint(name);
            var j: u32 = 0;
            while (j < self.max_probes) : (j += 1) {
                const p = keyFor(name, j);
                const v = self.store.get(p) orelse return false;
                if (fpOf(v) == fp) {
                    if ((v & ((1 << payload_bits) - 1)) == tombstone) return false;
                    _ = try self.store.put(p, packValue(fp, tombstone));
                    return true;
                }
            }
            return false;
        }
    };
}

// =====================================================================
// tests
// =====================================================================

const rng_mod = @import("rng.zig");

fn nameOf(buf: []u8, prefix: []const u8, i: usize) []const u8 {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = i;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (x > 0) : (x /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    var at: usize = 0;
    for (prefix) |c| {
        buf[at] = c;
        at += 1;
    }
    while (n > 0) {
        n -= 1;
        buf[at] = tmp[n];
        at += 1;
    }
    return buf[0..at];
}

test "named: put / get / overwrite / remove with no dictionary (default key range)" {
    const NS = Named(512, default_lo, default_span);
    var ns = NS.init();
    var buf: [32]u8 = undefined;
    const n = 300;
    for (0..n) |i| {
        _ = try ns.put(nameOf(&buf, "fact-", i), @intCast(i * 7 % 60000));
    }
    for (0..n) |i| try std.testing.expectEqual(@as(?u16, @intCast(i * 7 % 60000)), ns.get(nameOf(&buf, "fact-", i)));
    // absent names are absent (a false hit needs a prime collision AND a 12-bit fingerprint match)
    var false_hits: usize = 0;
    for (0..20000) |i| {
        if (ns.get(nameOf(&buf, "never-", i)) != null) false_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), false_hits);
    // overwrite and remove
    try std.testing.expectEqual(sunzi.PutResult.updated, try ns.put("fact-5", 4242));
    try std.testing.expectEqual(@as(?u16, 4242), ns.get("fact-5"));
    try std.testing.expect(try ns.remove("fact-5"));
    try std.testing.expectEqual(@as(?u16, null), ns.get("fact-5"));
    try std.testing.expect(!(try ns.remove("fact-5")));
    try std.testing.expect(!(try ns.remove("no-such-name")));
    // the tombstone payload is reserved
    try std.testing.expectError(error.ValueTooLarge, ns.put("x", 0xFFFF));
    // re-adding a removed name reuses its key
    _ = try ns.put("fact-5", 7);
    try std.testing.expectEqual(@as(?u16, 7), ns.get("fact-5"));
    // every key lies in the declared range and is prime
    var scratch: u32 = 0;
    for (0..8) |j| {
        scratch = NS.keyFor("fact-1", @intCast(j));
        try std.testing.expect(primes.isPrime(scratch) and scratch >= default_lo and scratch < (1 << 32) - (1 << 16) + 400);
    }
}

// A deliberately tiny key range (about 40 primes) so that collisions are the norm.
const Tiny = Named(512, 1 << 28, 800);

test "named: collisions are resolved by probing, and the cost is measured" {
    var ts = Tiny.init();
    var buf: [32]u8 = undefined;
    const n = 30;
    for (0..n) |i| _ = try ts.put(nameOf(&buf, "k", i), @intCast(i + 1));
    var deepest: u32 = 0;
    var probed: usize = 0;
    for (0..n) |i| {
        var j: u32 = 0;
        try std.testing.expectEqual(@as(?u16, @intCast(i + 1)), ts.getAt(nameOf(&buf, "k", i), &j));
        if (j > 0) probed += 1;
        deepest = @max(deepest, j);
    }
    try std.testing.expect(probed > 0); // collisions really happened
    // false positives: absent names in a crowded range. A false "found" needs a 12-bit fingerprint match
    // on a present key, so about (#present probes) * 2^-12 of absent lookups.
    var fp_hits: usize = 0;
    const trials = 40000;
    for (0..trials) |i| {
        if (ts.get(nameOf(&buf, "absent", i)) != null) fp_hits += 1;
    }
    std.debug.print("\n[named] {d} names in a ~40-prime range: {d} needed a probe (deepest j = {d}); {d} false hits in {d} absent lookups ({d:.4}%)\n", .{ n, probed, deepest, fp_hits, trials, 100.0 * @as(f64, @floatFromInt(fp_hits)) / @as(f64, trials) });
    // roughly trials * P(first probe lands on a present key) * 2^-12; allow a generous bound
    try std.testing.expect(fp_hits < 90);
}

test "named: FAILURE MODE - when two names collide the bytes depend on the order they were written" {
    // find two names whose first key is the same prime
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var a: []const u8 = undefined;
    var b: []const u8 = undefined;
    var found = false;
    var i: usize = 0;
    search: while (i < 200) : (i += 1) {
        var k: usize = i + 1;
        while (k < 200) : (k += 1) {
            const x = nameOf(&buf1, "n", i);
            const y = nameOf(&buf2, "n", k);
            if (Tiny.keyFor(x, 0) == Tiny.keyFor(y, 0) and fingerprint(x) != fingerprint(y)) {
                a = x;
                b = y;
                found = true;
                break :search;
            }
        }
    }
    try std.testing.expect(found);
    var ab = Tiny.init();
    _ = try ab.put(a, 11);
    _ = try ab.put(b, 22);
    var ba = Tiny.init();
    _ = try ba.put(b, 22);
    _ = try ba.put(a, 11);
    // both orders answer every query correctly ...
    try std.testing.expectEqual(@as(?u16, 11), ab.get(a));
    try std.testing.expectEqual(@as(?u16, 22), ab.get(b));
    try std.testing.expectEqual(@as(?u16, 11), ba.get(a));
    try std.testing.expectEqual(@as(?u16, 22), ba.get(b));
    // ... but they are different integers: the canonical form of sunzi.zig is lost at the naming layer
    try std.testing.expect(!ab.store.eql(&ba.store));
}

test "named: FAILURE MODE - deleting a key inside a probe chain hides the names behind it; tombstones do not" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var a: []const u8 = undefined;
    var b: []const u8 = undefined;
    var i: usize = 0;
    var found = false;
    search: while (i < 200) : (i += 1) {
        var k: usize = i + 1;
        while (k < 200) : (k += 1) {
            const x = nameOf(&buf1, "n", i);
            const y = nameOf(&buf2, "n", k);
            if (Tiny.keyFor(x, 0) == Tiny.keyFor(y, 0) and fingerprint(x) != fingerprint(y)) {
                a = x;
                b = y;
                found = true;
                break :search;
            }
        }
    }
    try std.testing.expect(found);
    var ns = Tiny.init();
    _ = try ns.put(a, 1); // takes the shared first key
    _ = try ns.put(b, 2); // collides, lands on its second key
    var j: u32 = 0;
    try std.testing.expectEqual(@as(?u16, 2), ns.getAt(b, &j));
    try std.testing.expect(j >= 1);

    // raw deletion of a's key (what sunzi.zig's del does) cuts b's probe chain
    var raw = ns;
    try std.testing.expect(try raw.store.del(Tiny.keyFor(a, 0)));
    try std.testing.expectEqual(@as(?u16, null), raw.get(a));
    try std.testing.expectEqual(@as(?u16, null), raw.get(b)); // b is still in the store, unreachable

    // tombstoning keeps the chain intact
    var safe = ns;
    try std.testing.expect(try safe.remove(a));
    try std.testing.expectEqual(@as(?u16, null), safe.get(a));
    try std.testing.expectEqual(@as(?u16, 2), safe.get(b));
}

test "named: probe exhaustion fails closed" {
    var ts = Tiny.init();
    ts.max_probes = 2;
    var buf: [32]u8 = undefined;
    var failed = false;
    for (0..200) |i| {
        if (ts.put(nameOf(&buf, "z", i), 1)) |_| {} else |err| {
            try std.testing.expectEqual(error.TooManyProbes, err);
            failed = true;
            break;
        }
    }
    try std.testing.expect(failed);
}
