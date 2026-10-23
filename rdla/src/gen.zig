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

pub const AnswerType = enum { define, cause, compare, yesno, idiom };

pub const Src = enum {
    subject, // the question's first subject
    other, // the question's second subject
    follows, // units that come after the subject
    precedes, // units that come before it
    near, // either side
    shared, // near BOTH subjects
    gloss, // taught gloss of an idiom
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
const yesno_t = [_]Template{
    &.{ L.s(.other), L.t(" ranks "), L.s(.shared), L.t(" among the units closest to "), L.s(.subject), L.t(".") },
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
    templates: [5][8]u32 = @splat(@splat(1)),
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

    pub fn spell(self: Table, h: u64) []const u8 {
        return self.sp.get(h) orelse "?";
    }

    fn isBoundary(self: Table, h: u64) bool {
        const s = self.spell(h);
        return s.len == 1 and (s[0] == '.' or s[0] == ',' or s[0] == '?' or s[0] == '!' or s[0] == ';' or s[0] == ':' or s[0] == '\n');
    }

    /// Adds, for every candidate unit v, score(v) += sum_d bundle[d] * sign(seed(v) ^ role) into `out`.
    fn accumulate(self: Table, bundle: []const i32, offsets: []const i32, scores: []f64) void {
        const acc = self.acc;
        for (acc.keys, 0..) |k, i| {
            if (k == 0) continue;
            const sv = ctx.seedVec(k);
            var tot: f64 = 0;
            for (offsets) |o| {
                const r = if (o == 0) ctx.seedVec(ctx.GLOSS_ROLE) else ctx.role(o);
                const v = ctx.bind(sv, r);
                var dot: i64 = 0;
                for (v, 0..) |w, wi| {
                    var b: usize = 0;
                    while (b < 64) : (b += 1) {
                        const x = bundle[wi * 64 + b];
                        dot += if ((w >> @intCast(b)) & 1 == 1) x else -x;
                    }
                }
                tot += @floatFromInt(dot);
            }
            scores[i] += tot;
        }
    }

    /// Top `k` units for `unit` on `side` (offset 0 = the gloss role). Boundary tokens and units
    /// seen fewer than `min_count` times are skipped. Score is lift-corrected: raw readout divided
    /// by the square root of the candidate's frequency, so ubiquitous words do not win by volume.
    pub fn readout(self: Table, a: std.mem.Allocator, unit: u64, side: Side, gloss: bool, k: usize) ![]Ranked {
        const acc = self.acc;
        const slot = acc.find(unit) orelse return a.alloc(Ranked, 0);
        const scores = try a.alloc(f64, acc.keys.len);
        defer a.free(scores);
        @memset(scores, 0);
        var offs: [16]i32 = undefined;
        var n: usize = 0;
        if (gloss) {
            offs[0] = 0;
            n = 1;
            self.accumulate(acc.right[slot * ctx.D ..][0..ctx.D], offs[0..n], scores);
        } else {
            var o: i32 = 1;
            while (o <= self.window) : (o += 1) {
                offs[n] = o;
                n += 1;
            }
            if (side != .left) self.accumulate(acc.right[slot * ctx.D ..][0..ctx.D], offs[0..n], scores);
            if (side != .right) self.accumulate(acc.left[slot * ctx.D ..][0..ctx.D], offs[0..n], scores);
        }
        // Each attestation adds ~D to its candidate's dot, so dot/D estimates the co-occurrence count n
        // (plus leakage noise, below). Rank by the collocation z-score (n - expected) / sqrt(expected + 1), where expected is
        // what independent frequencies would give. Ubiquitous words and one-off accidents both score low.
        var total: f64 = 0;
        for (acc.count) |c| total += @floatFromInt(c);
        const fs: f64 = @floatFromInt(acc.count[slot]);
        const sides: f64 = if (side == .both) 2 else 1;
        const reach: f64 = @as(f64, @floatFromInt(self.window)) * sides;
        // Readout noise: a strong association in the bundle leaks into every unrelated candidate's dot
        // with sd ||bundle||, so that much uncertainty (in counts) must be allowed for before a score counts.
        var noise_var: f64 = 0;
        const per_offset: f64 = if (gloss) 1 else @floatFromInt(self.window);
        if (gloss or side != .left) noise_var += per_offset * bundleNorm2(acc.right[slot * ctx.D ..][0..ctx.D]);
        if (!gloss and side != .right) noise_var += per_offset * bundleNorm2(acc.left[slot * ctx.D ..][0..ctx.D]);
        noise_var /= @as(f64, ctx.D) * @as(f64, ctx.D);
        var list: std.ArrayList(Ranked) = .empty;
        errdefer list.deinit(a);
        for (acc.keys, 0..) |key, i| {
            if (key == 0 or key == unit) continue;
            if (self.isBoundary(key)) continue;
            const cnt = scores[i] / @as(f64, ctx.D);
            var score: f64 = cnt;
            if (gloss) {
                if (cnt < 1) continue;
            } else {
                if (cnt < 3 or acc.count[i] < 5) continue;
                const fv: f64 = @floatFromInt(acc.count[i]);
                const expected = fs * fv * reach / total;
                score = (cnt - expected) / @sqrt(expected + 1 + noise_var); // collocation z-score
                if (score < 4) continue;
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
};

const max_depth = 3;
const pool_n = 12;

pub const Realiser = struct {
    a: std.mem.Allocator,
    t: Table,
    q: Question,
    w: *Weights,
    pools: [7][]Ranked = @splat(&.{}),
    cursor: [7]usize = @splat(0),
    alt_used: [2]usize = @splat(0),

    pub fn init(a: std.mem.Allocator, t: Table, q: Question, w: *Weights) !Realiser {
        var r = Realiser{ .a = a, .t = t, .q = q, .w = w };
        r.pools[@intFromEnum(Src.follows)] = try t.readout(a, q.subject, .right, false, pool_n);
        r.pools[@intFromEnum(Src.precedes)] = try t.readout(a, q.subject, .left, false, pool_n);
        r.pools[@intFromEnum(Src.near)] = try t.readout(a, q.subject, .both, false, pool_n);
        if (q.kind == .idiom) r.pools[@intFromEnum(Src.gloss)] = try t.readout(a, q.subject, .right, true, pool_n);
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
            .other => self.q.other,
            else => blk: {
                const i = @intFromEnum(s);
                const p = self.pools[i];
                if (p.len == 0) break :blk null;
                const c = self.cursor[i];
                self.cursor[i] += 1;
                break :blk p[c % p.len].unit;
            },
        };
        try out.appendSlice(self.a, if (u) |x| self.t.spell(x) else "(nothing learned)");
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
            const idx = pickAvoiding(self.w.templates[@intFromEnum(self.q.kind)][0..ts.len], used[0..ts.len]);
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
    const stop = [_][]const u8{ "what", "is", "are", "a", "an", "the", "why", "does", "do", "how", "of", "and", "vs", "versus", "between", "difference", "than", "to", "was", "were", "did", "can", "it", "?", ".", ",", "\n", "cause", "causes", "mean", "means", "like", "similar", "or", "from", "different" };
    var subj: [2]u64 = .{ 0, 0 };
    var n: usize = 0;
    var kind: AnswerType = .define;
    for (toks.items) |h| {
        const s = sp.get(h).?;
        if (std.mem.eql(u8, s, "why") or std.mem.eql(u8, s, "cause") or std.mem.eql(u8, s, "causes")) kind = .cause;
        var is_stop = false;
        for (stop) |sw| if (std.mem.eql(u8, sw, s)) {
            is_stop = true;
        };
        if (is_stop or n >= 2 or t.acc.find(h) == null) continue;
        subj[n] = h;
        n += 1;
    }
    if (n == 0) return null;
    const lower_first = if (toks.items.len > 0) sp.get(toks.items[0]).? else "";
    if (n == 2) {
        const has = struct {
            fn f(hay: []const u8, needle: []const u8) bool {
                return std.ascii.indexOfIgnoreCase(hay, needle) != null;
            }
        }.f;
        if (kind != .cause) kind = if (has(text, "differ") or has(text, "vs") or has(text, "versus") or has(text, "compare") or has(text, "between") or has(text, "similar") or has(text, "like")) .compare else .yesno;
        if (kind != .cause and (std.mem.eql(u8, lower_first, "is") or std.mem.eql(u8, lower_first, "are") or std.mem.eql(u8, lower_first, "does") or std.mem.eql(u8, lower_first, "do"))) kind = if (kind == .compare) .compare else .yesno;
    }
    return Question{ .kind = kind, .subject = subj[0], .other = subj[1] };
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

    const t = Table{ .acc = &acc, .sp = &sp, .window = 3 };
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
