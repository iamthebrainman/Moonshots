//! knowledge.zig - SUNZI carrying the kind of knowledge the exhibits carry:
//! relation facts with provenance, and the student/teacher comparison.
//!
//! This layer is deliberately thin. The format is sunzi.zig; this file shows one way
//! to put the exhibits' data in it, and what that buys.
//!
//! * A fact is a (subject, object) pair. The key shape is the same as the exhibits'
//!   Relation slot key (subject, object) - the relation type is NOT part of the key.
//!   In table.rs that omission corrupts the chain on a second assertion (GAPS.txt, A5/A6).
//!   Here the relation type lives in the value, so a second assertion is an exact overwrite.
//! * Provenance is the residue class of the key modulo 8. The speaker of a fact is
//!   not stored anywhere; it is a property of the number that is the address.
//! * The value packs relation(7) confidence(4) IS-domain(4) modality(3) = 18 bits, so
//!   every key must exceed 2^18. Keys are drawn from primes above 2^25.

const std = @import("std");
const sunzi = @import("sunzi.zig");
const primes = @import("primes.zig");

/// Who asserted a fact: the key's residue class mod 8.
pub const Speaker = enum(u3) {
    user = 1,
    self_engine = 3,
    corpus = 5,
    unknown = 7,
};

pub const speakers = [4]Speaker{ .user, .self_engine, .corpus, .unknown };

pub fn speakerOfKey(p: u32) Speaker {
    std.debug.assert(p & 1 == 1);
    return @enumFromInt(@as(u3, @truncate(p)));
}

pub const State = struct {
    /// Index into the host's relation table (the exhibits' RelationType has about 100 opcodes).
    relation: u7,
    confidence: u4,
    /// IsDomain: the exhibits define 13.
    domain: u4,
    /// AssertionModality: the exhibits define 5.
    modality: u3,
};

pub fn pack(st: State) u32 {
    return @as(u32, st.relation) |
        (@as(u32, st.confidence) << 7) |
        (@as(u32, st.domain) << 11) |
        (@as(u32, st.modality) << 15);
}

pub fn unpack(v: u32) State {
    return .{
        .relation = @truncate(v),
        .confidence = @truncate(v >> 7),
        .domain = @truncate(v >> 11),
        .modality = @truncate(v >> 15),
    };
}

/// The first `per_class` primes above 2^25 in each odd residue class mod 8.
/// Ordinal i of a fact selects the i-th prime of the speaker's class.
pub fn KeySpace(comptime per_class: usize) type {
    return struct {
        const Self = @This();
        by_class: [4][per_class]u32,

        pub fn build() Self {
            var ks: Self = undefined;
            var fill: [4]usize = @splat(0);
            var n: u32 = (1 << 25) + 1;
            while (true) : (n += 2) {
                if (!primes.isPrime(n)) continue;
                const c: usize = (n & 7) >> 1;
                if (fill[c] < per_class) {
                    ks.by_class[c][fill[c]] = n;
                    fill[c] += 1;
                }
                if (fill[0] == per_class and fill[1] == per_class and fill[2] == per_class and fill[3] == per_class) break;
            }
            return ks;
        }

        pub fn key(self: *const Self, speaker: Speaker, ordinal: usize) u32 {
            return self.by_class[@as(usize, @intFromEnum(speaker)) >> 1][ordinal];
        }
    };
}

/// (subject, object) pair -> dense ordinal. This is the host's dictionary: SUNZI
/// itself does not name anything; a name has to be turned into a prime by someone.
pub fn PairDict(comptime max: usize) type {
    return struct {
        const Self = @This();
        subj: [max]u32,
        obj: [max]u32,
        n: usize,

        pub fn init() Self {
            return .{ .subj = undefined, .obj = undefined, .n = 0 };
        }

        pub fn find(self: *const Self, s: u32, o: u32) ?usize {
            var i: usize = 0;
            while (i < self.n) : (i += 1) {
                if (self.subj[i] == s and self.obj[i] == o) return i;
            }
            return null;
        }

        pub fn getOrAdd(self: *Self, s: u32, o: u32) error{Overflow}!usize {
            if (self.find(s, o)) |i| return i;
            if (self.n >= max) return error.Overflow;
            self.subj[self.n] = s;
            self.obj[self.n] = o;
            self.n += 1;
            return self.n - 1;
        }
    };
}

pub fn Kb(comptime cap: usize, comptime max_facts: usize) type {
    return struct {
        const Self = @This();
        pub const St = sunzi.Store(cap);
        pub const Space = KeySpace(max_facts);

        store: St,
        space: Space,
        dict: PairDict(max_facts),

        /// Where a (subject, object) pair stands between two stores.
        pub const Sets = struct {
            /// asserted only in A (the student's "errors")
            only_a: [max_facts]bool,
            /// asserted only in B (the teacher's "corrections")
            only_b: [max_facts]bool,
            /// asserted in both with an identical state ("confirmations")
            confirmed: [max_facts]bool,
            /// asserted in both with a different relation (the exhibits' RelationSubstitution fix)
            substituted: [max_facts]bool,
            /// asserted in both with the same relation but different confidence/domain/modality
            reweighed: [max_facts]bool,
        };

        pub fn init() Self {
            return .{ .store = St.init(), .space = Space.build(), .dict = PairDict(max_facts).init() };
        }

        pub fn assertFact(self: *Self, speaker: Speaker, subject: u32, object: u32, st: State) !sunzi.PutResult {
            const ord = try self.dict.getOrAdd(subject, object);
            return self.store.put(self.space.key(speaker, ord), pack(st));
        }

        pub fn lookup(self: *const Self, speaker: Speaker, subject: u32, object: u32) ?State {
            const ord = self.dict.find(subject, object) orelse return null;
            const v = self.store.get(self.space.key(speaker, ord)) orelse return null;
            return unpack(v);
        }

        pub fn retract(self: *Self, speaker: Speaker, subject: u32, object: u32) !bool {
            const ord = self.dict.find(subject, object) orelse return false;
            return self.store.del(self.space.key(speaker, ord));
        }

        /// How many speakers currently assert something about the pair.
        pub fn corroboration(self: *const Self, subject: u32, object: u32) usize {
            const ord = self.dict.find(subject, object) orelse return 0;
            var n: usize = 0;
            for (speakers) |sp| {
                if (self.store.has(self.space.key(sp, ord))) n += 1;
            }
            return n;
        }

        /// Every key the dictionary can have produced, ascending: the universe for enumeration.
        pub fn universeInto(self: *const Self, out: []u32) usize {
            var n: usize = 0;
            for (speakers) |sp| {
                var ord: usize = 0;
                while (ord < self.dict.n) : (ord += 1) {
                    out[n] = self.space.key(sp, ord);
                    n += 1;
                }
            }
            std.mem.sort(u32, out[0..n], {}, std.sort.asc(u32));
            return n;
        }

        /// The sub-store of one speaker's facts: a divisor of M, reduced out of K.
        pub fn speakerView(self: *const Self, speaker: Speaker) !St {
            var keys: [max_facts]u32 = undefined;
            var n: usize = 0;
            var ord: usize = 0;
            while (ord < self.dict.n) : (ord += 1) {
                const k = self.space.key(speaker, ord);
                if (self.store.has(k)) {
                    keys[n] = k;
                    n += 1;
                }
            }
            return self.store.viewKeys(keys[0..n]);
        }

        /// Student/teacher comparison with one gcd of the key products and one gcd of the
        /// numerator difference. Both stores must keep the pair facts under `speaker`'s keys.
        pub fn compare(self: *const Self, speaker: Speaker, a: *const St, b: *const St) Sets {
            const d = a.diff(b);
            var sets = std.mem.zeroes(Sets);
            var ord: usize = 0;
            while (ord < self.dict.n) : (ord += 1) {
                const key = self.space.key(speaker, ord);
                if (d.only_a.modSmall(key) == 0) {
                    sets.only_a[ord] = true;
                } else if (d.only_b.modSmall(key) == 0) {
                    sets.only_b[ord] = true;
                } else if (d.agree.modSmall(key) == 0) {
                    sets.confirmed[ord] = true;
                } else if (d.conflict.modSmall(key) == 0) {
                    const sa = unpack(a.get(key).?);
                    const sb = unpack(b.get(key).?);
                    if (sa.relation != sb.relation) sets.substituted[ord] = true else sets.reweighed[ord] = true;
                }
            }
            return sets;
        }
    };
}

// =====================================================================
// tests
// =====================================================================

const rng_mod = @import("rng.zig");

const K = Kb(512, 64);

const IS: u7 = 1;
const HAS: u7 = 3;
const CAUSES: u7 = 5;
const CAN: u7 = 4;

fn mk(rel: u7, conf: u4) State {
    return .{ .relation = rel, .confidence = conf, .domain = 0, .modality = 0 };
}

test "knowledge: pack/unpack is lossless over the whole 18-bit state space" {
    var rel: u32 = 0;
    while (rel < 128) : (rel += 1) {
        var conf: u32 = 0;
        while (conf < 16) : (conf += 1) {
            const dom: u4 = @intCast((rel + conf) % 13);
            const mod: u3 = @intCast((rel * 3 + conf) % 5);
            const original = State{ .relation = @intCast(rel), .confidence = @intCast(conf), .domain = dom, .modality = mod };
            const back = unpack(pack(original));
            try std.testing.expectEqual(original, back);
            try std.testing.expect(pack(original) < (1 << 18));
        }
    }
}

test "knowledge: key space - every key is a prime above 2^25 in the right residue class" {
    const ks = KeySpace(40).build();
    for (speakers) |sp| {
        var prev: u32 = 0;
        for (0..40) |i| {
            const k = ks.key(sp, i);
            try std.testing.expect(primes.isPrime(k));
            try std.testing.expect(k > (1 << 25));
            try std.testing.expect(k > prev);
            try std.testing.expectEqual(sp, speakerOfKey(k));
            prev = k;
        }
    }
}

test "knowledge: provenance is the key, not a side table" {
    var kb = K.init();
    const dog = 0;
    const animal = 1;
    const pet = 2;
    // three speakers say things about (dog, animal); two about (dog, pet)
    try std.testing.expectEqual(sunzi.PutResult.inserted, try kb.assertFact(.corpus, dog, animal, mk(IS, 15)));
    try std.testing.expectEqual(sunzi.PutResult.inserted, try kb.assertFact(.user, dog, animal, mk(IS, 9)));
    try std.testing.expectEqual(sunzi.PutResult.inserted, try kb.assertFact(.self_engine, dog, animal, mk(HAS, 4)));
    _ = try kb.assertFact(.user, dog, pet, mk(IS, 12));
    _ = try kb.assertFact(.corpus, dog, pet, mk(IS, 14));

    try std.testing.expectEqual(@as(usize, 3), kb.corroboration(dog, animal));
    try std.testing.expectEqual(@as(usize, 2), kb.corroboration(dog, pet));
    try std.testing.expectEqual(@as(usize, 0), kb.corroboration(pet, dog));
    try std.testing.expectEqual(@as(u4, 9), kb.lookup(.user, dog, animal).?.confidence);
    try std.testing.expectEqual(HAS, kb.lookup(.self_engine, dog, animal).?.relation);
    try std.testing.expectEqual(@as(?State, null), kb.lookup(.unknown, dog, animal));

    // enumerate every key in the store from M alone, and read the speaker off each key
    var uni: [4 * 64]u32 = undefined;
    const nu = kb.universeInto(&uni);
    var found: [16]u32 = undefined;
    const nf = try kb.store.keysInto(uni[0..nu], &found);
    try std.testing.expectEqual(@as(usize, 5), nf);
    var by_speaker: [8]usize = @splat(0);
    for (found[0..nf]) |k| by_speaker[@intFromEnum(speakerOfKey(k))] += 1;
    try std.testing.expectEqual(@as(usize, 2), by_speaker[@intFromEnum(Speaker.user)]);
    try std.testing.expectEqual(@as(usize, 1), by_speaker[@intFromEnum(Speaker.self_engine)]);
    try std.testing.expectEqual(@as(usize, 2), by_speaker[@intFromEnum(Speaker.corpus)]);

    // one speaker's facts are a view: the same bytes as a store built from just those facts
    const user_view = try kb.speakerView(.user);
    var only_user = K.St.init();
    _ = try only_user.put(kb.space.key(.user, 0), pack(mk(IS, 9)));
    _ = try only_user.put(kb.space.key(.user, 1), pack(mk(IS, 12)));
    try std.testing.expect(user_view.eql(&only_user));
    // the views of the four speakers multiply back to M
    var prod = K.St.Num.fromU64(1);
    var rest = K.St.Num.init();
    for (speakers) |sp| {
        const v = try kb.speakerView(sp);
        try rest.mul(&prod, &v.m);
        prod.copyFrom(&rest);
    }
    try std.testing.expect(prod.eql(&kb.store.m));
}

test "knowledge: a second assertion is an exact overwrite (the exhibits' relation key corrupts its chain here)" {
    var kb = K.init();
    _ = try kb.assertFact(.corpus, 7, 8, mk(IS, 10));
    const once = kb.store;
    // asserting the identical fact again changes nothing - byte for byte
    try std.testing.expectEqual(sunzi.PutResult.unchanged, try kb.assertFact(.corpus, 7, 8, mk(IS, 10)));
    try std.testing.expect(kb.store.eql(&once));
    // same (subject, object) with a different relation replaces the old state exactly
    try std.testing.expectEqual(sunzi.PutResult.updated, try kb.assertFact(.corpus, 7, 8, mk(HAS, 10)));
    try std.testing.expectEqual(HAS, kb.lookup(.corpus, 7, 8).?.relation);
    var direct = K.St.init();
    _ = try direct.put(kb.space.key(.corpus, 0), pack(mk(HAS, 10)));
    try std.testing.expect(kb.store.eql(&direct));
    // and retracting returns to the empty store
    try std.testing.expect(try kb.retract(.corpus, 7, 8));
    try std.testing.expect(!(try kb.retract(.corpus, 7, 8)));
    const empty = K.St.init();
    try std.testing.expect(kb.store.eql(&empty));
}

test "knowledge: student/teacher comparison - the error_corrector scenario in one gcd" {
    // entities: dog=0 animal=1 cat=2 pet=3 fire=4 heat=5 ice=6 cold=7
    var kb = K.init();
    // register the pairs in a fixed order so ordinals are 0..3
    const pairs = [_][2]u32{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 } };
    for (pairs) |p| _ = try kb.dict.getOrAdd(p[0], p[1]);

    // student: dog HAS animal (wrong), cat IS pet, fire CAUSES heat
    var student = K.St.init();
    _ = try student.put(kb.space.key(.corpus, 0), pack(mk(HAS, 10)));
    _ = try student.put(kb.space.key(.corpus, 1), pack(mk(IS, 10)));
    _ = try student.put(kb.space.key(.corpus, 2), pack(mk(CAUSES, 10)));
    // teacher: dog IS animal, cat IS pet, ice CAUSES cold
    var teacher = K.St.init();
    _ = try teacher.put(kb.space.key(.corpus, 0), pack(mk(IS, 10)));
    _ = try teacher.put(kb.space.key(.corpus, 1), pack(mk(IS, 10)));
    _ = try teacher.put(kb.space.key(.corpus, 3), pack(mk(CAUSES, 10)));

    const sets = kb.compare(.corpus, &student, &teacher);
    try std.testing.expect(sets.substituted[0] and !sets.confirmed[0] and !sets.only_a[0] and !sets.only_b[0]); // dog-animal: HAS -> IS
    try std.testing.expect(sets.confirmed[1] and !sets.substituted[1]); // cat-pet agreed
    try std.testing.expect(sets.only_a[2] and !sets.only_b[2]); // fire-heat: student only
    try std.testing.expect(sets.only_b[3] and !sets.only_a[3]); // ice-cold: teacher only
    for (0..4) |i| try std.testing.expect(!sets.reweighed[i]);

    // the same facts as the key products the format hands back directly
    const d = student.diff(&teacher);
    try std.testing.expectEqual(kb.space.key(.corpus, 0), try asKey(&d.conflict));
    try std.testing.expectEqual(kb.space.key(.corpus, 1), try asKey(&d.agree));
    try std.testing.expectEqual(kb.space.key(.corpus, 2), try asKey(&d.only_a));
    try std.testing.expectEqual(kb.space.key(.corpus, 3), try asKey(&d.only_b));
}

test "knowledge: random student/teacher pairs agree with a naive comparison" {
    var g = rng_mod.SplitMix64.init(0xE220);
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var kb = K.init();
        const n = 60;
        for (0..n) |i| _ = try kb.dict.getOrAdd(@intCast(2 * i), @intCast(2 * i + 1));
        var student = K.St.init();
        var teacher = K.St.init();
        var sa: [n]?State = @splat(null);
        var sb: [n]?State = @splat(null);
        for (0..n) |i| {
            const rel: u7 = @intCast(1 + g.below(6));
            const conf: u4 = @intCast(g.below(16));
            const base = mk(rel, conf);
            switch (g.below(6)) {
                0 => sa[i] = base, // student only
                1 => sb[i] = base, // teacher only
                2 => { // identical
                    sa[i] = base;
                    sb[i] = base;
                },
                3 => { // relation substituted
                    sa[i] = base;
                    var other = base;
                    other.relation = if (rel == 1) 2 else rel - 1;
                    sb[i] = other;
                },
                4 => { // re-weighed
                    sa[i] = base;
                    var other = base;
                    other.confidence = conf +% 1;
                    sb[i] = other;
                },
                else => {}, // neither
            }
            if (sa[i]) |x| _ = try student.put(kb.space.key(.user, i), pack(x));
            if (sb[i]) |x| _ = try teacher.put(kb.space.key(.user, i), pack(x));
        }
        const sets = kb.compare(.user, &student, &teacher);
        for (0..n) |i| {
            const a = sa[i];
            const b = sb[i];
            const only_a = a != null and b == null;
            const only_b = a == null and b != null;
            const both = a != null and b != null;
            const same = both and pack(a.?) == pack(b.?);
            const subst = both and !same and a.?.relation != b.?.relation;
            const rew = both and !same and a.?.relation == b.?.relation;
            try std.testing.expectEqual(only_a, sets.only_a[i]);
            try std.testing.expectEqual(only_b, sets.only_b[i]);
            try std.testing.expectEqual(same, sets.confirmed[i]);
            try std.testing.expectEqual(subst, sets.substituted[i]);
            try std.testing.expectEqual(rew, sets.reweighed[i]);
        }
    }
}

/// The value of a number that is a single u32 key (the product of exactly one key).
fn asKey(n: *const K.St.Num) !u32 {
    const v = n.toU128() orelse return error.TestUnexpectedResult;
    return @intCast(v);
}

fn hexOf(n: *const K.St.Num, buf: []u8) []const u8 {
    var tmp: [2048]u8 = undefined;
    const len = n.byteLen();
    n.writeBE(tmp[0..len]);
    const digits = "0123456789abcdef";
    var at: usize = 0;
    buf[at] = '0';
    buf[at + 1] = 'x';
    at += 2;
    if (len == 0) {
        buf[at] = '0';
        at += 1;
    }
    for (tmp[0..len], 0..) |b, i| {
        if (i == 0 and (b >> 4) == 0) {
            buf[at] = digits[b & 15];
            at += 1;
            continue;
        }
        buf[at] = digits[b >> 4];
        buf[at + 1] = digits[b & 15];
        at += 2;
    }
    return buf[0..at];
}

test "knowledge: demo - a knowledge base is two integers, and comparing two of them is a gcd" {
    const names = [_][]const u8{ "dog", "animal", "cat", "pet", "fire", "heat", "ice", "cold" };
    const rels = [_][]const u8{ "?", "IS", "?", "HAS", "?", "CAUSES" };
    var kb = K.init();
    const pairs = [_][2]u32{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 } };
    for (pairs) |p| _ = try kb.dict.getOrAdd(p[0], p[1]);

    var teacher = K.St.init();
    _ = try teacher.put(kb.space.key(.corpus, 0), pack(mk(IS, 15)));
    _ = try teacher.put(kb.space.key(.corpus, 1), pack(mk(IS, 15)));
    _ = try teacher.put(kb.space.key(.corpus, 3), pack(mk(CAUSES, 15)));
    var student = K.St.init();
    _ = try student.put(kb.space.key(.corpus, 0), pack(mk(HAS, 9)));
    _ = try student.put(kb.space.key(.corpus, 1), pack(mk(IS, 15)));
    _ = try student.put(kb.space.key(.corpus, 2), pack(mk(CAUSES, 7)));

    var b1: [600]u8 = undefined;
    var b2: [600]u8 = undefined;
    std.debug.print("\n[demo] the teacher's three facts (dog IS animal, cat IS pet, ice CAUSES cold) are the pair\n", .{});
    std.debug.print("[demo]   M = {s}\n[demo]   K = {s}\n", .{ hexOf(&teacher.m, &b1), hexOf(&teacher.k, &b2) });
    std.debug.print("[demo] the student's three facts (dog HAS animal, cat IS pet, fire CAUSES heat) are the pair\n", .{});
    std.debug.print("[demo]   M = {s}\n[demo]   K = {s}\n", .{ hexOf(&student.m, &b1), hexOf(&student.k, &b2) });

    const d = student.diff(&teacher);
    std.debug.print("[demo] gcd(M_student, M_teacher)        = {s}   (the keys both assert)\n", .{hexOf(&d.shared, &b1)});
    std.debug.print("[demo] gcd(|K_student - K_teacher|, it) = {s}   (the keys on which they agree)\n", .{hexOf(&d.agree, &b1)});
    std.debug.print("[demo] shared / agree                   = {s}   (the keys on which they disagree)\n", .{hexOf(&d.conflict, &b1)});
    const sets = kb.compare(.corpus, &student, &teacher);
    for (0..kb.dict.n) |i| {
        const s = names[kb.dict.subj[i]];
        const o = names[kb.dict.obj[i]];
        const key = kb.space.key(.corpus, i);
        if (sets.confirmed[i]) std.debug.print("[demo]   key {d}: ({s}, {s}) confirmed by the teacher\n", .{ key, s, o });
        if (sets.substituted[i]) {
            const sa = unpack(student.get(key).?);
            const sb = unpack(teacher.get(key).?);
            std.debug.print("[demo]   key {d}: ({s}, {s}) is the conflict: student says {s}, teacher says {s}\n", .{ key, s, o, rels[sa.relation], rels[sb.relation] });
        }
        if (sets.only_a[i]) std.debug.print("[demo]   key {d}: ({s}, {s}) asserted only by the student (an error)\n", .{ key, s, o });
        if (sets.only_b[i]) std.debug.print("[demo]   key {d}: ({s}, {s}) asserted only by the teacher (a correction)\n", .{ key, s, o });
    }
    try std.testing.expect(sets.substituted[0] and sets.confirmed[1] and sets.only_a[2] and sets.only_b[3]);
}
