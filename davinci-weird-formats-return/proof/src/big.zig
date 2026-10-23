//! big.zig - fixed-capacity unsigned big integers (32-bit limbs, little-endian).
//!
//! SUNZI stores a knowledge base as two integers that are far wider than u128.
//! This file is the arithmetic those integers need and nothing else. It uses
//! only fixed arrays, u32/u64 arithmetic and std.testing: no allocator, no
//! std.math.big, no ArrayList. That is deliberate. The proof has to build on
//! four Zig releases whose big-int, container and allocator APIs differ, and
//! "same bytes on every compiler" is one of the determinism claims.
//!
//! Capacity is a comptime parameter. Anything that would not fit returns
//! `error.Overflow` and leaves its destination unchanged. Operations that can
//! grow a number require one or two limbs of headroom (documented per function),
//! so the usable capacity is `cap - 2` limbs.

const std = @import("std");

pub const Error = error{Overflow};

/// Test instrumentation: how many times Knuth D's rare "add back" step has run in this process.
/// The divMod tests use it to prove that step was actually exercised.
pub var knuth_addback_hits: usize = 0;

pub fn Big(comptime cap: usize) type {
    comptime {
        if (cap < 4) @compileError("Big needs at least 4 limbs");
    }
    return struct {
        const Self = @This();
        pub const capacity: usize = cap;
        const B: u64 = 1 << 32;

        /// limbs[0] is least significant. Only limbs[0..len] are meaningful.
        limbs: [cap]u32 = undefined,
        /// Number of significant limbs; limbs[len-1] != 0 when len > 0. Zero has len == 0.
        len: usize = 0,

        // ----------------------------------------------------------------
        // construction / inspection
        // ----------------------------------------------------------------

        pub fn init() Self {
            return .{};
        }

        pub fn fromU64(v: u64) Self {
            var r: Self = .{};
            r.setU64(v);
            return r;
        }

        pub fn setU64(self: *Self, v: u64) void {
            self.len = 0;
            if (v == 0) return;
            self.limbs[0] = @truncate(v);
            self.len = 1;
            const hi: u32 = @truncate(v >> 32);
            if (hi != 0) {
                self.limbs[1] = hi;
                self.len = 2;
            }
        }

        pub fn setU128(self: *Self, v: u128) void {
            self.len = 0;
            var x = v;
            var i: usize = 0;
            while (x != 0) : (i += 1) {
                self.limbs[i] = @truncate(x);
                x >>= 32;
                self.len = i + 1;
            }
        }

        /// Value as u128, or null if it does not fit.
        pub fn toU128(self: *const Self) ?u128 {
            if (self.len > 4) return null;
            var r: u128 = 0;
            var i = self.len;
            while (i > 0) {
                i -= 1;
                r = (r << 32) | self.limbs[i];
            }
            return r;
        }

        pub fn copyFrom(self: *Self, o: *const Self) void {
            var i: usize = 0;
            while (i < o.len) : (i += 1) self.limbs[i] = o.limbs[i];
            self.len = o.len;
        }

        pub fn trim(self: *Self) void {
            while (self.len > 0 and self.limbs[self.len - 1] == 0) self.len -= 1;
        }

        pub fn isZero(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isOne(self: *const Self) bool {
            return self.len == 1 and self.limbs[0] == 1;
        }

        pub fn bitLen(self: *const Self) usize {
            if (self.len == 0) return 0;
            const top: u32 = self.limbs[self.len - 1];
            const lz: usize = @clz(top);
            return (self.len - 1) * 32 + (32 - lz);
        }

        pub fn trailingZeros(self: *const Self) usize {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.limbs[i] != 0) {
                    const tz: usize = @ctz(self.limbs[i]);
                    return i * 32 + tz;
                }
            }
            return 0;
        }

        pub fn cmp(a: *const Self, b: *const Self) std.math.Order {
            if (a.len != b.len) return if (a.len < b.len) .lt else .gt;
            var i = a.len;
            while (i > 0) {
                i -= 1;
                if (a.limbs[i] != b.limbs[i]) return if (a.limbs[i] < b.limbs[i]) .lt else .gt;
            }
            return .eq;
        }

        pub fn eql(a: *const Self, b: *const Self) bool {
            return a.cmp(b) == .eq;
        }

        // ----------------------------------------------------------------
        // add / subtract
        // ----------------------------------------------------------------

        /// self += o. Needs one limb of headroom beyond max(len).
        pub fn add(self: *Self, o: *const Self) Error!void {
            const n = @max(self.len, o.len);
            if (n >= cap) return error.Overflow;
            var carry: u64 = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a: u64 = if (i < self.len) self.limbs[i] else 0;
                const b: u64 = if (i < o.len) o.limbs[i] else 0;
                const t = a + b + carry;
                self.limbs[i] = @truncate(t);
                carry = t >> 32;
            }
            self.len = n;
            if (carry != 0) {
                self.limbs[n] = @truncate(carry);
                self.len = n + 1;
            }
        }

        /// self -= o. Requires self >= o (checked in safe builds).
        pub fn sub(self: *Self, o: *const Self) void {
            std.debug.assert(self.cmp(o) != .lt);
            var borrow: i64 = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const b: i64 = if (i < o.len) o.limbs[i] else 0;
                var t: i64 = @as(i64, self.limbs[i]) - b - borrow;
                if (t < 0) {
                    t += 4294967296;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                self.limbs[i] = @intCast(t);
            }
            self.trim();
        }

        // ----------------------------------------------------------------
        // small-operand arithmetic (the hot path of the store)
        // ----------------------------------------------------------------

        /// self *= m. Needs one limb of headroom.
        pub fn mulSmall(self: *Self, m: u32) Error!void {
            if (m == 0 or self.len == 0) {
                self.len = 0;
                return;
            }
            if (self.len >= cap) return error.Overflow;
            var carry: u64 = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const t = @as(u64, self.limbs[i]) * m + carry;
                self.limbs[i] = @truncate(t);
                carry = t >> 32;
            }
            if (carry != 0) {
                self.limbs[self.len] = @truncate(carry);
                self.len += 1;
            }
        }

        /// self += o * t. Needs two limbs of headroom beyond max(len).
        pub fn addMulSmall(self: *Self, o: *const Self, t: u32) Error!void {
            if (t == 0 or o.len == 0) return;
            const n = @max(self.len, o.len);
            if (n + 2 > cap) return error.Overflow;
            var carry: u64 = 0;
            var i: usize = 0;
            while (i < n or carry != 0) : (i += 1) {
                const a: u64 = if (i < self.len) self.limbs[i] else 0;
                const b: u64 = if (i < o.len) o.limbs[i] else 0;
                const s = a + b * t + carry;
                self.limbs[i] = @truncate(s);
                carry = s >> 32;
            }
            if (i > self.len) self.len = i;
            self.trim();
        }

        /// self /= d, returns the remainder. d must be non-zero.
        pub fn divSmall(self: *Self, d: u32) u32 {
            std.debug.assert(d != 0);
            var rem: u64 = 0;
            var i = self.len;
            while (i > 0) {
                i -= 1;
                const cur = (rem << 32) | self.limbs[i];
                self.limbs[i] = @truncate(cur / d);
                rem = cur % d;
            }
            self.trim();
            return @truncate(rem);
        }

        /// self mod d. d must be non-zero.
        pub fn modSmall(self: *const Self, d: u32) u32 {
            std.debug.assert(d != 0);
            var rem: u64 = 0;
            var i = self.len;
            while (i > 0) {
                i -= 1;
                rem = ((rem << 32) | self.limbs[i]) % d;
            }
            return @truncate(rem);
        }

        // ----------------------------------------------------------------
        // shifts
        // ----------------------------------------------------------------

        pub fn shiftLeft(self: *Self, bits: usize) Error!void {
            if (self.len == 0 or bits == 0) return;
            const need = (self.bitLen() + bits + 31) / 32;
            if (need > cap) return error.Overflow;
            const limb_shift = bits / 32;
            const s: u6 = @intCast(bits % 32);
            const rs: u6 = 32 - s;
            var i: usize = need;
            while (i > 0) {
                i -= 1;
                var v: u64 = 0;
                if (i >= limb_shift) {
                    const src = i - limb_shift;
                    const lo: u64 = if (src < self.len) self.limbs[src] else 0;
                    v = lo << s;
                    if (src >= 1) {
                        const prev: u64 = if (src - 1 < self.len) self.limbs[src - 1] else 0;
                        v |= prev >> rs;
                    }
                }
                self.limbs[i] = @truncate(v);
            }
            self.len = need;
            self.trim();
        }

        pub fn shiftRight(self: *Self, bits: usize) void {
            if (self.len == 0 or bits == 0) return;
            const limb_shift = bits / 32;
            if (limb_shift >= self.len) {
                self.len = 0;
                return;
            }
            const s: u6 = @intCast(bits % 32);
            const rs: u6 = 32 - s;
            const new_len = self.len - limb_shift;
            var i: usize = 0;
            while (i < new_len) : (i += 1) {
                const src = i + limb_shift;
                var v: u64 = @as(u64, self.limbs[src]) >> s;
                if (src + 1 < self.len) v |= @as(u64, self.limbs[src + 1]) << rs;
                self.limbs[i] = @truncate(v);
            }
            self.len = new_len;
            self.trim();
        }

        // ----------------------------------------------------------------
        // multiply, divide, gcd
        // ----------------------------------------------------------------

        /// out = a * b (schoolbook). out must not alias a or b.
        pub fn mul(out: *Self, a: *const Self, b: *const Self) Error!void {
            if (a.len == 0 or b.len == 0) {
                out.len = 0;
                return;
            }
            if (a.len + b.len > cap) return error.Overflow;
            var i: usize = 0;
            while (i < a.len + b.len) : (i += 1) out.limbs[i] = 0;
            i = 0;
            while (i < a.len) : (i += 1) {
                var carry: u64 = 0;
                var j: usize = 0;
                while (j < b.len) : (j += 1) {
                    const t = @as(u64, a.limbs[i]) * b.limbs[j] + out.limbs[i + j] + carry;
                    out.limbs[i + j] = @truncate(t);
                    carry = t >> 32;
                }
                out.limbs[i + b.len] = @truncate(carry);
            }
            out.len = a.len + b.len;
            out.trim();
        }

        /// q = a / b, r = a % b (Knuth, TAOCP vol. 2, 4.3.1 Algorithm D, in the
        /// 32-bit-digit form of Hacker's Delight `divmnu`). b must be non-zero.
        /// q and r must be distinct objects; either may alias a or b.
        pub fn divMod(q: *Self, r: *Self, a: *const Self, b: *const Self) void {
            std.debug.assert(b.len != 0);
            std.debug.assert(@intFromPtr(q) != @intFromPtr(r));
            if (a.cmp(b) == .lt) {
                r.copyFrom(a);
                q.len = 0;
                return;
            }
            const m = a.len;
            const n = b.len;
            var qq: [cap]u32 = undefined;

            if (n == 1) {
                const d: u64 = b.limbs[0];
                var k: u64 = 0;
                var j = m;
                while (j > 0) {
                    j -= 1;
                    const cur = (k << 32) | a.limbs[j];
                    qq[j] = @truncate(cur / d);
                    k = cur % d;
                }
                var i: usize = 0;
                while (i < m) : (i += 1) q.limbs[i] = qq[i];
                q.len = m;
                q.trim();
                r.setU64(k);
                return;
            }

            var un: [cap + 1]u32 = undefined;
            var vn: [cap]u32 = undefined;
            const lz: usize = @clz(b.limbs[n - 1]);
            const s: u6 = @intCast(lz);
            const rs: u6 = 32 - s;

            var i: usize = n - 1;
            while (i > 0) : (i -= 1) {
                vn[i] = @truncate((@as(u64, b.limbs[i]) << s) | (@as(u64, b.limbs[i - 1]) >> rs));
            }
            vn[0] = @truncate(@as(u64, b.limbs[0]) << s);

            un[m] = @truncate(@as(u64, a.limbs[m - 1]) >> rs);
            i = m - 1;
            while (i > 0) : (i -= 1) {
                un[i] = @truncate((@as(u64, a.limbs[i]) << s) | (@as(u64, a.limbs[i - 1]) >> rs));
            }
            un[0] = @truncate(@as(u64, a.limbs[0]) << s);

            var jj: usize = m - n + 1;
            while (jj > 0) {
                jj -= 1;
                const j = jj;
                const num: u64 = (@as(u64, un[j + n]) << 32) | un[j + n - 1];
                var qhat: u64 = num / vn[n - 1];
                var rhat: u64 = num - qhat * vn[n - 1];
                while (true) {
                    if (qhat >= B or qhat * vn[n - 2] > ((rhat << 32) | un[j + n - 2])) {
                        qhat -= 1;
                        rhat += vn[n - 1];
                        if (rhat < B) continue;
                    }
                    break;
                }

                // multiply and subtract
                var k: i64 = 0;
                var t: i64 = 0;
                var ix: usize = 0;
                while (ix < n) : (ix += 1) {
                    const p: u64 = qhat * vn[ix];
                    t = @as(i64, un[ix + j]) - k - @as(i64, @intCast(p & 0xFFFFFFFF));
                    un[ix + j] = @truncate(@as(u64, @bitCast(t)));
                    k = @as(i64, @intCast(p >> 32)) - (t >> 32);
                }
                t = @as(i64, un[j + n]) - k;
                un[j + n] = @truncate(@as(u64, @bitCast(t)));

                qq[j] = @truncate(qhat);
                if (t < 0) {
                    // subtracted too much: add the divisor back once
                    knuth_addback_hits += 1;
                    qq[j] -%= 1;
                    var kk: u64 = 0;
                    ix = 0;
                    while (ix < n) : (ix += 1) {
                        const tt: u64 = @as(u64, un[ix + j]) + vn[ix] + kk;
                        un[ix + j] = @truncate(tt);
                        kk = tt >> 32;
                    }
                    un[j + n] +%= @as(u32, @truncate(kk));
                }
            }

            // remainder = un[0..n] >> s
            var ri: usize = 0;
            while (ri < n) : (ri += 1) {
                r.limbs[ri] = @truncate((@as(u64, un[ri]) >> s) | (@as(u64, un[ri + 1]) << rs));
            }
            r.len = n;
            r.trim();

            const qn = m - n + 1;
            ri = 0;
            while (ri < qn) : (ri += 1) q.limbs[ri] = qq[ri];
            q.len = qn;
            q.trim();
        }

        /// out = gcd(a, b) by Stein's binary algorithm. gcd(0, x) = x.
        pub fn gcd(out: *Self, a: *const Self, b: *const Self) void {
            if (a.len == 0) {
                out.copyFrom(b);
                return;
            }
            if (b.len == 0) {
                out.copyFrom(a);
                return;
            }
            var x: Self = undefined;
            var y: Self = undefined;
            x.copyFrom(a);
            y.copyFrom(b);
            const tzx = x.trailingZeros();
            const tzy = y.trailingZeros();
            const common = @min(tzx, tzy);
            x.shiftRight(tzx);
            y.shiftRight(tzy);
            var px: *Self = &x;
            var py: *Self = &y;
            while (true) {
                switch (px.cmp(py)) {
                    .eq => break,
                    .gt => {
                        const tmp = px;
                        px = py;
                        py = tmp;
                    },
                    .lt => {},
                }
                py.sub(px);
                py.shiftRight(py.trailingZeros());
            }
            out.copyFrom(px);
            // cannot overflow: the result is no larger than min(a, b)
            out.shiftLeft(common) catch unreachable;
        }

        // ----------------------------------------------------------------
        // bytes (canonical big-endian, minimal length, zero = empty)
        // ----------------------------------------------------------------

        pub fn byteLen(self: *const Self) usize {
            return (self.bitLen() + 7) / 8;
        }

        /// Writes exactly byteLen() bytes, most significant first.
        pub fn writeBE(self: *const Self, out: []u8) void {
            const n = self.byteLen();
            std.debug.assert(out.len >= n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const limb = self.limbs[i / 4];
                const sh: u5 = @intCast((i % 4) * 8);
                out[n - 1 - i] = @truncate(limb >> sh);
            }
        }

        /// Parses big-endian bytes (leading zero bytes tolerated).
        pub fn readBE(self: *Self, bytes: []const u8) Error!void {
            const need = (bytes.len + 3) / 4;
            if (need > cap) return error.Overflow;
            var i: usize = 0;
            while (i < need) : (i += 1) self.limbs[i] = 0;
            i = 0;
            while (i < bytes.len) : (i += 1) {
                const b = bytes[bytes.len - 1 - i];
                const sh: u5 = @intCast((i % 4) * 8);
                self.limbs[i / 4] |= @as(u32, b) << sh;
            }
            self.len = need;
            self.trim();
        }
    };
}

// =====================================================================
// tests
// =====================================================================

const rng_mod = @import("rng.zig");

const T = Big(64);

fn randBig(g: *rng_mod.SplitMix64, limbs: usize) T {
    var r: T = .{};
    var i: usize = 0;
    while (i < limbs) : (i += 1) {
        // Biased toward the digits that exercise Knuth D's correction paths.
        const pick = g.below(8);
        r.limbs[i] = switch (pick) {
            0 => 0,
            1 => 1,
            2 => 0x7FFFFFFF,
            3 => 0x80000000,
            4 => 0xFFFFFFFF,
            else => @truncate(g.next()),
        };
    }
    r.len = limbs;
    r.trim();
    return r;
}

fn fromU128(v: u128) T {
    var r: T = .{};
    r.setU128(v);
    return r;
}

fn gcdU128(a: u128, b: u128) u128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return x;
}

test "big: small arithmetic agrees with u128" {
    var g = rng_mod.SplitMix64.init(0xB16);
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        // am < 2^90 and bm < 2^60 keep every oracle expression below 2^128.
        const bits_a: u7 = @intCast(1 + g.below(90));
        const bits_b: u7 = @intCast(1 + g.below(60));
        const a: u128 = @as(u128, g.next()) << 64 | g.next();
        const b: u128 = @as(u128, g.next()) << 64 | g.next();
        const am: u128 = a >> @intCast(128 - @as(u8, bits_a));
        const bm: u128 = b >> @intCast(128 - @as(u8, bits_b));

        var x = fromU128(am);
        const y = fromU128(bm);

        // add
        try x.add(&y);
        try std.testing.expectEqual(am + bm, x.toU128().?);
        // sub
        x.sub(&y);
        try std.testing.expectEqual(am, x.toU128().?);
        // compare
        const ord = std.math.order(am, bm);
        try std.testing.expectEqual(ord, x.cmp(&y));
        // bitLen
        try std.testing.expectEqual(@as(usize, 128 - @clz(am)), x.bitLen());
        // small ops
        const s: u32 = @truncate(g.next() | 1);
        var z = x;
        try z.mulSmall(s);
        try std.testing.expectEqual(am * s, z.toU128() orelse return error.TestUnexpectedResult);
        z = x;
        const rem = z.divSmall(s);
        try std.testing.expectEqual(am / s, z.toU128().?);
        try std.testing.expectEqual(@as(u32, @intCast(am % s)), rem);
        try std.testing.expectEqual(@as(u32, @intCast(am % s)), x.modSmall(s));
        // addMulSmall
        z = x;
        try z.addMulSmall(&y, s);
        try std.testing.expectEqual(am + bm * s, z.toU128().?);
        // shifts
        if (bits_a < 60) {
            const sh: usize = @intCast(g.below(60));
            z = x;
            try z.shiftLeft(sh);
            try std.testing.expectEqual(am << @intCast(sh), z.toU128().?);
            z.shiftRight(sh);
            try std.testing.expectEqual(am, z.toU128().?);
        }
        const shr: usize = @intCast(g.below(130));
        z = x;
        z.shiftRight(shr);
        const expect_shr: u128 = if (shr >= 128) 0 else am >> @intCast(shr);
        try std.testing.expectEqual(expect_shr, z.toU128().?);
    }
}

test "big: mul, divMod, gcd against u128 and u64 oracles" {
    var g = rng_mod.SplitMix64.init(0xD1F);
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        const a: u64 = g.next() >> @intCast(g.below(63));
        const b: u64 = (g.next() >> @intCast(g.below(63))) | 1;
        const xa = T.fromU64(a);
        const xb = T.fromU64(b);
        var p: T = .{};
        try p.mul(&xa, &xb);
        try std.testing.expectEqual(@as(u128, a) * b, p.toU128().?);

        var q: T = .{};
        var r: T = .{};
        T.divMod(&q, &r, &p, &xb);
        try std.testing.expectEqual(@as(u128, a), q.toU128().?);
        try std.testing.expectEqual(@as(u128, 0), r.toU128().?);

        const w: u128 = @as(u128, g.next()) << 64 | g.next();
        const wd: u128 = (@as(u128, g.next()) << 40 | g.next() >> 24) | 1;
        const xw = fromU128(w);
        const xd = fromU128(wd);
        T.divMod(&q, &r, &xw, &xd);
        try std.testing.expectEqual(w / wd, q.toU128().?);
        try std.testing.expectEqual(w % wd, r.toU128().?);

        var gg: T = .{};
        T.gcd(&gg, &xw, &xd);
        try std.testing.expectEqual(gcdU128(w, wd), gg.toU128().?);
    }
}

test "big: divMod identity on large operands (Knuth D correction paths)" {
    var g = rng_mod.SplitMix64.init(0xAD0);
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        const la = 1 + g.below(30);
        const lb = 1 + g.below(14);
        const a = randBig(&g, @intCast(la));
        var b = randBig(&g, @intCast(lb));
        if (b.isZero()) b.setU64(3);

        var q: T = .{};
        var r: T = .{};
        T.divMod(&q, &r, &a, &b);
        // r < b
        try std.testing.expectEqual(std.math.Order.lt, r.cmp(&b));
        // a == q*b + r
        var qb: T = .{};
        try qb.mul(&q, &b);
        try qb.add(&r);
        try std.testing.expect(qb.eql(&a));
    }
}

test "big: gcd structure on large operands" {
    var g = rng_mod.SplitMix64.init(0x6CD);
    var n: usize = 0;
    while (n < 300) : (n += 1) {
        var a = randBig(&g, @intCast(1 + g.below(10)));
        var b = randBig(&g, @intCast(1 + g.below(10)));
        var c = randBig(&g, @intCast(1 + g.below(6)));
        if (a.isZero()) a.setU64(7);
        if (b.isZero()) b.setU64(11);
        if (c.isZero()) c.setU64(13);
        var ac: T = .{};
        var bc: T = .{};
        try ac.mul(&a, &c);
        try bc.mul(&b, &c);
        var d: T = .{};
        T.gcd(&d, &a, &b);
        var dc: T = .{};
        T.gcd(&dc, &ac, &bc);
        // gcd(ac, bc) == c * gcd(a, b)
        var cd: T = .{};
        try cd.mul(&c, &d);
        try std.testing.expect(dc.eql(&cd));
        // gcd divides both
        var q: T = .{};
        var r: T = .{};
        T.divMod(&q, &r, &a, &d);
        try std.testing.expect(r.isZero());
        T.divMod(&q, &r, &b, &d);
        try std.testing.expect(r.isZero());
    }
}

test "big: bytes round trip and canonical length" {
    var g = rng_mod.SplitMix64.init(0xB7E5);
    var n: usize = 0;
    while (n < 500) : (n += 1) {
        const a = randBig(&g, @intCast(g.below(20)));
        var buf: [96]u8 = undefined;
        const len = a.byteLen();
        a.writeBE(buf[0..len]);
        if (len > 0) try std.testing.expect(buf[0] != 0);
        var b: T = .{};
        try b.readBE(buf[0..len]);
        try std.testing.expect(a.eql(&b));
    }
    // tolerant of leading zero bytes
    var z: T = .{};
    try z.readBE(&[_]u8{ 0, 0, 0, 1, 2 });
    try std.testing.expectEqual(@as(u128, 0x0102), z.toU128().?);
}

test "big: overflow is reported and leaves the destination unchanged" {
    const S = Big(4);
    var a: S = .{};
    a.setU128((@as(u128, 1) << 127) | 12345);
    const before = a;
    // a occupies 4 limbs == capacity: no headroom for add/mulSmall/addMulSmall
    try std.testing.expectError(error.Overflow, a.mulSmall(3));
    const one = S.fromU64(1);
    try std.testing.expectError(error.Overflow, a.add(&one));
    try std.testing.expectError(error.Overflow, a.addMulSmall(&one, 5));
    try std.testing.expectError(error.Overflow, a.shiftLeft(1));
    try std.testing.expect(a.eql(&before));
    var out: S = .{};
    try std.testing.expectError(error.Overflow, out.mul(&a, &a));
}

fn fromLimbs(ls: []const u32) T {
    var r: T = .{};
    for (ls, 0..) |l, i| r.limbs[i] = l;
    r.len = ls.len;
    r.trim();
    return r;
}

fn checkDivision(a: *const T, b: *const T) !void {
    var q: T = .{};
    var r: T = .{};
    T.divMod(&q, &r, a, b);
    try std.testing.expectEqual(std.math.Order.lt, r.cmp(b));
    var qb: T = .{};
    try qb.mul(&q, b);
    try qb.add(&r);
    try std.testing.expect(qb.eql(a));
}

test "big: Knuth D add-back step - pinned vectors that trigger it, and a sweep that proves it ran" {
    // Found by exhaustive search over structured digits (4-limb / 3-limb, 10^7 cases, 111,036 hits).
    // Digits are listed least significant first.
    const vectors = [_][2][]const u32{
        .{ &[_]u32{ 0, 0, 0, 1 }, &[_]u32{ 1, 0, 1 } },
        .{ &[_]u32{ 0, 0, 0, 1 }, &[_]u32{ 1, 0, 0x80000000 } },
        .{ &[_]u32{ 0, 0, 0, 1 }, &[_]u32{ 0x7ffffffe, 0, 0x80000000 } },
    };
    for (vectors) |v| {
        const a = fromLimbs(v[0]);
        const b = fromLimbs(v[1]);
        const before = knuth_addback_hits;
        try checkDivision(&a, &b);
        try std.testing.expect(knuth_addback_hits == before + 1); // this input takes the add-back branch exactly once
    }
    // Now sweep 6^7 structured 4-limb / 3-limb divisions, check a = q*b + r (r < b) for every one,
    // and require that the add-back branch ran many times along the way.
    const ds = [_]u32{ 0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF };
    const before = knuth_addback_hits;
    for (ds) |d0| for (ds) |d1| for (ds) |d2| for (ds) |d3| for (ds) |e0| for (ds) |e1| for (ds) |e2| {
        if (e2 == 0) continue;
        const a = fromLimbs(&[_]u32{ d0, d1, d2, d3 });
        const b = fromLimbs(&[_]u32{ e0, e1, e2 });
        try checkDivision(&a, &b);
    };
    try std.testing.expect(knuth_addback_hits - before > 100);
}

test "big: gcd edge cases" {
    const zero: T = .{};
    const x = T.fromU64(0xDEADBEEF12345);
    var g: T = .{};
    T.gcd(&g, &zero, &x);
    try std.testing.expect(g.eql(&x));
    T.gcd(&g, &x, &zero);
    try std.testing.expect(g.eql(&x));
    T.gcd(&g, &zero, &zero);
    try std.testing.expect(g.isZero());
    T.gcd(&g, &x, &x);
    try std.testing.expect(g.eql(&x));
    const one = T.fromU64(1);
    T.gcd(&g, &one, &x);
    try std.testing.expect(g.isOne());
    // powers of two: gcd(2^100 * 3, 2^60 * 5) = 2^60
    var a = T.fromU64(3);
    try a.shiftLeft(100);
    var b = T.fromU64(5);
    try b.shiftLeft(60);
    T.gcd(&g, &a, &b);
    var want = T.fromU64(1);
    try want.shiftLeft(60);
    try std.testing.expect(g.eql(&want));
    // coprime large numbers: consecutive integers
    var c: T = fromLimbs(&[_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF });
    var d = c;
    try d.add(&one);
    T.gcd(&g, &c, &d);
    try std.testing.expect(g.isOne());
    _ = &c;
}
