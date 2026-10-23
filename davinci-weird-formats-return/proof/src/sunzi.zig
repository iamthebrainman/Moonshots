//! sunzi.zig - SUNZI: a knowledge base that is one pair of integers.
//!
//! State is (M, K):
//!   M  squarefree product of the keys present (each key is a prime < 2^32),
//!   K  the unique integer in [0, M) with  K = value(p)  (mod p)  for every key p.
//!
//! The Chinese Remainder Theorem makes K unique, so the pair is canonical: two
//! stores hold the same facts if and only if their (M, K) are equal as integers.
//! There is no table, no slot, no index. A value is not stored anywhere; it is
//! the residue of the whole number.
//!
//! Addressing  address of a fact = its prime key p. has(p) is "p divides M".
//! Read        get(p) = K mod p.   view(d) = (d, K mod d) for any divisor d of M.
//! Write       put(p, v): lift K by a multiple of M/p so that K = v (mod p),
//!             leaving every other residue untouched. del(p): M /= p, K mod= M.
//! Algebra     diff(A, B): g = gcd(M_A, M_B) are the shared keys; the shared keys
//!             whose values agree are gcd(|K_A - K_B|, g); the rest conflict.
//!
//! Capacity is a comptime parameter (see big.zig). A write that does not fit
//! returns error.Overflow and leaves the store unchanged.

const std = @import("std");
const big = @import("big.zig");
const primes = @import("primes.zig");

pub const Error = error{
    /// The key is not a prime below 2^32.
    NotPrime,
    /// The value is not smaller than its key (a residue mod p is < p).
    ValueTooLarge,
    /// The fixed capacity of the store (or of an output buffer) is exhausted.
    Overflow,
    /// A required key is not present.
    NotFound,
    /// Bytes are not the canonical encoding of a valid store.
    Malformed,
    /// M has a prime factor that is not in the supplied universe of primes.
    IncompleteUniverse,
    /// The supplied number does not divide M.
    NotADivisor,
    /// Two stores disagree on a key they share, so no store contains both.
    Conflict,
};

pub const magic = [8]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1 };

pub const PutResult = enum { inserted, updated, unchanged };

pub fn Store(comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const Num = big.Big(cap);

        /// Product of the keys present; 1 for the empty store.
        m: Num,
        /// The CRT solution in [0, m); 0 for the empty store.
        k: Num,

        pub const Diff = struct {
            /// gcd(M_a, M_b): product of the keys present in both stores.
            shared: Num,
            /// Product of the shared keys whose values are equal.
            agree: Num,
            /// Product of the shared keys whose values differ (shared / agree).
            conflict: Num,
            /// M_a / shared: keys only in a.
            only_a: Num,
            /// M_b / shared: keys only in b.
            only_b: Num,
        };

        pub fn init() Self {
            var s: Self = undefined;
            s.m.setU64(1);
            s.k.len = 0;
            return s;
        }

        pub fn copyFrom(self: *Self, o: *const Self) void {
            self.m.copyFrom(&o.m);
            self.k.copyFrom(&o.k);
        }

        pub fn eql(a: *const Self, b: *const Self) bool {
            return a.m.eql(&b.m) and a.k.eql(&b.k);
        }

        // ----------------------------------------------------------------
        // read
        // ----------------------------------------------------------------

        /// True if the prime p is a key of the store ("p divides M").
        pub fn has(self: *const Self, p: u32) bool {
            if (!primes.isPrime(p)) return false;
            return self.m.modSmall(p) == 0;
        }

        /// The value stored under p, or null if p is not a key.
        pub fn get(self: *const Self, p: u32) ?u32 {
            if (!self.has(p)) return null;
            return self.k.modSmall(p);
        }

        // ----------------------------------------------------------------
        // write
        // ----------------------------------------------------------------

        /// Sets the value of key p to v, adding p if it is new.
        /// Cost: a handful of passes over the limbs of M and K - O(size of the store).
        pub fn put(self: *Self, p: u32, v: u32) Error!PutResult {
            if (!primes.isPrime(p)) return error.NotPrime;
            if (v >= p) return error.ValueTooLarge;
            const mp = self.m.modSmall(p);
            const kp = self.k.modSmall(p);
            const want: u64 = (@as(u64, v) + p - kp) % p; // (v - K) mod p
            if (mp != 0) {
                // New key. M' = M*p. Choose t in [0,p) with K + M*t = v (mod p).
                if (self.m.len + 3 > cap) return error.Overflow;
                const t: u32 = @intCast((want * primes.modInverse(mp, p)) % p);
                try self.k.addMulSmall(&self.m, t);
                try self.m.mulSmall(p);
                return .inserted;
            }
            // Existing key. With Q = M/p (not divisible by p, M being squarefree),
            // K + Q*t = v (mod p) and K + Q*t = K (mod Q).
            if (want == 0) return .unchanged;
            if (self.m.len + 3 > cap) return error.Overflow;
            var q = self.m;
            _ = q.divSmall(p);
            const qp = q.modSmall(p);
            if (qp == 0) return error.Malformed; // p^2 divides M: this is not a valid store
            const t: u32 = @intCast((want * primes.modInverse(qp, p)) % p);
            try self.k.addMulSmall(&q, t); // K < 2M now
            if (self.k.cmp(&self.m) != .lt) self.k.sub(&self.m);
            return .updated;
        }

        /// Removes key p. Returns whether it was present.
        pub fn del(self: *Self, p: u32) Error!bool {
            if (!primes.isPrime(p)) return error.NotPrime;
            if (self.m.modSmall(p) != 0) return false;
            _ = self.m.divSmall(p);
            var q: Num = undefined;
            var r: Num = undefined;
            Num.divMod(&q, &r, &self.k, &self.m);
            self.k.copyFrom(&r);
            return true;
        }

        // ----------------------------------------------------------------
        // seal: the integrity check is itself a fact
        // ----------------------------------------------------------------

        /// Reserved key of the seal: the largest prime below 2^32. A store that uses
        /// sealing must not use this key for anything else.
        pub const seal_key: u32 = 4_294_967_291;

        fn sealDigest(rest: *const Self) Error!u32 {
            var tmp: [16 + 8 * cap]u8 = undefined;
            const n = try rest.encode(&tmp);
            return @intCast(fnv1a64(tmp[0..n]) % seal_key);
        }

        /// (Re)computes the seal: stores, under seal_key, a digest of the canonical
        /// bytes of the store without it. The seal is a fact like any other - an
        /// ordinary key whose residue K mod seal_key is the digest - so it needs no
        /// header, no trailer and no new rule. Any later put/del makes it stale.
        pub fn seal(self: *Self) Error!void {
            _ = try self.del(seal_key);
            const digest = try sealDigest(self);
            _ = try self.put(seal_key, digest);
        }

        /// True iff the store carries a seal and the seal matches the rest of the store.
        /// Detects corruption of K or M with probability about 1 - 2^-32; it is a
        /// non-cryptographic digest and does not defend against an adversary.
        pub fn sealIsValid(self: *const Self) bool {
            const stored = self.get(seal_key) orelse return false;
            var rest = self.*;
            _ = rest.del(seal_key) catch return false;
            const digest = sealDigest(&rest) catch return false;
            return stored == digest;
        }

        // ----------------------------------------------------------------
        // views: every divisor of M names a sub-store, and it is a reduction
        // ----------------------------------------------------------------

        /// The sub-store whose key set is the divisor d of M: (d, K mod d).
        pub fn viewDivisor(self: *const Self, d: *const Num) Error!Self {
            if (d.isZero()) return error.NotADivisor;
            var q: Num = undefined;
            var r: Num = undefined;
            Num.divMod(&q, &r, &self.m, d);
            if (!r.isZero()) return error.NotADivisor;
            var out: Self = undefined;
            out.m.copyFrom(d);
            Num.divMod(&q, &out.k, &self.k, d);
            return out;
        }

        /// The sub-store restricted to the listed keys (each must be present, no repeats).
        pub fn viewKeys(self: *const Self, keys: []const u32) Error!Self {
            var d = Num.fromU64(1);
            for (keys) |p| {
                if (!self.has(p)) return error.NotFound;
                try d.mulSmall(p);
            }
            return self.viewDivisor(&d);
        }

        // ----------------------------------------------------------------
        // algebra of two stores
        // ----------------------------------------------------------------

        /// Compares two stores with one gcd of the key products and one gcd of the
        /// difference of the numerators. Nothing is enumerated.
        pub fn diff(a: *const Self, b: *const Self) Diff {
            var d: Diff = undefined;
            Num.gcd(&d.shared, &a.m, &b.m);
            var delta: Num = undefined;
            switch (a.k.cmp(&b.k)) {
                .eq => delta.len = 0,
                .gt => {
                    delta.copyFrom(&a.k);
                    delta.sub(&b.k);
                },
                .lt => {
                    delta.copyFrom(&b.k);
                    delta.sub(&a.k);
                },
            }
            if (delta.isZero()) {
                d.agree.copyFrom(&d.shared);
            } else {
                Num.gcd(&d.agree, &delta, &d.shared);
            }
            var r: Num = undefined;
            Num.divMod(&d.conflict, &r, &d.shared, &d.agree);
            std.debug.assert(r.isZero());
            Num.divMod(&d.only_a, &r, &a.m, &d.shared);
            std.debug.assert(r.isZero());
            Num.divMod(&d.only_b, &r, &b.m, &d.shared);
            std.debug.assert(r.isZero());
            return d;
        }

        /// True when the two stores agree on every key they share (so a merge exists).
        pub fn consistent(a: *const Self, b: *const Self) bool {
            return a.diff(b).conflict.isOne();
        }

        /// The one store that holds every fact of a and every fact of b, if they agree wherever
        /// both speak (error.Conflict otherwise). One Chinese-remainder step on the two big
        /// numbers: no key is enumerated, no fact is replayed.
        ///
        ///   g = gcd(M_a, M_b);  m2 = M_b / g;  require g | (K_b - K_a)
        ///   t = ((K_b - K_a) / g) * (M_a / g)^-1  (mod m2)
        ///   M = M_a * m2;  K = K_a + M_a * t
        ///
        /// glue is commutative, associative and idempotent, and glue(a, b) restricted to M_a
        /// (resp. M_b) gives back a (resp. b): consistent stores form a join-semilattice.
        pub fn glue(a: *const Self, b: *const Self) Error!Self {
            var g: Num = undefined;
            Num.gcd(&g, &a.m, &b.m);
            var q: Num = undefined;
            var r: Num = undefined;
            var m2: Num = undefined;
            Num.divMod(&m2, &r, &b.m, &g); // exact: g | M_b
            // delta = K_b - K_a as sign and magnitude
            var delta: Num = undefined;
            var negative = false;
            switch (b.k.cmp(&a.k)) {
                .eq => delta.len = 0,
                .gt => {
                    delta.copyFrom(&b.k);
                    delta.sub(&a.k);
                },
                .lt => {
                    delta.copyFrom(&a.k);
                    delta.sub(&b.k);
                    negative = true;
                },
            }
            var d: Num = undefined;
            Num.divMod(&d, &r, &delta, &g);
            if (!r.isZero()) return error.Conflict; // they disagree on a shared key
            if (m2.isOne()) return a.*; // every key of b is already in a, and they agree
            // dm = (delta / g) mod m2, with the sign applied
            var dm: Num = undefined;
            Num.divMod(&q, &dm, &d, &m2);
            if (negative and !dm.isZero()) {
                var flipped: Num = undefined;
                flipped.copyFrom(&m2);
                flipped.sub(&dm);
                dm.copyFrom(&flipped);
            }
            // inv = (M_a / g)^-1 mod m2   (M_a/g and m2 are coprime because M is squarefree)
            var m1: Num = undefined;
            Num.divMod(&m1, &r, &a.m, &g);
            var m1r: Num = undefined;
            Num.divMod(&q, &m1r, &m1, &m2);
            var inv: Num = undefined;
            try modInverseBig(Num, &inv, &m1r, &m2);
            // t = dm * inv mod m2
            var prod: Num = undefined;
            try prod.mul(&dm, &inv);
            var t: Num = undefined;
            Num.divMod(&q, &t, &prod, &m2);
            var out: Self = undefined;
            try out.m.mul(&a.m, &m2);
            var shift: Num = undefined;
            try shift.mul(&a.m, &t);
            out.k.copyFrom(&a.k);
            try out.k.add(&shift);
            return out;
        }

        // ----------------------------------------------------------------
        // enumeration (the one operation the format does not make cheap)
        // ----------------------------------------------------------------

        /// Writes the keys in ascending order into `out` and returns how many.
        /// `universe` must list, in ascending order, every prime that may be a key.
        /// The product of the keys found is checked against M, so a key outside the
        /// universe is reported as IncompleteUniverse rather than silently dropped.
        pub fn keysInto(self: *const Self, universe: []const u32, out: []u32) Error!usize {
            var rest = self.m;
            var n: usize = 0;
            for (universe) |p| {
                if (rest.isOne()) break;
                if (rest.modSmall(p) == 0) {
                    if (n >= out.len) return error.Overflow;
                    out[n] = p;
                    n += 1;
                    _ = rest.divSmall(p);
                }
            }
            if (!rest.isOne()) return error.IncompleteUniverse;
            return n;
        }

        /// Full structural validation of a store against a universe of primes:
        /// M must be a product of distinct universe primes and K < M.
        pub fn verify(self: *const Self, universe: []const u32) Error!void {
            var rest = self.m;
            for (universe) |p| {
                if (rest.isOne()) break;
                if (rest.modSmall(p) == 0) {
                    _ = rest.divSmall(p);
                    if (rest.modSmall(p) == 0) return error.Malformed; // p^2 divides M
                }
            }
            if (!rest.isOne()) return error.IncompleteUniverse;
            if (self.k.cmp(&self.m) != .lt) return error.Malformed;
        }

        // ----------------------------------------------------------------
        // direct construction (independent of put; used to cross-check it)
        // ----------------------------------------------------------------

        /// Builds the store for the given facts with the textbook CRT formula
        ///   K = sum_i v_i * (M/p_i) * ((M/p_i)^-1 mod p_i)   (mod M).
        /// Keys must be distinct primes. Needs headroom for K up to n*M before reduction.
        pub fn fromFacts(keys: []const u32, values: []const u32) Error!Self {
            std.debug.assert(keys.len == values.len);
            var s = init();
            for (keys, values) |p, v| {
                if (!primes.isPrime(p)) return error.NotPrime;
                if (v >= p) return error.ValueTooLarge;
                if (s.m.modSmall(p) == 0) return error.Malformed; // duplicate key
                try s.m.mulSmall(p);
            }
            var acc: Num = Num.init();
            for (keys, values) |p, v| {
                var mi = s.m;
                _ = mi.divSmall(p);
                const inv = primes.modInverse(mi.modSmall(p), p);
                const c: u32 = @intCast((@as(u64, v) * inv) % p);
                try acc.addMulSmall(&mi, c);
            }
            var q: Num = undefined;
            Num.divMod(&q, &s.k, &acc, &s.m);
            return s;
        }

        // ----------------------------------------------------------------
        // canonical bytes
        // ----------------------------------------------------------------

        /// magic(8) | u32be len(M) | M big-endian | u32be len(K) | K big-endian (empty for 0)
        pub fn encodedLen(self: *const Self) usize {
            return 8 + 4 + self.m.byteLen() + 4 + self.k.byteLen();
        }

        pub fn encode(self: *const Self, out: []u8) Error!usize {
            const total = self.encodedLen();
            if (out.len < total) return error.Overflow;
            var at: usize = 0;
            for (magic) |b| {
                out[at] = b;
                at += 1;
            }
            const ml = self.m.byteLen();
            putU32(out[at .. at + 4], @intCast(ml));
            at += 4;
            self.m.writeBE(out[at .. at + ml]);
            at += ml;
            const kl = self.k.byteLen();
            putU32(out[at .. at + 4], @intCast(kl));
            at += 4;
            self.k.writeBE(out[at .. at + kl]);
            at += kl;
            return at;
        }

        /// Strict decoder: rejects every byte string that is not the canonical
        /// encoding of some store (bad magic, leading zero bytes, K >= M, truncation,
        /// trailing bytes). It cannot cheaply prove that M is squarefree or a product
        /// of primes; use verify() with a universe for that.
        pub fn decode(bytes: []const u8) Error!Self {
            if (bytes.len < 8 + 4 + 1 + 4) return error.Malformed;
            for (magic, 0..) |b, i| {
                if (bytes[i] != b) return error.Malformed;
            }
            var at: usize = 8;
            const ml: usize = getU32(bytes[at .. at + 4]);
            at += 4;
            // Lengths come from the input: compare by subtraction so that a hostile 0xFFFFFFFF
            // cannot wrap a 32-bit usize. (bytes.len >= 17 and at == 12 here, so this cannot underflow.)
            if (ml == 0 or ml > bytes.len - at - 4) return error.Malformed;
            if (bytes[at] == 0) return error.Malformed;
            var s: Self = undefined;
            s.m.readBE(bytes[at .. at + ml]) catch return error.Overflow;
            at += ml;
            const kl: usize = getU32(bytes[at .. at + 4]);
            at += 4;
            if (kl != bytes.len - at) return error.Malformed;
            if (kl > 0 and bytes[at] == 0) return error.Malformed;
            s.k.readBE(bytes[at .. at + kl]) catch return error.Overflow;
            if (s.k.cmp(&s.m) != .lt) return error.Malformed;
            return s;
        }
    };
}

/// out = a^-1 mod m, for m > 1, 0 < a < m and gcd(a, m) = 1: extended Euclid on unsigned
/// bignums with the sign of the Bezout coefficient tracked on the side.
fn modInverseBig(comptime Num: type, out: *Num, a: *const Num, m: *const Num) !void {
    var r0: Num = undefined;
    var r1: Num = undefined;
    r0.copyFrom(m);
    r1.copyFrom(a);
    var t0: Num = Num.init(); // 0
    var t1: Num = Num.fromU64(1);
    var t0_neg = false;
    var t1_neg = false;
    var q: Num = undefined;
    var r2: Num = undefined;
    var prod: Num = undefined;
    var t2: Num = undefined;
    while (!r1.isZero()) {
        Num.divMod(&q, &r2, &r0, &r1);
        // t2 = t0 - q*t1, with signs
        try prod.mul(&q, &t1);
        const prod_neg = t1_neg;
        var t2_neg: bool = undefined;
        if (t0_neg != prod_neg) {
            // t0 and -prod have the same sign: magnitudes add
            t2.copyFrom(&t0);
            try t2.add(&prod);
            t2_neg = t0_neg;
        } else if (t0.cmp(&prod) != .lt) {
            t2.copyFrom(&t0);
            t2.sub(&prod);
            t2_neg = t0_neg;
        } else {
            t2.copyFrom(&prod);
            t2.sub(&t0);
            t2_neg = !t0_neg;
        }
        if (t2.isZero()) t2_neg = false;
        r0.copyFrom(&r1);
        r1.copyFrom(&r2);
        t0.copyFrom(&t1);
        t0_neg = t1_neg;
        t1.copyFrom(&t2);
        t1_neg = t2_neg;
    }
    std.debug.assert(r0.isOne()); // a and m were coprime
    if (t0_neg) {
        out.copyFrom(m);
        out.sub(&t0);
    } else {
        out.copyFrom(&t0);
    }
}

fn putU32(out: []u8, v: u32) void {
    out[0] = @truncate(v >> 24);
    out[1] = @truncate(v >> 16);
    out[2] = @truncate(v >> 8);
    out[3] = @truncate(v);
}

fn getU32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// FNV-1a, 64-bit, over a byte string. Used for golden digests in the tests; defined
/// here so the digest does not depend on any standard-library hash.
pub fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// =====================================================================
// tests
// =====================================================================

const rng_mod = @import("rng.zig");

const S = Store(256);

/// The first primes below 40000 (4203 of them), ascending.
fn smallPrimes(buf: *[4300]u32) []const u32 {
    var scratch: [20_001]u8 = undefined;
    const n = primes.sieve(40_000, &scratch, buf);
    return buf[0..n];
}

/// Stores built by put in the given order.
fn buildByPuts(comptime SS: type, keys: []const u32, vals: []const u32) !SS {
    var s = SS.init();
    for (keys, vals) |p, v| _ = try s.put(p, v);
    return s;
}

fn productOf(comptime SS: type, keys: []const u32) !SS.Num {
    var d = SS.Num.fromU64(1);
    for (keys) |p| try d.mulSmall(p);
    return d;
}

test "sunzi: worked example from PROPOSAL (7 -> 3, 11 -> 10)" {
    var s = S.init();
    try std.testing.expectEqual(@as(u128, 1), s.m.toU128().?);
    try std.testing.expectEqual(@as(u128, 0), s.k.toU128().?);
    try std.testing.expectEqual(PutResult.inserted, try s.put(7, 3));
    try std.testing.expectEqual(@as(u128, 7), s.m.toU128().?);
    try std.testing.expectEqual(@as(u128, 3), s.k.toU128().?);
    try std.testing.expectEqual(PutResult.inserted, try s.put(11, 10));
    try std.testing.expectEqual(@as(u128, 77), s.m.toU128().?);
    try std.testing.expectEqual(@as(u128, 10), s.k.toU128().?); // 10 = 3 (mod 7), 10 = 10 (mod 11)
    try std.testing.expectEqual(@as(?u32, 3), s.get(7));
    try std.testing.expectEqual(@as(?u32, 10), s.get(11));
    try std.testing.expectEqual(@as(?u32, null), s.get(13));
    // overwrite 7 -> 5: the unique K in [0,77) with K = 5 (7) and K = 10 (11) is 54
    try std.testing.expectEqual(PutResult.updated, try s.put(7, 5));
    try std.testing.expectEqual(@as(u128, 77), s.m.toU128().?);
    try std.testing.expectEqual(@as(u128, 54), s.k.toU128().?);
    try std.testing.expectEqual(@as(?u32, 5), s.get(7));
    try std.testing.expectEqual(@as(?u32, 10), s.get(11));
    try std.testing.expectEqual(PutResult.unchanged, try s.put(7, 5));
    // the canonical bytes of the 2-fact store
    var buf: [64]u8 = undefined;
    const n = try s.encode(&buf);
    const expect = [_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0, 0, 0, 1, 77, 0, 0, 0, 1, 54 };
    try std.testing.expectEqualSlices(u8, &expect, buf[0..n]);
    // delete both keys: back to the empty store, byte for byte
    try std.testing.expect(try s.del(7));
    try std.testing.expect(!(try s.del(7)));
    try std.testing.expectEqual(@as(u128, 11), s.m.toU128().?);
    try std.testing.expectEqual(@as(u128, 10), s.k.toU128().?);
    try std.testing.expect(try s.del(11));
    const empty = S.init();
    try std.testing.expect(s.eql(&empty));
    const n2 = try empty.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0 }, buf[0..n2]);
}

test "sunzi: rejects non-prime keys and oversized values" {
    var s = S.init();
    try std.testing.expectError(error.NotPrime, s.put(0, 0));
    try std.testing.expectError(error.NotPrime, s.put(1, 0));
    try std.testing.expectError(error.NotPrime, s.put(15, 1));
    try std.testing.expectError(error.NotPrime, s.put(4_294_967_295, 1));
    try std.testing.expectError(error.ValueTooLarge, s.put(7, 7));
    try std.testing.expectError(error.ValueTooLarge, s.put(2, 2));
    try std.testing.expectError(error.NotPrime, s.del(9));
    try std.testing.expect(!s.has(15));
    try std.testing.expectEqual(@as(?u32, null), s.get(15));
    _ = try s.put(3, 2);
    _ = try s.put(5, 4);
    // 15 divides M = 15, but 15 is not a key
    try std.testing.expect(!s.has(15));
    try std.testing.expect(s.has(3) and s.has(5));
    // value 0 is a real value, different from absence
    _ = try s.put(7, 0);
    try std.testing.expectEqual(@as(?u32, 0), s.get(7));
    try std.testing.expectEqual(@as(?u32, null), s.get(11));
}

test "sunzi: capacity exhaustion fails closed and leaves the store unchanged" {
    const Tiny = Store(8);
    var s = Tiny.init();
    var p: u32 = 2_000_000_000;
    var inserted: usize = 0;
    while (true) {
        p = primes.nextPrime(p + 1).?;
        const before = s;
        if (s.put(p, p / 3)) |_| {
            inserted += 1;
        } else |err| {
            try std.testing.expectEqual(error.Overflow, err);
            try std.testing.expect(s.eql(&before)); // unchanged
            break;
        }
        if (inserted > 20) return error.TestUnexpectedResult;
    }
    try std.testing.expect(inserted >= 3);
    // everything inserted before the failure is still readable
    var q: u32 = 2_000_000_000;
    var i: usize = 0;
    while (i < inserted) : (i += 1) {
        q = primes.nextPrime(q + 1).?;
        try std.testing.expectEqual(@as(?u32, q / 3), s.get(q));
    }
}

test "sunzi: canonical form - write order, history and construction route do not matter" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xC0FFEE);
    const n = 40;
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        // random key set and values
        var keys: [n]u32 = undefined;
        var vals: [n]u32 = undefined;
        var chosen: [n]usize = undefined;
        var c: usize = 0;
        while (c < n) {
            const idx: usize = @intCast(g.below(universe.len));
            var dup = false;
            for (chosen[0..c]) |x| {
                if (x == idx) dup = true;
            }
            if (dup) continue;
            chosen[c] = idx;
            keys[c] = universe[idx];
            vals[c] = @intCast(g.below(universe[idx]));
            c += 1;
        }
        const reference = try S.fromFacts(&keys, &vals);
        var ref_bytes: [2048]u8 = undefined;
        const ref_len = try reference.encode(&ref_bytes);

        // 24 random write orders
        var order: u32 = 0;
        while (order < 24) : (order += 1) {
            var idxs: [n]usize = undefined;
            for (&idxs, 0..) |*x, i| x.* = i;
            g.shuffle(usize, &idxs);
            var s = S.init();
            for (idxs) |i| _ = try s.put(keys[i], vals[i]);
            try std.testing.expect(s.eql(&reference));
            var bytes: [2048]u8 = undefined;
            const len = try s.encode(&bytes);
            try std.testing.expectEqualSlices(u8, ref_bytes[0..ref_len], bytes[0..len]);
        }

        // history independence: write garbage, overwrite, delete extras, converge to the same bytes
        var s = S.init();
        for (0..n) |i| _ = try s.put(keys[i], @intCast((vals[i] + 1) % keys[i])); // wrong values first
        var extra: usize = 0;
        while (extra < 15) : (extra += 1) {
            const p = universe[universe.len - 1 - extra]; // keys not in the chosen set (high primes)
            _ = try s.put(p, @intCast(g.below(p)));
        }
        for (0..n) |i| _ = try s.put(keys[i], vals[i]); // correct values
        extra = 0;
        while (extra < 15) : (extra += 1) _ = try s.del(universe[universe.len - 1 - extra]);
        try std.testing.expect(s.eql(&reference));

        // get agrees with the model for every key
        for (keys, vals) |p, v| try std.testing.expectEqual(@as(?u32, v), reference.get(p));
    }
}

test "sunzi: exhaustive bijection - every store on {2,3,5,7,11,13} is a distinct (M,K)" {
    const U = [_]u32{ 2, 3, 5, 7, 11, 13 };
    const stride: u32 = 30030; // product of U
    const SS = Store(8);
    const expected_states: usize = 3 * 4 * 6 * 8 * 12 * 14; // prod (p+1) = sigma(30030) = 96768
    const codes = try std.heap.page_allocator.alloc(u32, expected_states);
    defer std.heap.page_allocator.free(codes);
    var dig: [6]u32 = @splat(0);
    var count: usize = 0;
    while (true) {
        var s = SS.init();
        for (U, dig) |p, d| {
            if (d != 0) _ = try s.put(p, d - 1);
        }
        // every read agrees with the digits
        for (U, dig) |p, d| {
            const want: ?u32 = if (d == 0) null else d - 1;
            try std.testing.expectEqual(want, s.get(p));
        }
        const m: u32 = @intCast(s.m.toU128().?);
        const k: u32 = @intCast(s.k.toU128().?);
        try std.testing.expect(k < m and stride % m == 0);
        codes[count] = m * stride + k;
        count += 1;
        // odometer
        var i: usize = 0;
        var more = false;
        while (i < 6) : (i += 1) {
            dig[i] += 1;
            if (dig[i] <= U[i]) {
                more = true;
                break;
            }
            dig[i] = 0;
        }
        if (!more) break;
    }
    try std.testing.expectEqual(expected_states, count);
    std.mem.sort(u32, codes, {}, std.sort.asc(u32));
    var i: usize = 1;
    while (i < codes.len) : (i += 1) try std.testing.expect(codes[i - 1] != codes[i]);
    // Distinct and counted: the map {partial functions} -> {(M,K): M | 30030, 0 <= K < M}
    // is injective, and both sides have sigma(30030) = 96768 elements, so it is a bijection.
    var sigma: usize = 0;
    var d: u32 = 1;
    while (d <= stride) : (d += 1) {
        if (stride % d == 0) sigma += d;
    }
    try std.testing.expectEqual(expected_states, sigma);
}

test "sunzi: put then del restores the previous bytes exactly" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xDE1);
    var s = S.init();
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        const p = universe[@intCast(g.below(300))];
        const v: u32 = @intCast(g.below(p));
        const before = s;
        const was_present = s.has(p);
        const old = s.get(p);
        _ = try s.put(p, v);
        if (!was_present) {
            // a fresh key: deleting it is the exact inverse
            _ = try s.del(p);
            try std.testing.expect(s.eql(&before));
            _ = try s.put(p, v); // keep it for the next rounds
        } else {
            // an overwrite: putting the old value back is the exact inverse
            _ = try s.put(p, old.?);
            try std.testing.expect(s.eql(&before));
            _ = try s.put(p, v);
        }
    }
}

test "sunzi: every divisor of M is a view, and a view is a reduction (exhaustive on {2,3,5,7})" {
    const U = [_]u32{ 2, 3, 5, 7 };
    const SS = Store(8);
    var dig: [4]u32 = @splat(0);
    var views_checked: usize = 0;
    while (true) {
        var full = SS.init();
        var keys: [4]u32 = undefined;
        var vals: [4]u32 = undefined;
        var nk: usize = 0;
        for (U, dig) |p, d| {
            if (d != 0) {
                _ = try full.put(p, d - 1);
                keys[nk] = p;
                vals[nk] = d - 1;
                nk += 1;
            }
        }
        // every subset of the present keys
        var mask: usize = 0;
        while (mask < (@as(usize, 1) << @intCast(nk))) : (mask += 1) {
            var sk: [4]u32 = undefined;
            var sv: [4]u32 = undefined;
            var ns: usize = 0;
            for (0..nk) |i| {
                if (mask & (@as(usize, 1) << @intCast(i)) != 0) {
                    sk[ns] = keys[i];
                    sv[ns] = vals[i];
                    ns += 1;
                }
            }
            const view = try full.viewKeys(sk[0..ns]);
            const built = try buildByPuts(SS, sk[0..ns], sv[0..ns]);
            try std.testing.expect(view.eql(&built));
            views_checked += 1;
        }
        var i: usize = 0;
        var more = false;
        while (i < 4) : (i += 1) {
            dig[i] += 1;
            if (dig[i] <= U[i]) {
                more = true;
                break;
            }
            dig[i] = 0;
        }
        if (!more) break;
    }
    // prod (1 + 2p) over p in {2,3,5,7}
    try std.testing.expectEqual(@as(usize, 5 * 7 * 11 * 15), views_checked);
}

test "sunzi: views of a large store, divisors that are not divisors are refused" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0x71E);
    var keys: [100]u32 = undefined;
    var vals: [100]u32 = undefined;
    for (0..100) |i| {
        keys[i] = universe[i * 7 + 3]; // distinct
        vals[i] = @intCast(g.below(keys[i]));
    }
    const full = try buildByPuts(S, &keys, &vals);
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var idxs: [100]usize = undefined;
        for (&idxs, 0..) |*x, i| x.* = i;
        g.shuffle(usize, &idxs);
        const take: usize = 1 + @as(usize, @intCast(g.below(99)));
        var sk: [100]u32 = undefined;
        var sv: [100]u32 = undefined;
        for (0..take) |i| {
            sk[i] = keys[idxs[i]];
            sv[i] = vals[idxs[i]];
        }
        const view = try full.viewKeys(sk[0..take]);
        const built = try buildByPuts(S, sk[0..take], sv[0..take]);
        try std.testing.expect(view.eql(&built));
    }
    // 2 is not a key (keys start at universe[3] = 7)
    try std.testing.expectError(error.NotFound, full.viewKeys(&[_]u32{ keys[0], 2 }));
    // 6 does not divide M
    const six = S.Num.fromU64(6);
    try std.testing.expectError(error.NotADivisor, full.viewDivisor(&six));
    const zero = S.Num.init();
    try std.testing.expectError(error.NotADivisor, full.viewDivisor(&zero));
}

test "sunzi: diff by gcd equals the brute-force comparison for ALL ordered pairs on {2,3,5,7}" {
    const U = [_]u32{ 2, 3, 5, 7 };
    const SS = Store(8);
    const N: usize = 3 * 4 * 6 * 8; // 576 stores
    var stores: [N]SS = undefined;
    var digs: [N][4]u32 = undefined;
    var dig: [4]u32 = @splat(0);
    var n: usize = 0;
    while (true) {
        var s = SS.init();
        for (U, dig) |p, d| {
            if (d != 0) _ = try s.put(p, d - 1);
        }
        stores[n] = s;
        digs[n] = dig;
        n += 1;
        var i: usize = 0;
        var more = false;
        while (i < 4) : (i += 1) {
            dig[i] += 1;
            if (dig[i] <= U[i]) {
                more = true;
                break;
            }
            dig[i] = 0;
        }
        if (!more) break;
    }
    try std.testing.expectEqual(N, n);
    var pairs: usize = 0;
    for (0..N) |ia| {
        for (0..N) |ib| {
            var shared: u64 = 1;
            var agree: u64 = 1;
            var conflict: u64 = 1;
            var only_a: u64 = 1;
            var only_b: u64 = 1;
            for (U, 0..) |p, j| {
                const da = digs[ia][j];
                const db = digs[ib][j];
                if (da != 0 and db != 0) {
                    shared *= p;
                    if (da == db) agree *= p else conflict *= p;
                } else if (da != 0) {
                    only_a *= p;
                } else if (db != 0) {
                    only_b *= p;
                }
            }
            const d = stores[ia].diff(&stores[ib]);
            try std.testing.expectEqual(@as(u128, shared), d.shared.toU128().?);
            try std.testing.expectEqual(@as(u128, agree), d.agree.toU128().?);
            try std.testing.expectEqual(@as(u128, conflict), d.conflict.toU128().?);
            try std.testing.expectEqual(@as(u128, only_a), d.only_a.toU128().?);
            try std.testing.expectEqual(@as(u128, only_b), d.only_b.toU128().?);
            try std.testing.expectEqual(conflict == 1, stores[ia].consistent(&stores[ib]));
            pairs += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 576 * 576), pairs);
}

test "sunzi: diff finds exactly the planted conflicts in two 150-fact stores; merge is order independent" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xD1FF);
    const total = 200;
    var ka: [total]u32 = undefined;
    var va: [total]u32 = undefined;
    var kb: [total]u32 = undefined;
    var vb: [total]u32 = undefined;
    // a holds universe[0..150); b holds universe[50..200): 100 shared keys
    for (0..150) |i| {
        ka[i] = universe[100 + i];
        va[i] = @intCast(g.below(ka[i]));
    }
    for (0..150) |i| {
        kb[i] = universe[150 + i];
        vb[i] = if (150 + i < 250) va[50 + i] else @intCast(g.below(kb[i]));
    }
    // shared keys are universe[150..250); plant 7 conflicts among them
    const planted = [_]usize{ 3, 17, 29, 41, 55, 76, 99 }; // indices into the shared range
    var expect_conflict: u128 = 1;
    for (planted) |idx| {
        const bi = idx; // kb[idx] = universe[150+idx]
        vb[bi] = (vb[bi] + 1 + @as(u32, @intCast(g.below(kb[bi] - 1)))) % kb[bi];
        try std.testing.expect(vb[bi] != va[50 + idx]);
        // build the expected product with exact arithmetic below
    }
    const a = try buildByPuts(S, ka[0..150], va[0..150]);
    const b = try buildByPuts(S, kb[0..150], vb[0..150]);
    const d = a.diff(&b);
    var want_conflict = S.Num.fromU64(1);
    for (planted) |idx| try want_conflict.mulSmall(kb[idx]);
    try std.testing.expect(d.conflict.eql(&want_conflict));
    var want_shared = S.Num.fromU64(1);
    for (0..100) |i| try want_shared.mulSmall(universe[150 + i]);
    try std.testing.expect(d.shared.eql(&want_shared));
    try std.testing.expect(!a.consistent(&b));
    _ = &expect_conflict;

    // the conflicting keys, recovered from the product by trial division
    var found: [16]u32 = undefined;
    const nf = blk: {
        var tmp = S.init();
        tmp.m.copyFrom(&d.conflict);
        break :blk try tmp.keysInto(universe, &found);
    };
    try std.testing.expectEqual(planted.len, nf);
    for (planted, 0..) |idx, i| try std.testing.expectEqual(kb[idx], found[i]);

    // repair b on the planted keys; now the stores are consistent and the union is unique
    var b2 = b;
    for (planted) |idx| _ = try b2.put(kb[idx], va[50 + idx]);
    try std.testing.expect(a.consistent(&b2));
    const d2 = a.diff(&b2);
    try std.testing.expect(d2.conflict.isOne());
    try std.testing.expect(d2.agree.eql(&d2.shared));

    // union built both ways round is the same pair of integers
    var ab = a;
    var ba = b2;
    var buf_a: [160]u32 = undefined;
    var buf_b: [160]u32 = undefined;
    const na = try a.keysInto(universe, &buf_a);
    const nb = try b2.keysInto(universe, &buf_b);
    for (buf_b[0..nb]) |p| _ = try ab.put(p, b2.get(p).?);
    for (buf_a[0..na]) |p| _ = try ba.put(p, a.get(p).?);
    try std.testing.expect(ab.eql(&ba));
    // and equals the direct construction from the 250-key union
    var uk: [250]u32 = undefined;
    var uv: [250]u32 = undefined;
    var nu: usize = 0;
    for (buf_a[0..na]) |p| {
        uk[nu] = p;
        uv[nu] = a.get(p).?;
        nu += 1;
    }
    for (buf_b[0..nb]) |p| {
        if (!a.has(p)) {
            uk[nu] = p;
            uv[nu] = b2.get(p).?;
            nu += 1;
        }
    }
    const direct = try S.fromFacts(uk[0..nu], uv[0..nu]);
    try std.testing.expect(ab.eql(&direct));
    try std.testing.expectEqual(@as(usize, 200), nu);
}

test "sunzi: time travel - in an append-only history every past state is a reduction of the present" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0x71AE);
    const n = 60;
    var order: [n]u32 = undefined;
    var vals: [n]u32 = undefined;
    for (0..n) |i| {
        order[i] = universe[10 + 3 * i];
        vals[i] = @intCast(g.below(order[i]));
    }
    g.shuffle(u32, &order);
    for (0..n) |i| vals[i] = @intCast(g.below(order[i]));
    var snapshots: [n + 1]S = undefined;
    var s = S.init();
    snapshots[0] = s;
    for (0..n) |i| {
        _ = try s.put(order[i], vals[i]);
        snapshots[i + 1] = s;
    }
    // the divisor chain 1 | M_1 | M_2 | ... | M_n
    var m_t = S.Num.fromU64(1);
    for (0..n + 1) |t| {
        if (t > 0) try m_t.mulSmall(order[t - 1]);
        const past = try s.viewDivisor(&m_t);
        try std.testing.expect(past.eql(&snapshots[t]));
    }
}

test "sunzi: canonical bytes round-trip and strict rejection" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xB17E);
    var buf: [4096]u8 = undefined;
    var round: usize = 0;
    while (round < 40) : (round += 1) {
        var s = S.init();
        const n = g.below(60);
        var j: u64 = 0;
        while (j < n) : (j += 1) {
            const p = universe[@intCast(g.below(universe.len))];
            _ = try s.put(p, @intCast(g.below(p)));
        }
        const len = try s.encode(&buf);
        try std.testing.expectEqual(s.encodedLen(), len);
        const back = try S.decode(buf[0..len]);
        try std.testing.expect(back.eql(&s));
        try s.verify(universe);
    }
    // targeted corruptions of the 2-fact store (M = 77, K = 54)
    var s = S.init();
    _ = try s.put(7, 5);
    _ = try s.put(11, 10);
    const len = try s.encode(&buf);
    const good = buf[0..len];
    _ = try S.decode(good);
    var bad: [64]u8 = undefined;
    // wrong magic
    @memcpy(bad[0..len], good);
    bad[0] ^= 1;
    try std.testing.expectError(error.Malformed, S.decode(bad[0..len]));
    // truncated and extended
    try std.testing.expectError(error.Malformed, S.decode(good[0 .. len - 1]));
    @memcpy(bad[0..len], good);
    bad[len] = 0;
    try std.testing.expectError(error.Malformed, S.decode(bad[0 .. len + 1]));
    // K >= M: K = 77 (0x4D) is not smaller than M = 77
    @memcpy(bad[0..len], good);
    bad[len - 1] = 77;
    try std.testing.expectError(error.Malformed, S.decode(bad[0..len]));
    // leading zero byte in M (length 2, bytes 00 4D)
    const lead = [_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0, 0, 0, 2, 0, 77, 0, 0, 0, 1, 54 };
    try std.testing.expectError(error.Malformed, S.decode(&lead));
    // zero-length M
    const zm = [_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, S.decode(&zm));
    // a number that is valid as bytes but is not a product of distinct primes is caught by verify()
    var evil = S.init();
    evil.m.setU64(7 * 7 * 11);
    evil.k.setU64(3);
    var pb2: [4300]u32 = undefined;
    try std.testing.expectError(error.Malformed, evil.verify(smallPrimes(&pb2)));
    // ... and a factor outside the universe
    evil.m.setU64(7 * 40009); // 40009 is prime and > 40000
    try std.testing.expectError(error.IncompleteUniverse, evil.verify(smallPrimes(&pb2)));
}

test "sunzi: enumeration is verified by recomposition" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var s = S.init();
    var out: [32]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try s.keysInto(universe, &out));
    _ = try s.put(13, 1);
    _ = try s.put(2, 1);
    _ = try s.put(40_009 - 0, 5); // outside the universe (largest sieved prime is 39989)
    try std.testing.expectError(error.IncompleteUniverse, s.keysInto(universe, &out));
    _ = try s.del(40_009);
    const n = try s.keysInto(universe, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 2), out[0]);
    try std.testing.expectEqual(@as(u32, 13), out[1]);
    var tiny: [1]u32 = undefined;
    try std.testing.expectError(error.Overflow, s.keysInto(universe, &tiny));
}

test "sunzi: no locality - one flipped bit of K changes the value of every odd key" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xF11B);
    var keys: [120]u32 = undefined;
    var vals: [120]u32 = undefined;
    for (0..120) |i| {
        keys[i] = universe[1 + 5 * i]; // odd primes only
        vals[i] = @intCast(g.below(keys[i]));
    }
    const s = try buildByPuts(S, &keys, &vals);
    const kbits = s.k.bitLen();
    var flips: usize = 0;
    var bit: usize = 0;
    while (bit < kbits) : (bit += 1) {
        var t = s;
        t.k.limbs[bit / 32] ^= @as(u32, 1) << @intCast(bit % 32);
        t.k.trim();
        var changed: usize = 0;
        for (keys, vals) |p, v| {
            if (t.k.modSmall(p) != v) changed += 1;
        }
        // delta = +-2^bit is a unit modulo every odd prime, so it never maps a value to itself
        try std.testing.expectEqual(@as(usize, 120), changed);
        flips += 1;
    }
    try std.testing.expect(flips > 1000);
    // the single exception is the key 2: its value only sees bit 0
    var t2 = S.init();
    _ = try t2.put(2, 1);
    _ = try t2.put(3, 2);
    var u = t2;
    u.k.limbs[0] ^= 2; // flip bit 1
    try std.testing.expectEqual(t2.k.modSmall(2), u.k.modSmall(2));
}

fn runScenario(seed: u64, universe: []const u32) !S {
    var g = rng_mod.SplitMix64.init(seed);
    var s = S.init();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const p = universe[@intCast(g.below(600))];
        if (g.below(10) < 7) {
            _ = try s.put(p, @intCast(g.below(p)));
        } else {
            _ = try s.del(p);
        }
    }
    return s;
}

test "sunzi: golden digest - the bytes are a pure function of the fact set (fixed across compilers)" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    const s = try runScenario(0x5EEDF00D, universe);
    var buf: [4096]u8 = undefined;
    const len = try s.encode(&buf);
    const digest = fnv1a64(buf[0..len]);
    std.debug.print("\n[golden] scenario 0x5EEDF00D: {d} bytes, M has {d} bits, K has {d} bits, fnv1a64 = 0x{x:0>16}\n", .{ len, s.m.bitLen(), s.k.bitLen(), digest });
    // Pinned after running the identical scenario on Zig 0.14.1, 0.15.2, 0.16.0 and 0.17.0
    // in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall: all sixteen builds print this value.
    try std.testing.expectEqual(@as(u64, 0x6e5e8b941866bdef), digest);
}

fn nowNs() ?u64 {
    if (@hasDecl(std.time, "nanoTimestamp")) {
        const t = std.time.nanoTimestamp();
        return @intCast(t);
    }
    return null;
}

test "sunzi: exhaustive write rule - put (every value) and del on every store of {2,3,5,7}, checked against direct CRT" {
    const U = [_]u32{ 2, 3, 5, 7 };
    const SS = Store(8);
    var dig: [4]u32 = @splat(0);
    var cases: usize = 0;
    while (true) {
        var base = SS.init();
        for (U, dig) |p, d| {
            if (d != 0) _ = try base.put(p, d - 1);
        }
        for (U, 0..) |p, j| {
            var v: u32 = 0;
            while (v < p) : (v += 1) {
                var s = base;
                _ = try s.put(p, v);
                var want = dig;
                want[j] = v + 1;
                var ks: [4]u32 = undefined;
                var vs: [4]u32 = undefined;
                var n: usize = 0;
                for (U, want) |q, d| {
                    if (d != 0) {
                        ks[n] = q;
                        vs[n] = d - 1;
                        n += 1;
                    }
                }
                const expect = try SS.fromFacts(ks[0..n], vs[0..n]);
                try std.testing.expect(s.eql(&expect));
                cases += 1;
            }
            var s = base;
            try std.testing.expectEqual(dig[j] != 0, try s.del(p));
            var want = dig;
            want[j] = 0;
            var ks: [4]u32 = undefined;
            var vs: [4]u32 = undefined;
            var n: usize = 0;
            for (U, want) |q, d| {
                if (d != 0) {
                    ks[n] = q;
                    vs[n] = d - 1;
                    n += 1;
                }
            }
            const expect = try SS.fromFacts(ks[0..n], vs[0..n]);
            try std.testing.expect(s.eql(&expect));
            cases += 1;
        }
        var i: usize = 0;
        var more = false;
        while (i < 4) : (i += 1) {
            dig[i] += 1;
            if (dig[i] <= U[i]) {
                more = true;
                break;
            }
            dig[i] = 0;
        }
        if (!more) break;
    }
    try std.testing.expectEqual(@as(usize, 576 * (17 + 4)), cases);
}

test "sunzi: differential fuzz against a plain array model (20000 operations)" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xF022);
    const K = 150;
    var present: [K]bool = @splat(false);
    var value: [K]u32 = @splat(0);
    var s = S.init();
    var ops: usize = 0;
    while (ops < 20_000) : (ops += 1) {
        const i: usize = @intCast(g.below(K));
        const p = universe[20 + i];
        switch (g.below(6)) {
            0, 1, 2 => {
                const v: u32 = @intCast(g.below(p));
                const r = try s.put(p, v);
                const want: PutResult = if (!present[i]) .inserted else if (value[i] == v) .unchanged else .updated;
                try std.testing.expectEqual(want, r);
                present[i] = true;
                value[i] = v;
            },
            3 => {
                try std.testing.expectEqual(present[i], try s.del(p));
                present[i] = false;
            },
            else => {
                const want: ?u32 = if (present[i]) value[i] else null;
                try std.testing.expectEqual(want, s.get(p));
                try std.testing.expectEqual(present[i], s.has(p));
            },
        }
        if (ops % 500 == 499) {
            var ks: [K]u32 = undefined;
            var vs: [K]u32 = undefined;
            var n: usize = 0;
            for (0..K) |j| {
                const q = universe[20 + j];
                const want: ?u32 = if (present[j]) value[j] else null;
                try std.testing.expectEqual(want, s.get(q));
                if (present[j]) {
                    ks[n] = q;
                    vs[n] = value[j];
                    n += 1;
                }
            }
            // canonical form under random operations: equals the direct construction
            const direct = try S.fromFacts(ks[0..n], vs[0..n]);
            try std.testing.expect(s.eql(&direct));
        }
    }
}

test "sunzi: keys at the top of the u32 range" {
    const SS = Store(64);
    var tops: [6]u32 = undefined;
    var c: u64 = 4_294_967_295;
    var n: usize = 0;
    while (n < tops.len) : (c -= 1) {
        if (primes.isPrime(@intCast(c))) {
            tops[n] = @intCast(c);
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 4_294_967_291), tops[0]);
    var s = SS.init();
    for (tops) |p| _ = try s.put(p, p - 1); // largest legal value
    for (tops) |p| try std.testing.expectEqual(@as(?u32, p - 1), s.get(p));
    for (tops, 0..) |p, i| _ = try s.put(p, @intCast(i * 1_000_003)); // overwrite
    for (tops, 0..) |p, i| try std.testing.expectEqual(@as(?u32, @intCast(i * 1_000_003)), s.get(p));
    var vals: [6]u32 = undefined;
    for (&vals, 0..) |*v, i| v.* = @intCast(i * 1_000_003);
    const direct = try SS.fromFacts(&tops, &vals);
    try std.testing.expect(s.eql(&direct));
    var buf: [128]u8 = undefined;
    const len = try s.encode(&buf);
    const back = try SS.decode(buf[0..len]);
    try std.testing.expect(back.eql(&s));
    for (tops) |p| try std.testing.expect(try s.del(p));
    const empty = SS.init();
    try std.testing.expect(s.eql(&empty));
}

test "sunzi: 400 facts under 29-bit primes - write orders agree with each other and with direct CRT" {
    const SS = Store(1024);
    var g = rng_mod.SplitMix64.init(0x29B17);
    const n = 400;
    var keys: [n]u32 = undefined;
    var vals: [n]u32 = undefined;
    var p: u32 = 1 << 28;
    for (0..n) |i| {
        p = primes.nextPrime(p + 1 + @as(u32, @intCast(g.below(5000)))).?;
        keys[i] = p;
        vals[i] = @intCast(g.below(1 << 24));
    }
    const direct = try SS.fromFacts(&keys, &vals);
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        var idxs: [n]usize = undefined;
        for (&idxs, 0..) |*x, i| x.* = i;
        g.shuffle(usize, &idxs);
        var s = SS.init();
        for (idxs) |i| _ = try s.put(keys[i], vals[i]);
        try std.testing.expect(s.eql(&direct));
    }
    // reading every fact back, then removing them in a third order and arriving at the empty store
    for (keys, vals) |q, v| try std.testing.expectEqual(@as(?u32, v), direct.get(q));
    var s = direct;
    var idxs: [n]usize = undefined;
    for (&idxs, 0..) |*x, i| x.* = i;
    g.shuffle(usize, &idxs);
    for (idxs) |i| try std.testing.expect(try s.del(keys[i]));
    const empty = SS.init();
    try std.testing.expect(s.eql(&empty));
}

test "sunzi: diff is symmetric and agrees with its own repair" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0x5E77);
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var a = S.init();
        var b = S.init();
        for (0..80) |_| {
            const p = universe[@intCast(g.below(300))];
            const v: u32 = @intCast(g.below(p));
            switch (g.below(3)) {
                0 => _ = try a.put(p, v),
                1 => _ = try b.put(p, v),
                else => {
                    _ = try a.put(p, v);
                    _ = try b.put(p, if (g.below(4) == 0) @as(u32, @intCast((v + 1) % p)) else v);
                },
            }
        }
        const ab = a.diff(&b);
        const ba = b.diff(&a);
        try std.testing.expect(ab.shared.eql(&ba.shared));
        try std.testing.expect(ab.agree.eql(&ba.agree));
        try std.testing.expect(ab.conflict.eql(&ba.conflict));
        try std.testing.expect(ab.only_a.eql(&ba.only_b));
        try std.testing.expect(ab.only_b.eql(&ba.only_a));
        // a diff of a store with itself has no conflict and agrees on everything
        const aa = a.diff(&a);
        try std.testing.expect(aa.conflict.isOne());
        try std.testing.expect(aa.shared.eql(&a.m));
        try std.testing.expect(aa.only_a.isOne() and aa.only_b.isOne());
    }
}

test "sunzi: measured size and cost (prints; asserts only structural facts)" {
    const SS = Store(2048);
    var g = rng_mod.SplitMix64.init(0x3EA5);
    const sizes = [_]usize{ 250, 500, 1000, 1500 };
    std.debug.print("\n[measure] 30-bit prime keys, 20-bit values, Store(2048)\n", .{});
    for (sizes) |n| {
        var keys: [1500]u32 = undefined;
        var vals: [1500]u32 = undefined;
        var p: u32 = 1 << 29;
        for (0..n) |i| {
            p = primes.nextPrime(p + 1 + @as(u32, @intCast(g.below(3000)))).?;
            keys[i] = p;
            vals[i] = @intCast(g.below(1 << 20));
        }
        var s = SS.init();
        const t0 = nowNs();
        for (0..n) |i| _ = try s.put(keys[i], vals[i]);
        const t1 = nowNs();
        var acc: u64 = 0;
        for (0..n) |i| acc +%= s.get(keys[i]).?;
        const t2 = nowNs();
        // structural facts that hold on every machine
        try std.testing.expect(s.k.cmp(&s.m) == .lt);
        const mbits = s.m.bitLen();
        const kbits = s.k.bitLen();
        try std.testing.expect(mbits >= 29 * n and mbits <= 30 * n);
        std.debug.print("[measure] n={d:>5}: M={d:>6} bits, K={d:>6} bits, {d:.1} bits/fact, {d} bytes encoded, {d} limbs per read pass", .{ n, mbits, kbits, @as(f64, @floatFromInt(mbits + kbits)) / @as(f64, @floatFromInt(n)), s.encodedLen(), s.m.len });
        if (t0 != null and t1 != null and t2 != null) {
            std.debug.print("  | build {d} us total ({d} ns/put avg), {d} ns/get avg (checksum {d})\n", .{ (t1.? - t0.?) / 1000, (t1.? - t0.?) / n, (t2.? - t1.?) / n, acc & 0xff });
        } else {
            std.debug.print("  | (no timer in this Zig's std.time; checksum {d})\n", .{acc & 0xff});
        }
    }
}

test "sunzi: a store whose M repeats a prime is refused by put (garbage in, error out)" {
    var evil = S.init();
    evil.m.setU64(7 * 7 * 11);
    evil.k.setU64(3);
    try std.testing.expectError(error.Malformed, evil.put(7, 1));
}

test "sunzi: the seal is a fact - it detects corruption, and a sealed store is still canonical" {
    var g = rng_mod.SplitMix64.init(0x5EA1);
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    const n = 60;
    var keys: [n]u32 = undefined;
    var vals: [n]u32 = undefined;
    for (0..n) |i| {
        keys[i] = universe[i * 5 + 1];
        vals[i] = @intCast(g.below(keys[i]));
    }
    var s = try buildByPuts(S, &keys, &vals);
    try std.testing.expect(!s.sealIsValid()); // no seal yet
    try s.seal();
    try std.testing.expect(s.sealIsValid());
    try std.testing.expect(s.has(S.seal_key));
    // the seal is an ordinary fact: the other values are untouched
    for (keys, vals) |p, v| try std.testing.expectEqual(@as(?u32, v), s.get(p));
    // sealing again changes nothing
    const once = s;
    try s.seal();
    try std.testing.expect(s.eql(&once));
    // canonical: the same facts written in another order, then sealed, give the same integers
    var idxs: [n]usize = undefined;
    for (&idxs, 0..) |*x, i| x.* = i;
    g.shuffle(usize, &idxs);
    var s2 = S.init();
    for (idxs) |i| _ = try s2.put(keys[i], vals[i]);
    try s2.seal();
    try std.testing.expect(s2.eql(&s));
    // a later write makes the seal stale; resealing repairs it
    var s3 = s;
    _ = try s3.put(universe[700], 1);
    try std.testing.expect(!s3.sealIsValid());
    try s3.seal();
    try std.testing.expect(s3.sealIsValid());
    // deleting the seal key un-seals
    var s4 = s;
    try std.testing.expect(try s4.del(S.seal_key));
    try std.testing.expect(!s4.sealIsValid());

    // corruption: flip every single bit of K, one at a time - none may pass
    const kbits = s.k.bitLen();
    var bit: usize = 0;
    while (bit < kbits) : (bit += 1) {
        var t = s;
        t.k.limbs[bit / 32] ^= @as(u32, 1) << @intCast(bit % 32);
        t.k.trim();
        try std.testing.expect(!t.sealIsValid());
    }
    // ... and flip bits of M (this changes the key set; the seal key stops dividing M)
    const mbits = s.m.bitLen();
    var mb: usize = 0;
    while (mb < mbits) : (mb += 7) {
        var t = s;
        t.m.limbs[mb / 32] ^= @as(u32, 1) << @intCast(mb % 32);
        t.m.trim();
        try std.testing.expect(!t.sealIsValid());
    }
    std.debug.print("\n[seal] {d} single-bit flips of K and {d} of M: all detected (digest is 32-bit, non-cryptographic)\n", .{ kbits, (mbits + 6) / 7 });
}

test "sunzi: write amplification - a put changes essentially every limb of K (measured)" {
    const SS = Store(1024);
    var g = rng_mod.SplitMix64.init(0xA3F1);
    const n = 300;
    var keys: [n + 100]u32 = undefined;
    var p: u32 = 1 << 28;
    for (0..n + 100) |i| {
        p = primes.nextPrime(p + 1 + @as(u32, @intCast(g.below(4000)))).?;
        keys[i] = p;
    }
    var s = SS.init();
    for (0..n) |i| _ = try s.put(keys[i], @intCast(g.below(keys[i])));
    var changed: usize = 0;
    var total: usize = 0;
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        const before = s;
        if (round % 2 == 0) {
            _ = try s.put(keys[n + round / 2], @intCast(g.below(keys[n + round / 2]))); // new key
        } else {
            const i: usize = @intCast(g.below(n));
            _ = try s.put(keys[i], @intCast((g.below(keys[i] - 1) + 1 + (before.get(keys[i]).?)) % keys[i])); // overwrite
        }
        const len = @max(before.k.len, s.k.len);
        var l: usize = 0;
        while (l < len) : (l += 1) {
            const a: u32 = if (l < before.k.len) before.k.limbs[l] else 0;
            const b: u32 = if (l < s.k.len) s.k.limbs[l] else 0;
            if (a != b) changed += 1;
            total += 1;
        }
    }
    const frac = @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(total));
    std.debug.print("\n[amplification] 100 puts into a {d}-fact store: {d:.4} of K's limbs changed per write on average\n", .{ n, frac });
    try std.testing.expect(frac > 0.99);
}

test "sunzi: enumeration costs one pass over M per universe prime scanned (measured, universe = first 4203 primes)" {
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xE17);
    var s = S.init();
    var top: usize = 0;
    for (0..150) |_| {
        const idx: usize = @intCast(g.below(universe.len));
        _ = try s.put(universe[idx], @intCast(g.below(universe[idx])));
        top = @max(top, idx);
    }
    var out: [200]u32 = undefined;
    const t0 = nowNs();
    const n = try s.keysInto(universe, &out);
    const t1 = nowNs();
    // the scan stops as soon as M is fully factored: it visits exactly top+1 primes
    std.debug.print("\n[enumerate] {d} keys, M has {d} limbs, scanned {d} universe primes", .{ n, s.m.len, top + 1 });
    if (t0 != null and t1 != null) std.debug.print(" in {d} us ({d} ns per prime)\n", .{ (t1.? - t0.?) / 1000, (t1.? - t0.?) / (top + 1) }) else std.debug.print("\n", .{});
    try std.testing.expect(n > 100);
}

test "sunzi: hostile length fields are Malformed, never a crash (also on 32-bit usize)" {
    // M length 0xFFFFFFFF, K length absent
    const huge_m = [_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 7, 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, S.decode(&huge_m));
    // valid M, K length 0xFFFFFFFF
    const huge_k = [_]u8{ 'S', 'U', 'N', 'Z', 'I', 0, 0, 1, 0, 0, 0, 1, 7, 0xFF, 0xFF, 0xFF, 0xFF, 3 };
    try std.testing.expectError(error.Malformed, S.decode(&huge_k));
    // M length that fits the buffer but not the capacity of the store type
    var big_m: [8 + 4 + 2000 + 4]u8 = undefined;
    @memcpy(big_m[0..8], &magic);
    putU32(big_m[8..12], 2000);
    @memset(big_m[12 .. 12 + 2000], 0xFF);
    putU32(big_m[12 + 2000 ..][0..4], 0);
    const Small = Store(16);
    try std.testing.expectError(error.Overflow, Small.decode(&big_m));
}

test "sunzi: glue - the 4-prime universe, every ordered pair: union when consistent, Conflict otherwise" {
    const U = [_]u32{ 2, 3, 5, 7 };
    const SS = Store(16);
    const N: usize = 3 * 4 * 6 * 8;
    var stores: [N]SS = undefined;
    var digs: [N][4]u32 = undefined;
    var dig: [4]u32 = @splat(0);
    var n: usize = 0;
    while (true) {
        var s = SS.init();
        for (U, dig) |p, d| {
            if (d != 0) _ = try s.put(p, d - 1);
        }
        stores[n] = s;
        digs[n] = dig;
        n += 1;
        var i: usize = 0;
        var more = false;
        while (i < 4) : (i += 1) {
            dig[i] += 1;
            if (dig[i] <= U[i]) {
                more = true;
                break;
            }
            dig[i] = 0;
        }
        if (!more) break;
    }
    var glued: usize = 0;
    var refused: usize = 0;
    for (0..N) |ia| {
        for (0..N) |ib| {
            // oracle: union of the two digit vectors, or a conflict
            var union_dig: [4]u32 = undefined;
            var conflict = false;
            for (0..4) |j| {
                const da = digs[ia][j];
                const db = digs[ib][j];
                if (da != 0 and db != 0 and da != db) conflict = true;
                union_dig[j] = if (da != 0) da else db;
            }
            if (conflict) {
                try std.testing.expectError(error.Conflict, stores[ia].glue(&stores[ib]));
                refused += 1;
                continue;
            }
            var ks: [4]u32 = undefined;
            var vs: [4]u32 = undefined;
            var m: usize = 0;
            for (U, union_dig) |p, d| {
                if (d != 0) {
                    ks[m] = p;
                    vs[m] = d - 1;
                    m += 1;
                }
            }
            const expect = try SS.fromFacts(ks[0..m], vs[0..m]);
            const g = try stores[ia].glue(&stores[ib]);
            try std.testing.expect(g.eql(&expect));
            // commutative
            const g2 = try stores[ib].glue(&stores[ia]);
            try std.testing.expect(g.eql(&g2));
            glued += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 576 * 576), glued + refused);
    // idempotent
    for (0..N) |i| {
        const g = try stores[i].glue(&stores[i]);
        try std.testing.expect(g.eql(&stores[i]));
    }
    std.debug.print("\n[glue] 331776 ordered pairs on {{2,3,5,7}}: {d} glued (each equal to the union, each commutative), {d} refused as conflicting\n", .{ glued, refused });
}

test "sunzi: glue laws on large stores - views glue back, order is irrelevant, restriction recovers the parts" {
    const SS = Store(512);
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0x61E);
    const n = 300;
    var keys: [n]u32 = undefined;
    var vals: [n]u32 = undefined;
    for (0..n) |i| {
        keys[i] = universe[i * 3 + 2];
        vals[i] = @intCast(g.below(keys[i]));
    }
    const whole = try buildByPuts(SS, &keys, &vals);
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        // three overlapping random subsets that together cover everything
        var sub: [3][n]bool = undefined;
        for (0..n) |i| {
            const cover = g.below(3);
            for (0..3) |s| sub[s][i] = (s == cover) or g.below(3) == 0;
        }
        var parts: [3]SS = undefined;
        for (0..3) |s| {
            var ks: [n]u32 = undefined;
            var m: usize = 0;
            for (0..n) |i| {
                if (sub[s][i]) {
                    ks[m] = keys[i];
                    m += 1;
                }
            }
            parts[s] = try whole.viewKeys(ks[0..m]);
        }
        // every association and order gives the same integers, and they are the whole store
        const ab = try parts[0].glue(&parts[1]);
        const ab_c = try ab.glue(&parts[2]);
        const bc = try parts[1].glue(&parts[2]);
        const a_bc = try parts[0].glue(&bc);
        const ca = try parts[2].glue(&parts[0]);
        const ca_b = try ca.glue(&parts[1]);
        try std.testing.expect(ab_c.eql(&a_bc));
        try std.testing.expect(ab_c.eql(&ca_b));
        try std.testing.expect(ab_c.eql(&whole));
        // restriction recovers each part exactly
        for (0..3) |s| {
            const back = try ab_c.viewDivisor(&parts[s].m);
            try std.testing.expect(back.eql(&parts[s]));
        }
        // gluing a part into the whole changes nothing (absorption)
        const w2 = try whole.glue(&parts[1]);
        try std.testing.expect(w2.eql(&whole));
    }
}

test "sunzi: glue reports a conflict between two big stores, and the conflict is the diff's" {
    const SS = Store(512);
    var pbuf: [4300]u32 = undefined;
    const universe = smallPrimes(&pbuf);
    var g = rng_mod.SplitMix64.init(0xC0F1);
    var a = SS.init();
    var b = SS.init();
    for (0..200) |i| {
        const p = universe[i + 10];
        const v: u32 = @intCast(g.below(p));
        if (i < 140) _ = try a.put(p, v);
        if (i >= 60) _ = try b.put(p, if (i == 100 or i == 120) @as(u32, @intCast((v + 1) % p)) else v);
    }
    try std.testing.expectError(error.Conflict, a.glue(&b));
    try std.testing.expect(!a.consistent(&b));
    // repair the two disagreeing keys in b, then it glues
    _ = try b.put(universe[110], a.get(universe[110]).?);
    _ = try b.put(universe[130], a.get(universe[130]).?);
    try std.testing.expect(a.consistent(&b));
    const merged = try a.glue(&b);
    // equals the union built the slow way
    var ks: [200]u32 = undefined;
    var vs: [200]u32 = undefined;
    for (0..200) |i| {
        ks[i] = universe[i + 10];
        vs[i] = if (i < 140) a.get(ks[i]).? else b.get(ks[i]).?;
    }
    const direct = try SS.fromFacts(&ks, &vs);
    try std.testing.expect(merged.eql(&direct));
}
