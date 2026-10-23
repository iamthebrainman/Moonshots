//! primes.zig - the key universe of SUNZI: primes below 2^32.
//!
//! A key is a prime p < 2^32. Everything here is exact integer arithmetic on
//! u32/u64; there is no floating point and no randomness.

const std = @import("std");

/// (a * b) mod m for a, b < m < 2^32. The product fits in u64.
inline fn mulmod(a: u64, b: u64, m: u64) u64 {
    return (a * b) % m;
}

fn powmod(base: u64, exp: u64, m: u64) u64 {
    var result: u64 = 1;
    var b = base % m;
    var e = exp;
    while (e > 0) {
        if (e & 1 == 1) result = mulmod(result, b, m);
        b = mulmod(b, b, m);
        e >>= 1;
    }
    return result;
}

/// Deterministic primality test for every u32.
/// Miller-Rabin with bases 2, 7, 61 is exact for n < 4,759,123,141 (Jaeschke 1993),
/// which covers all of u32. The small-prime pre-pass also removes the n == base cases.
pub fn isPrime(n: u32) bool {
    if (n < 2) return false;
    const small = [_]u32{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (small) |p| {
        if (n == p) return true;
        if (n % p == 0) return false;
    }
    var d: u64 = n - 1;
    var s: u32 = 0;
    while (d % 2 == 0) {
        d /= 2;
        s += 1;
    }
    const bases = [_]u64{ 2, 7, 61 };
    for (bases) |a| {
        if (a % n == 0) continue;
        var x = powmod(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var witness = true;
        var r: u32 = 1;
        while (r < s) : (r += 1) {
            x = mulmod(x, x, n);
            if (x == n - 1) {
                witness = false;
                break;
            }
        }
        if (witness) return false;
    }
    return true;
}

/// Smallest prime >= n, or null if there is none below 2^32.
pub fn nextPrime(n: u32) ?u32 {
    var c: u64 = n;
    if (c < 2) c = 2;
    while (c <= std.math.maxInt(u32)) : (c += 1) {
        if (isPrime(@intCast(c))) return @intCast(c);
    }
    return null;
}

/// Multiplicative inverse of a modulo the prime p (a not divisible by p).
pub fn modInverse(a: u32, p: u32) u32 {
    std.debug.assert(p > 1 and a % p != 0);
    // Extended Euclid on signed 64-bit values.
    var r0: i64 = p;
    var r1: i64 = a % p;
    var t0: i64 = 0;
    var t1: i64 = 1;
    while (r1 != 0) {
        const q = @divTrunc(r0, r1);
        const r2 = r0 - q * r1;
        r0 = r1;
        r1 = r2;
        const t2 = t0 - q * t1;
        t0 = t1;
        t1 = t2;
    }
    std.debug.assert(r0 == 1);
    if (t0 < 0) t0 += p;
    return @intCast(t0);
}

/// Fills `out` with the primes <= limit in increasing order (sieve of Eratosthenes
/// over odd numbers). Returns how many were written; stops when `out` is full.
/// `scratch` must hold at least limit/2 + 1 bytes.
pub fn sieve(limit: u32, scratch: []u8, out: []u32) usize {
    std.debug.assert(scratch.len >= limit / 2 + 1);
    const half: usize = limit / 2 + 1;
    var i: usize = 0;
    while (i < half) : (i += 1) scratch[i] = 1; // index i represents the odd number 2i+1
    scratch[0] = 0; // 1 is not prime
    var p: usize = 3;
    while (p * p <= limit) : (p += 2) {
        if (scratch[p / 2] == 1) {
            var m: usize = p * p;
            while (m <= limit) : (m += 2 * p) scratch[m / 2] = 0;
        }
    }
    var count: usize = 0;
    if (limit >= 2 and out.len > 0) {
        out[0] = 2;
        count = 1;
    }
    i = 1;
    while (i < half and count < out.len) : (i += 1) {
        const v: usize = 2 * i + 1;
        if (v > limit) break;
        if (scratch[i] == 1) {
            out[count] = @intCast(v);
            count += 1;
        }
    }
    return count;
}

// =====================================================================
// tests
// =====================================================================

test "primes: Miller-Rabin agrees with a sieve for every n < 200000" {
    var scratch: [100_001]u8 = undefined;
    var list: [20_000]u32 = undefined;
    const count = sieve(200_000, &scratch, &list);
    try std.testing.expectEqual(@as(usize, 17984), count); // pi(200000) = 17984
    var idx: usize = 0;
    var n: u32 = 0;
    while (n < 200_000) : (n += 1) {
        const expect = idx < count and list[idx] == n;
        if (expect) idx += 1;
        try std.testing.expectEqual(expect, isPrime(n));
    }
}

test "primes: known large values and strong pseudoprimes" {
    try std.testing.expect(isPrime(4_294_967_291)); // largest prime below 2^32
    try std.testing.expect(!isPrime(4_294_967_295));
    try std.testing.expect(!isPrime(4_294_967_293)); // 2^32 - 3 is composite
    try std.testing.expect(isPrime(2_147_483_647)); // 2^31 - 1
    // Carmichael numbers and base-2 / base-2,7 strong pseudoprimes must be rejected.
    const bad = [_]u32{ 561, 1105, 1729, 2465, 2821, 6601, 8911, 2047, 3277, 4033, 4681, 8321, 3215031751, 25326001, 1373653 };
    for (bad) |c| try std.testing.expect(!isPrime(c));
    // Squares of primes near the top of the range.
    try std.testing.expect(!isPrime(65_521 * 65_521));
    try std.testing.expect(!isPrime(65_519 * 65_537));
}

test "primes: nextPrime and modInverse" {
    try std.testing.expectEqual(@as(?u32, 2), nextPrime(0));
    try std.testing.expectEqual(@as(?u32, 101), nextPrime(100));
    try std.testing.expectEqual(@as(?u32, 4_294_967_291), nextPrime(4_294_967_290));
    try std.testing.expectEqual(@as(?u32, null), nextPrime(4_294_967_292));
    const ps = [_]u32{ 2, 3, 5, 7, 65_521, 1_000_003, 268_435_399, 4_294_967_291 };
    for (ps) |p| {
        var a: u32 = 1;
        var step: u32 = 0;
        while (step < 50) : (step += 1) {
            if (a % p != 0) {
                const inv = modInverse(a, p);
                try std.testing.expectEqual(@as(u64, 1), (@as(u64, a % p) * inv) % p);
            }
            a = a *% 2654435761 +% 12345;
        }
    }
}
