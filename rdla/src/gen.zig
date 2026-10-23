//! gen.zig - the answer realiser: a Dada-engine style stochastic recursive transition network,
//! driven by RDLA readouts instead of seed word lists.
//!   * template sets per answer type, with literal chunks, slot sources and recursive sub-grammars
//!   * a slot source is a readout of the mapped table (what follows / precedes / keeps company with
//!     a unit, or the taught gloss of an idiom), ranked, then consumed in rank order with an avoid-list
//!   * template and sub-grammar choice is argmax over counts with an avoid-list (no randomness),
//!     so the same table + question always gives the same text
const std = @import("std");
const ctx = @import("ctx.zig");
const tok = @import("tok.zig");

pub const AnswerType = enum {
    define, // what is / what are
    cause, // why does / why is / why did
    justify, // why should / why would / why must
    means, // how can / how should / how does / how to
    advise, // what should / what would / what can
    place, // where is / where should / where does
    agent, // who is / who should / who can
    compare, // difference between / X vs Y / X like Y
    yesno, // aux-first question, undecided (resolved to confirm/correct at render time)
    confirm, // "Yes, S is a T ..."
    correct, // "No, S is a X, which is a type of Z."
    idiom, // "phrase" means ...
};

pub const Src = enum {
    subject, // the question's first subject
    other, // the question's second subject
    follows, // units that come after the subject
    precedes, // units that come before it
    near, // either side
    shared, // near BOTH subjects
    gloss, // taught gloss of an idiom
    isa, // S's hypernym, bare
    isa_a, // S's hypernym with a/an
    isa2_a, // the hypernym's hypernym with a/an
    other_a, // the second subject with a/an
};

pub const NT = enum { evidence, aside };

pub const Part = union(enum) {
    lit: []const u8,
    src: Src,
    sub: NT,
};

const L = struct {
    fn t(text: []const u8) Part {
        return .{ .lit = text };
    }
    fn s(x: Src) Part {
        return .{ .src = x };
    }
    fn n(x: NT) Part {
        return .{ .sub = x };
    }
};

const Template = []const Part;

const define_t = [_]Template{
    &.{ L.s(.subject), L.t(" is most often followed by "), L.s(.follows), L.t(", "), L.s(.follows), L.t(" and "), L.s(.follows), L.t(".") },
    &.{ L.t("Where "), L.s(.subject), L.t(" occurs, "), L.s(.precedes), L.t(" tends to come before it and "), L.s(.follows), L.t(" after it.") },
    &.{ L.s(.subject), L.t(" is bound up with "), L.s(.near), L.t(", "), L.n(.evidence) },
};
const cause_t = [_]Template{
    &.{ L.s(.subject), L.t(" is preceded by "), L.s(.precedes), L.t(" and "), L.s(.precedes), L.t(", which is what leads into it.") },
    &.{ L.t("What comes before "), L.s(.subject), L.t(" is "), L.s(.precedes), L.t("; what comes out of it is "), L.s(.follows), L.t(".") },
};
const compare_t = [_]Template{
    &.{ L.s(.subject), L.t(" and "), L.s(.other), L.t(" both keep company with "), L.s(.shared), L.t(" and "), L.s(.shared), L.t(".") },
    &.{ L.t("They share "), L.s(.shared), L.t("; "), L.s(.subject), L.t(" leans toward "), L.s(.near), L.t(".") },
};
const justify_t = [_]Template{
    &.{ L.s(.subject), L.t(" is worth it because it is tied to "), L.s(.near), L.t(" and "), L.s(.near), L.t(", and it leads to "), L.s(.follows), L.t(".") },
    &.{ L.t("The reason is what comes before "), L.s(.subject), L.t(": "), L.s(.precedes), L.t(" and "), L.s(.precedes), L.t(".") },
};
const means_t = [_]Template{
    &.{ L.t("Approach "), L.s(.subject), L.t(" through "), L.s(.precedes), L.t(", which leads into "), L.s(.follows), L.t(".") },
    &.{ L.t("Start from "), L.s(.near), L.t(", then "), L.s(.follows), L.t(", keeping "), L.s(.near), L.t(" in mind.") },
};
const advise_t = [_]Template{
    &.{ L.t("With "), L.s(.subject), L.t(", deal with "), L.s(.precedes), L.t(" first, then "), L.s(.follows), L.t(".") },
    &.{ L.t("Keep "), L.s(.near), L.t(" and "), L.s(.near), L.t(" in view when it comes to "), L.s(.subject), L.t(".") },
};
const place_t = [_]Template{
    &.{ L.s(.subject), L.t(" turns up around "), L.s(.near), L.t(" and "), L.s(.near), L.t(".") },
    &.{ L.t("Look where "), L.s(.precedes), L.t(" and "), L.s(.follows), L.t(" meet "), L.s(.subject), L.t(".") },
};
const agent_t = [_]Template{
    &.{ L.s(.subject), L.t(" is the business of whoever deals with "), L.s(.near), L.t(" and "), L.s(.near), L.t(".") },
    &.{ L.t("Those connected with "), L.s(.precedes), L.t(" and "), L.s(.follows), L.t(" are the ones to ask about "), L.s(.subject), L.t(".") },
};
const yesno_t = [_]Template{
    &.{ L.s(.other), L.t(" ranks "), L.s(.shared), L.t(" among the units closest to "), L.s(.subject), L.t(".") },
};
const confirm_t = [_]Template{
    &.{ L.t("Yes, "), L.s(.subject), L.t(" is "), L.s(.isa_a), L.t(", which is a type of "), L.s(.isa2_a), L.t(".") },
    &.{ L.t("Yes: "), L.s(.subject), L.t(" is "), L.s(.isa_a), L.t(".") },
};
const correct_t = [_]Template{
    &.{ L.t("No, "), L.s(.subject), L.t(" is "), L.s(.isa_a), L.t(", which is a type of "), L.s(.isa2_a), L.t(", not "), L.s(.other_a), L.t(".") },
    &.{ L.t("No, "), L.s(.subject), L.t(" is "), L.s(.isa_a), L.t(".") },
};
const idiom_t = [_]Template{
    &.{ L.t("\""), L.s(.subject), L.t("\" means "), L.s(.gloss), L.t(" "), L.s(.gloss), L.t(" "), L.s(.gloss), L.t(".") },
};

const evidence_alts = [_]Template{
    &.{ L.t("it keeps company with "), L.s(.near), L.t(" and "), L.s(.near), L.t("."), },
    &.{ L.t("it is preceded by "), L.s(.precedes), L.t(", and "), L.n(.aside) },
};
const aside_alts = [_]Template{
    &.{ L.t("followed by "), L.s(.follows), L.t(".") },
    &.{ L.t("then "), L.s(.follows), L.t(".") },
};

fn templatesFor(a: AnswerType) []const Template {
    return switch (a) {
        .define => &define_t,
        .cause => &cause_t,
        .compare => &compare_t,
        .yesno => &yesno_t,
        .justify => &justify_t,
        .means => &means_t,
        .advise => &advise_t,
        .place => &place_t,
        .agent => &agent_t,
        .confirm => &confirm_t,
        .correct => &correct_t,
        .idiom => &idiom_t,
    };
}

fn altsFor(n: NT) []const Template {
    return switch (n) {
        .evidence => &evidence_alts,
        .aside => &aside_alts,
    };
}

/// Plain counts, argmax with an avoid-list. All start at 1; `reinforce` is the training hook.
pub const Weights = struct {
    templates: [12][8]u32 = @splat(@splat(1)),
    alts: [2][4]u32 = @splat(@splat(1)),

    pub fn reinforce(self: *Weights, a: AnswerType, idx: usize, by: u32) void {
        self.templates[@intFromEnum(a)][idx] += by;
    }
};

fn pickAvoiding(counts: []const u32, used: []const bool) usize {
    var best: usize = 0;
    var best_c: u32 = 0;
    var found = false;
    for (counts, 0..) |c, i| {
        if (used[i]) continue;
        if (!found or c > best_c) {
            best = i;
            best_c = c;
            found = true;
        }
    }
    if (found) return best;
    for (counts, 0..) |c, i| if (i == 0 or c > best_c) {
        best = i;
        best_c = c;
    };
    return best;
}

// ---------------------------------------------------------------------------------------------
// Readout: which units does a bundle say sit at a given relative position?
// ---------------------------------------------------------------------------------------------

/// Set by `rdla probe`: print the raw decoded candidates (before the z threshold) for each readout.
pub var debug = false;

pub const Side = enum { left, right, both };

pub const Ranked = struct { unit: u64, score: f64 };

fn bundleNorm2(b: []const i32) f64 {
    var ss: f64 = 0;
    for (b) |x| ss += @as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(x));
    return ss;
}

pub const Table = struct {
    acc: *const ctx.Acc,
    sp: *const tok.Spellings,
    window: usize,
    /// 0 = automatic (peelCount). Tests on toy tapes pin it.
    peel: usize = 0,

    pub fn spell(self: Table, h: u64) []const u8 {
        return self.sp.get(h) orelse "?";
    }

    fn isBoundary(self: Table, h: u64) bool {
        const s = self.spell(h);
        return s.len == 1 and (s[0] == '.' or s[0] == ',' or s[0] == '?' or s[0] == '!' or s[0] == ';' or s[0] == ':' or s[0] == '\n');
    }

    fn signVec(v: ctx.Vec, out: []f64) void {
        for (v, 0..) |w, wi| {
            var b: usize = 0;
            while (b < 64) : (b += 1) out[wi * 64 + b] = if ((w >> @intCast(b)) & 1 == 1) 1 else -1;
        }
    }

    fn dotSign(resid: []const f64, v: ctx.Vec) f64 {
        var dot: f64 = 0;
        for (v, 0..) |w, wi| {
            var b: usize = 0;
            while (b < 64) : (b += 1) {
                const x = resid[wi * 64 + b];
                dot += if ((w >> @intCast(b)) & 1 == 1) x else -x;
            }
        }
        return dot;
    }

    /// The `peel_n` most frequent units: function words and punctuation. They are the operators; slots
    /// hold content, so slot readouts skip them.
    pub fn functionSet(self: Table, a: std.mem.Allocator) ![]bool {
        const acc = self.acc;
        const flags = try a.alloc(bool, acc.keys.len);
        @memset(flags, false);
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(a);
        for (acc.keys, 0..) |k, i| if (k != 0 and acc.count[i] > 0) try idxs.append(a, i);
        const C = struct {
            acc: *const ctx.Acc,
            fn lt(c: @This(), x: usize, y: usize) bool {
                if (c.acc.count[x] != c.acc.count[y]) return c.acc.count[x] > c.acc.count[y];
                return c.acc.keys[x] < c.acc.keys[y];
            }
        };
        std.mem.sort(usize, idxs.items, C{ .acc = acc }, C.lt);
        const peeled_n = if (self.peel != 0) @min(self.peel, idxs.items.len) else peelCount(idxs.items.len);
        for (idxs.items[0..@max(peeled_n * 2 / 5, @min(peeled_n, 1))]) |i| flags[i] = true; // function words: the top 2/5 of the peeled set
        return flags;
    }

    /// The unit that `unit` "is a": needs "is"/"was" right after it (offset 1) and then a content unit
    /// at offset 3 or 4 ("pizza is an italian dish" -> offset 3 or 4), both read from the same
    /// total-context bundle. Null when the table does not say.
    pub fn isa(self: Table, a: std.mem.Allocator, unit: u64) !?u64 {
        const acc = self.acc;
        const slot = acc.find(unit) orelse return null;
        const bundle = acc.right[slot * ctx.D ..][0..ctx.D];
        const c1 = try a.alloc(f64, acc.keys.len);
        defer a.free(c1);
        @memset(c1, 0);
        _ = try self.decode(a, bundle, &.{1}, c1);
        var copula: f64 = 0;
        for ([_][]const u8{ "is", "was", "are" }) |w| {
            if (acc.find(tok.fnv(w))) |wi| copula += c1[wi];
        }
        const fs: f64 = @floatFromInt(acc.count[slot]);
        if (debug) std.debug.print("-- isa({s}): copula={d:.1} of {d}\n", .{ self.spell(unit), copula, fs });
        if (copula < 0.15 * fs or copula < 3) return null;

        const c = try a.alloc(f64, acc.keys.len);
        defer a.free(c);
        @memset(c, 0);
        const nv = try self.decode(a, bundle, &.{ 3, 4 }, c);
        const func = try self.functionSet(a);
        defer a.free(func);
        var total: f64 = 0;
        for (acc.count) |x| total += @floatFromInt(x);
        var best: ?u64 = null;
        var best_z: f64 = 2.5;
        for (acc.keys, 0..) |key, i| {
            if (key == 0 or key == unit or func[i] or acc.count[i] < 3 or self.isBoundary(key)) continue;
            const fv: f64 = @floatFromInt(acc.count[i]);
            const expected = fs * fv * 2 / total;
            const z = (c[i] - expected) / @sqrt(expected + 1 + nv);
            if (debug and c[i] >= 1.5) std.debug.print("   isa cand {s:<14} est={d:.1} z={d:.1} count={d}\n", .{ self.spell(key), c[i], z, acc.count[i] });
            if (c[i] >= 2 and (z > best_z or (z == best_z and best != null and key < best.?))) {
                best = key;
                best_z = z;
            }
        }
        return best;
    }

    const peel_n = 300;
    /// 300 on a real vocabulary; a twentieth of it on a toy one.
    fn peelCount(units: usize) usize {
        return @min(peel_n, @max(units / 20, 1));
    }

    /// Decodes one bundle into per-unit co-occurrence estimates `cnt` (indexed like acc.keys) and returns
    /// the residual noise variance (in counts^2). Frequent units (the, of, ",", ...) are in every bundle
    /// at huge weight and leak into every unrelated candidate's dot, so the `peel_n` most frequent units
    /// are estimated and subtracted first (matching pursuit), twice to absorb cross-talk. Everything
    /// else is then read from the residual.
    fn decode(self: Table, a: std.mem.Allocator, bundle: []const i32, score_offs: []const i32, cnt: []f64) !f64 {
        const acc = self.acc;
        const D: usize = ctx.D;
        const resid = try a.alloc(f64, D);
        defer a.free(resid);
        for (bundle, 0..) |x, d| resid[d] = @floatFromInt(x);

        // the peel set: most frequent units, ties by key
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(a);
        for (acc.keys, 0..) |k, i| if (k != 0 and acc.count[i] > 0) try idxs.append(a, i);
        const Ctx = struct {
            acc: *const ctx.Acc,
            fn lt(c: @This(), x: usize, y: usize) bool {
                if (c.acc.count[x] != c.acc.count[y]) return c.acc.count[x] > c.acc.count[y];
                return c.acc.keys[x] < c.acc.keys[y];
            }
        };
        std.mem.sort(usize, idxs.items, Ctx{ .acc = acc }, Ctx.lt);
        const np = if (self.peel != 0) @min(self.peel, idxs.items.len) else peelCount(idxs.items.len);

        const w = self.window;
        const signs = try a.alloc(f64, np * w * D);
        defer a.free(signs);
        const est = try a.alloc(f64, np * w);
        defer a.free(est);
        @memset(est, 0);
        for (idxs.items[0..np], 0..) |ki, p| {
            const sv = ctx.seedVec(acc.keys[ki]);
            for (0..w) |oi| signVec(ctx.bind(sv, ctx.role(@intCast(oi + 1))), signs[(p * w + oi) * D ..][0..D]);
        }
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (0..np * w) |c| {
                const sg = signs[c * D ..][0..D];
                var dot: f64 = 0;
                for (sg, resid) |q, r| dot += q * r;
                const n = dot / @as(f64, @floatFromInt(D));
                est[c] += n;
                for (sg, resid) |q, *r| r.* -= n * q;
            }
        }
        // peeled units: their estimates at the offsets being scored
        for (idxs.items[0..np], 0..) |ki, p| {
            for (score_offs) |o| if (o >= 1) {
                cnt[ki] += est[p * w + @as(usize, @intCast(o - 1))];
            };
        }
        // everyone else (and the gloss role for everyone): residual dot
        var peeled = try a.alloc(bool, acc.keys.len);
        defer a.free(peeled);
        @memset(peeled, false);
        for (idxs.items[0..np]) |ki| peeled[ki] = true;
        for (acc.keys, 0..) |k, i| {
            if (k == 0) continue;
            const sv = ctx.seedVec(k);
            for (score_offs) |o| {
                if (o >= 1 and peeled[i]) continue;
                const r = if (o == 0) ctx.seedVec(ctx.GLOSS_ROLE) else ctx.role(o);
                cnt[i] += dotSign(resid, ctx.bind(sv, r)) / @as(f64, @floatFromInt(D));
            }
        }
        var ss: f64 = 0;
        for (resid) |x| ss += x * x;
        return @as(f64, @floatFromInt(score_offs.len)) * ss / (@as(f64, @floatFromInt(D)) * @as(f64, @floatFromInt(D)));
    }

    /// Top `k` units for `unit` on `side` (gloss = the taught-gloss role). Boundary tokens and units seen
    /// fewer than 5 times are skipped. Score is a collocation z-score on the decoded co-occurrence count.
    pub fn readout(self: Table, a: std.mem.Allocator, unit: u64, side: Side, gloss: bool, k: usize) ![]Ranked {
        const acc = self.acc;
        const slot = acc.find(unit) orelse return a.alloc(Ranked, 0);
        const cnt = try a.alloc(f64, acc.keys.len);
        defer a.free(cnt);
        @memset(cnt, 0);
        var offs: [16]i32 = undefined;
        var n: usize = 0;
        var noise_var: f64 = 0;
        if (gloss) {
            offs[0] = 0;
            noise_var = try self.decode(a, acc.right[slot * ctx.D ..][0..ctx.D], offs[0..1], cnt);
        } else {
            var o: i32 = 1;
            while (o <= self.window) : (o += 1) {
                offs[n] = o;
                n += 1;
            }
            if (side != .left) noise_var += try self.decode(a, acc.right[slot * ctx.D ..][0..ctx.D], offs[0..n], cnt);
            if (side != .right) noise_var += try self.decode(a, acc.left[slot * ctx.D ..][0..ctx.D], offs[0..n], cnt);
        }
        var total: f64 = 0;
        for (acc.count) |c| total += @floatFromInt(c);
        const fs: f64 = @floatFromInt(acc.count[slot]);
        const sides: f64 = if (side == .both) 2 else 1;
        const reach: f64 = @as(f64, @floatFromInt(self.window)) * sides;
        const func = try self.functionSet(a);
        defer a.free(func);
        if (debug) {
            std.debug.print("-- readout of {s} (count {d}, noise sd {d:.1}) side={s}\n", .{ self.spell(unit), acc.count[slot], @sqrt(noise_var), @tagName(side) });
            var shown: usize = 0;
            var used_d: std.ArrayList(bool) = .empty;
            defer used_d.deinit(a);
            try used_d.appendNTimes(a, false, acc.keys.len);
            while (shown < 12) : (shown += 1) {
                var bi: ?usize = null;
                for (acc.keys, 0..) |key, i| {
                    if (key == 0 or used_d.items[i] or self.isBoundary(key)) continue;
                    if (bi == null or cnt[i] > cnt[bi.?]) bi = i;
                }
                const i = bi orelse break;
                used_d.items[i] = true;
                const fv: f64 = @floatFromInt(acc.count[i]);
                const exp_d = fs * fv * reach / total;
                std.debug.print("   {s:<14} est={d:>7.1} expected={d:>7.1} z={d:>6.1} count={d} func={}\n", .{ self.spell(acc.keys[i]), cnt[i], exp_d, (cnt[i] - exp_d) / @sqrt(exp_d + 1 + noise_var), acc.count[i], func[i] });
            }
        }
        var list: std.ArrayList(Ranked) = .empty;
        errdefer list.deinit(a);
        for (acc.keys, 0..) |key, i| {
            if (key == 0 or key == unit) continue;
            if (self.isBoundary(key) or func[i]) continue; // function words are operators, not slot fillers
            const c = cnt[i];
            var score: f64 = c;
            if (gloss) {
                if (c < 1) continue;
            } else {
                if (c < 2 or acc.count[i] < 3) continue;
                const fv: f64 = @floatFromInt(acc.count[i]);
                const expected = fs * fv * reach / total;
                score = (c - expected) / @sqrt(expected + 1 + noise_var); // collocation z-score
                if (score < 2.5) continue;
            }
            try list.append(a, .{ .unit = key, .score = score });
        }
        std.mem.sort(Ranked, list.items, {}, struct {
            fn lt(_: void, x: Ranked, y: Ranked) bool {
                if (x.score != y.score) return x.score > y.score;
                return x.unit < y.unit;
            }
        }.lt);
        if (list.items.len > k) list.shrinkRetainingCapacity(k);
        return list.toOwnedSlice(a);
    }
};

// ---------------------------------------------------------------------------------------------
// Realiser
// ---------------------------------------------------------------------------------------------

pub const Question = struct {
    kind: AnswerType,
    subject: u64,
    other: u64 = 0,
    frame: Frame = .{ .wh = .none, .modal = .none },
};

const max_depth = 3;
const pool_n = 12;

pub const Realiser = struct {
    a: std.mem.Allocator,
    t: Table,
    q: Question,
    w: *Weights,
    pools: [11][]Ranked = @splat(&.{}),
    cursor: [11]usize = @splat(0),
    alt_used: [2]usize = @splat(0),
    short: bool = false, // no second-level hypernym: use the one-clause confirm/correct template

    pub fn init(a: std.mem.Allocator, t: Table, q: Question, w: *Weights) !Realiser {
        var r = Realiser{ .a = a, .t = t, .q = q, .w = w };
        r.pools[@intFromEnum(Src.follows)] = try t.readout(a, q.subject, .right, false, pool_n);
        r.pools[@intFromEnum(Src.precedes)] = try t.readout(a, q.subject, .left, false, pool_n);
        r.pools[@intFromEnum(Src.near)] = try t.readout(a, q.subject, .both, false, pool_n);
        if (q.kind == .idiom) r.pools[@intFromEnum(Src.gloss)] = try t.readout(a, q.subject, .right, true, pool_n);
        if (q.kind == .yesno or q.kind == .confirm or q.kind == .correct) {
            const x = try t.isa(a, q.subject);
            const z = if (x) |xx| try t.isa(a, xx) else null;
            const mk = struct {
                fn one(al: std.mem.Allocator, u: ?u64) ![]Ranked {
                    if (u == null) return &.{};
                    const p = try al.alloc(Ranked, 1);
                    p[0] = .{ .unit = u.?, .score = 0 };
                    return p;
                }
            }.one;
            r.pools[@intFromEnum(Src.isa_a)] = try mk(a, x);
            r.pools[@intFromEnum(Src.isa2_a)] = try mk(a, z);
            if (x) |xx| {
                if (q.other == xx or (z != null and q.other == z.?)) r.q.kind = .confirm else r.q.kind = .correct;
                r.short = z == null;
            }
        }
        if (q.other != 0) {
            const mine = r.pools[@intFromEnum(Src.near)];
            const theirs = try t.readout(a, q.other, .both, false, 400);
            defer a.free(theirs);
            const mine_all = try t.readout(a, q.subject, .both, false, 400);
            defer a.free(mine_all);
            var sh: std.ArrayList(Ranked) = .empty;
            for (mine_all) |m| for (theirs) |o| if (m.unit == o.unit) {
                try sh.append(a, .{ .unit = m.unit, .score = m.score + o.score });
                break;
            };
            std.mem.sort(Ranked, sh.items, {}, struct {
                fn lt(_: void, x: Ranked, y: Ranked) bool {
                    if (x.score != y.score) return x.score > y.score;
                    return x.unit < y.unit;
                }
            }.lt);
            r.pools[@intFromEnum(Src.shared)] = try sh.toOwnedSlice(a);
            _ = mine;
        }
        return r;
    }

    pub fn deinit(self: *Realiser) void {
        for (self.pools) |p| if (p.len > 0) self.a.free(p);
    }

    fn take(self: *Realiser, out: *std.ArrayList(u8), s: Src) !void {
        const u: ?u64 = switch (s) {
            .subject => self.q.subject,
            .other, .other_a => self.q.other,
            else => blk: {
                const i = @intFromEnum(s);
                const p = self.pools[i];
                if (p.len == 0) break :blk null;
                const c = self.cursor[i];
                self.cursor[i] += 1;
                break :blk p[c % p.len].unit;
            },
        };
        const word = if (u) |x| self.t.spell(x) else "(nothing learned)";
        if (s == .isa_a or s == .isa2_a or s == .other_a) {
            const vowel = word.len > 0 and std.mem.indexOfScalar(u8, "aeiou", word[0]) != null;
            try out.appendSlice(self.a, if (vowel) "an " else "a ");
        }
        try out.appendSlice(self.a, word);
    }

    fn renderParts(self: *Realiser, out: *std.ArrayList(u8), parts: Template, depth: usize) anyerror!void {
        for (parts) |p| switch (p) {
            .lit => |l| try out.appendSlice(self.a, l),
            .src => |s| try self.take(out, s),
            .sub => |n| {
                if (depth >= max_depth) {
                    try out.appendSlice(self.a, "...");
                    continue;
                }
                const alts = altsFor(n);
                const ni = @intFromEnum(n);
                var used: [4]bool = @splat(false);
                for (0..@min(self.alt_used[ni], alts.len)) |i| used[i] = true;
                const idx = pickAvoiding(self.w.alts[ni][0..alts.len], used[0..alts.len]);
                self.alt_used[ni] += 1;
                try self.renderParts(out, alts[idx], depth + 1);
            },
        };
    }

    /// One answer: `sentences` template picks, each different where the set allows.
    pub fn render(self: *Realiser, out: *std.ArrayList(u8), sentences: usize) !void {
        const ts = templatesFor(self.q.kind);
        var used: [8]bool = @splat(false);
        var i: usize = 0;
        while (i < sentences) : (i += 1) {
            const idx = if (self.short and (self.q.kind == .confirm or self.q.kind == .correct)) ts.len - 1 else pickAvoiding(self.w.templates[@intFromEnum(self.q.kind)][0..ts.len], used[0..ts.len]);
            used[idx] = true;
            const before = out.items.len;
            try self.renderParts(out, ts[idx], 0);
            if (out.items.len > before) out.items[before] = std.ascii.toUpper(out.items[before]);
            if (i + 1 < sentences) try out.appendSlice(self.a, " ");
        }
    }
};

// ---------------------------------------------------------------------------------------------
// Question understanding (minimal, deterministic): answer type from the question's operator words
// ---------------------------------------------------------------------------------------------

pub const Wh = enum { none, what, why, how, where, who, when, which };
pub const Modal = enum { none, is, does, should, would, can, will };

pub const Frame = struct { wh: Wh, modal: Modal };

fn whOf(w: []const u8) Wh {
    inline for (.{ "what", "why", "how", "where", "who", "when", "which" }, 1..) |name, k| {
        if (std.mem.eql(u8, w, name)) return @enumFromInt(k);
    }
    return .none;
}

fn modalOf(w: []const u8) Modal {
    const tbl = .{
        .{ "is", Modal.is },       .{ "are", Modal.is },     .{ "was", Modal.is },    .{ "were", Modal.is },
        .{ "does", Modal.does },   .{ "do", Modal.does },    .{ "did", Modal.does },
        .{ "should", Modal.should }, .{ "must", Modal.should }, .{ "ought", Modal.should },
        .{ "would", Modal.would }, .{ "could", Modal.would },
        .{ "can", Modal.can },     .{ "may", Modal.can },    .{ "might", Modal.can },
        .{ "will", Modal.will },
    };
    inline for (tbl) |e| if (std.mem.eql(u8, w, e[0])) return e[1];
    return .none;
}

/// The question frame: the wh-word (if first) and the modal/auxiliary that follows it (or leads).
pub fn frameOf(words: []const []const u8) Frame {
    if (words.len == 0) return .{ .wh = .none, .modal = .none };
    const wh = whOf(words[0]);
    if (wh != .none) return .{ .wh = wh, .modal = if (words.len > 1) modalOf(words[1]) else .none };
    return .{ .wh = .none, .modal = modalOf(words[0]) };
}

/// Frame (+ whether two subjects were named, + compare cue) -> answer type.
pub fn kindOf(f: Frame, subjects: usize, compare_cue: bool) AnswerType {
    if (subjects >= 2 and compare_cue) return .compare;
    return switch (f.wh) {
        .why => switch (f.modal) {
            .should, .would => .justify,
            else => .cause,
        },
        .how => .means,
        .what => switch (f.modal) {
            .should, .would, .can => .advise,
            else => .define,
        },
        .where, .when => .place,
        .who => .agent,
        .which => .define,
        .none => if (f.modal != .none and subjects >= 2) .yesno else .define,
    };
}

const stop_words = [_][]const u8{
    "what", "why", "how", "where", "who", "when", "which", "is", "are", "was", "were", "does", "do", "did",
    "should", "must", "ought", "would", "could", "can", "may", "might", "will", "a", "an", "the", "of", "and",
    "or", "to", "it", "its", "this", "that", "there", "difference", "differ", "between", "versus", "vs",
    "than", "like", "similar", "different", "compare", "cause", "causes", "mean", "means", "from", "i", "we",
    "you", "they", "be", "been", "being", "matter", "about", "for", "in", "on", "at", "by", "with", "so", "not",
    "no", "yes", "if", "then", "any", "get", "go", "use", "make", "have", "has", "had", "one", "someone",
};

pub fn parseQuestion(gpa: std.mem.Allocator, t: Table, text: []const u8) !?Question {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var sp = tok.Spellings.init(a);
    // quoted phrase => idiom
    if (std.mem.indexOfScalar(u8, text, '"')) |q0| {
        if (std.mem.indexOfScalarPos(u8, text, q0 + 1, '"')) |q1| {
            var toks: std.ArrayList(u64) = .empty;
            try tok.tokenize(a, text[q0 + 1 .. q1], &toks, &sp);
            var name: std.ArrayList(u8) = .empty;
            for (toks.items, 0..) |h, i| {
                if (i > 0) try name.append(a, ' ');
                try name.appendSlice(a, sp.get(h).?);
            }
            const unit = tok.fnv(name.items) ^ 0x1D10_0000_0000_0001;
            if (t.acc.find(unit) != null) return Question{ .kind = .idiom, .subject = unit };
        }
    }
    var toks: std.ArrayList(u64) = .empty;
    try tok.tokenize(a, text, &toks, &sp);
    var words: std.ArrayList([]const u8) = .empty;
    for (toks.items) |h| {
        const w = sp.get(h).?;
        if (w.len == 1 and std.mem.indexOfScalar(u8, ".,?!;:\n", w[0]) != null) continue;
        try words.append(a, w);
    }
    const frame = frameOf(words.items);
    var subj: [2]u64 = .{ 0, 0 };
    var n: usize = 0;
    var cue = false;
    for (words.items) |w| {
        var is_stop = false;
        for (stop_words) |sw| if (std.mem.eql(u8, sw, w)) {
            is_stop = true;
        };
        if (std.mem.eql(u8, w, "difference") or std.mem.eql(u8, w, "differ") or std.mem.eql(u8, w, "between") or
            std.mem.eql(u8, w, "versus") or std.mem.eql(u8, w, "vs") or std.mem.eql(u8, w, "compare") or
            std.mem.eql(u8, w, "similar") or std.mem.eql(u8, w, "like") or std.mem.eql(u8, w, "than")) cue = true;
        const h = tok.fnv(w);
        if (is_stop or n >= 2 or t.acc.find(h) == null) continue;
        subj[n] = h;
        n += 1;
    }
    if (n == 0) return null;
    return Question{ .kind = kindOf(frame, n, cue), .subject = subj[0], .other = subj[1], .frame = frame };
}

pub fn rankOf(a: std.mem.Allocator, t: Table, subject: u64, target: u64) !?usize {
    const all = try t.readout(a, subject, .both, false, t.acc.used);
    defer a.free(all);
    for (all, 0..) |r, i| if (r.unit == target) return i + 1;
    return null;
}

test "gen: readout recovers learned neighbours; answers are deterministic; idiom gloss is read back" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const aa = ar.allocator();
    var sp = tok.Spellings.init(aa);
    var units: std.ArrayList(u64) = .empty;
    // "zork" is always followed by "blip" and preceded by "snarf"; filler varies.
    var s: u64 = 5;
    var text: std.ArrayList(u8) = .empty;
    for (0..200) |_| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        const f1 = (s >> 40) % 40;
        const f2 = (s >> 20) % 40;
        try text.print(aa, "w{d} snarf zork blip w{d}\n", .{ f1, f2 });
        for (0..4) |_| { // filler lines without zork, so frequencies are not dominated by the pattern
            s = s *% 6364136223846793005 +% 1442695040888963407;
            try text.print(aa, "w{d} w{d} w{d} w{d} w{d}\n", .{ (s >> 40) % 40, (s >> 30) % 40, (s >> 20) % 40, (s >> 10) % 40, s % 40 });
        }
    }
    try tok.tokenize(aa, text.items, &units, &sp);
    var acc = try ctx.Acc.init(a, 10);
    defer acc.deinit();
    try acc.centers(units.items, 0, units.items.len, 3);
    const zork = tok.fnv("zork");
    const gloss = [_]u64{ tok.fnv("alpha"), tok.fnv("beta") };
    try sp.put(gloss[0], "alpha");
    try sp.put(gloss[1], "beta");
    try acc.glossAuto(zork, &gloss, 16);

    const t = Table{ .acc = &acc, .sp = &sp, .window = 3, .peel = 1 };
    const fol = try t.readout(a, zork, .right, false, 3);
    defer a.free(fol);
    try std.testing.expectEqualStrings("blip", t.spell(fol[0].unit));
    const pre = try t.readout(a, zork, .left, false, 3);
    defer a.free(pre);
    try std.testing.expectEqualStrings("snarf", t.spell(pre[0].unit));
    const gl = try t.readout(a, zork, .right, true, 2);
    defer a.free(gl);
    try std.testing.expect(gl.len == 2);
    for (gl) |g| try std.testing.expect(g.unit == gloss[0] or g.unit == gloss[1]);

    var w = Weights{};
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(a);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(a);
    var r1 = try Realiser.init(a, t, .{ .kind = .define, .subject = zork }, &w);
    defer r1.deinit();
    try r1.render(&out1, 3);
    var r2 = try Realiser.init(a, t, .{ .kind = .define, .subject = zork }, &w);
    defer r2.deinit();
    try r2.render(&out2, 3);
    try std.testing.expectEqualStrings(out1.items, out2.items);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "blip") != null);
}

test "gen: question frames cover the wh x modal grid" {
    const cases = [_]struct { q: []const u8, k: AnswerType }{
        .{ .q = "what is pizza", .k = .define },
        .{ .q = "what should pizza", .k = .advise },
        .{ .q = "why does pizza", .k = .cause },
        .{ .q = "why should pizza", .k = .justify },
        .{ .q = "why would pizza", .k = .justify },
        .{ .q = "how can pizza", .k = .means },
        .{ .q = "how should pizza", .k = .means },
        .{ .q = "where should pizza", .k = .place },
        .{ .q = "who should pizza", .k = .agent },
        .{ .q = "who can pizza", .k = .agent },
    };
    for (cases) |c| {
        var it = std.mem.tokenizeScalar(u8, c.q, ' ');
        var buf: [8][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |w| : (n += 1) buf[n] = w;
        try std.testing.expectEqual(c.k, kindOf(frameOf(buf[0..n]), 1, false));
    }
    var w = [_][]const u8{ "is", "pizza", "a", "sandwich" };
    try std.testing.expectEqual(AnswerType.yesno, kindOf(frameOf(&w), 2, false));
    try std.testing.expectEqual(AnswerType.compare, kindOf(frameOf(&w), 2, true));
}
