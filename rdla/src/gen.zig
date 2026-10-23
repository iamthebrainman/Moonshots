//! gen.zig - the answer realiser: a Dada-engine style recursive transition network whose slots are
//! filled by reading the tape through lenses (lens.zig). A question picks an answer type; the answer
//! type picks a lens (which slot requirement to look through) and a template set. A template is used
//! only if every slot it needs was found in the tape; otherwise the next template is tried, and if
//! none can be filled the answer says the tape does not say. Nothing is scored or thresholded.
const std = @import("std");
const tok = @import("tok.zig");
const lens = @import("lens.zig");

pub const AnswerType = enum {
    define, // what is / what are
    cause, // why does / why is / why did
    justify, // why should / why would / why must
    means, // how can / how should / how does / how to
    advise, // what should / what would / what can
    place, // where is / where should / where does
    agent, // who is / who should / who can
    compare, // difference between / X vs Y / X like Y
    yesno, // aux-first question, resolved to confirm / correct at render time
    confirm, // "Yes, S is a T ..."
    correct, // "No, S is a X, which is a type of Z."
    idiom, // "phrase" means ...
};

pub const Wh = enum { none, what, why, how, where, who, when, which };
pub const Modal = enum { none, is, does, should, would, can, will };
pub const Frame = struct { wh: Wh, modal: Modal };

pub const Question = struct {
    kind: AnswerType,
    subject: u32, // unit ids; maxInt = none
    other: u32 = none,
    rest: [4]u32 = .{ none, none, none, none }, // yes/no: everything after the subject that names the claimed type
    nrest: u8 = 0,
    rest_unknown: bool = false, // the claim names a word the tape has never seen
    frame: Frame = .{ .wh = .none, .modal = .none },
    pub const none = std.math.maxInt(u32);
};

// ---------------------------------------------------------------------------------------------
// Question frames: wh-word x modal -> answer type
// ---------------------------------------------------------------------------------------------

fn whOf(w: []const u8) Wh {
    inline for (.{ "what", "why", "how", "where", "who", "when", "which" }, 1..) |name, k| {
        if (std.mem.eql(u8, w, name)) return @enumFromInt(k);
    }
    return .none;
}

fn modalOf(w: []const u8) Modal {
    const tbl = .{
        .{ "is", Modal.is },         .{ "are", Modal.is },       .{ "was", Modal.is },  .{ "were", Modal.is },
        .{ "does", Modal.does },     .{ "do", Modal.does },      .{ "did", Modal.does },
        .{ "should", Modal.should }, .{ "must", Modal.should },  .{ "ought", Modal.should },
        .{ "would", Modal.would },   .{ "could", Modal.would },
        .{ "can", Modal.can },       .{ "may", Modal.can },      .{ "might", Modal.can },
        .{ "will", Modal.will },
    };
    inline for (tbl) |e| if (std.mem.eql(u8, w, e[0])) return e[1];
    return .none;
}

pub fn frameOf(words: []const []const u8) Frame {
    if (words.len == 0) return .{ .wh = .none, .modal = .none };
    const wh = whOf(words[0]);
    if (wh != .none) return .{ .wh = wh, .modal = if (words.len > 1) modalOf(words[1]) else .none };
    return .{ .wh = .none, .modal = modalOf(words[0]) };
}

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
    "no", "yes", "if", "then", "any", "get", "go", "use", "make", "have", "has", "had", "one", "someone", "people",
};

/// Subjects are the words of the question the tape knows and the question's grammar does not own;
/// when there are more than two, the most specific (fewest occurrences) win, kept in question order.
pub fn parseQuestion(gpa: std.mem.Allocator, ix: *const lens.Index, text: []const u8) !?Question {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var sp = tok.Spellings.init(a);
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
            if (ix.idOf(unit)) |id| return Question{ .kind = .idiom, .subject = id };
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
    var cands: std.ArrayList(u32) = .empty;
    var unknown_after_first = false;
    var cue = false;
    for (words.items) |w| {
        var is_stop = false;
        for (stop_words) |sw| if (std.mem.eql(u8, sw, w)) {
            is_stop = true;
        };
        for ([_][]const u8{ "difference", "differ", "between", "versus", "vs", "compare", "similar", "like", "than" }) |c|
            if (std.mem.eql(u8, c, w)) {
                cue = true;
            };
        if (is_stop) continue;
        const id = ix.idOfWord(w) orelse {
            if (cands.items.len > 0) unknown_after_first = true;
            continue;
        };
        var dup = false;
        for (cands.items) |c| if (c == id) {
            dup = true;
        };
        if (!dup) try cands.append(a, id);
    }
    if (cands.items.len == 0) return null;
    // aux-first claim ("is X a Y Z?"): X is the subject, everything after it is the claimed type
    if (frame.wh == .none and frame.modal != .none and !cue and (cands.items.len > 1 or unknown_after_first)) {
        var q = Question{ .kind = .yesno, .subject = cands.items[0], .frame = frame, .rest_unknown = unknown_after_first };
        for (cands.items[1..]) |c| if (q.nrest < 4) {
            q.rest[q.nrest] = c;
            q.nrest += 1;
        };
        return q;
    }
    // keep the (up to) two most specific, in question order
    while (cands.items.len > 2) {
        var worst: usize = 0;
        for (cands.items, 0..) |c, i| if (ix.count(c) > ix.count(cands.items[worst])) {
            worst = i;
        };
        _ = cands.orderedRemove(worst);
    }
    const subj = cands.items[0];
    const other = if (cands.items.len > 1) cands.items[1] else Question.none;
    return Question{ .kind = kindOf(frame, cands.items.len, cue), .subject = subj, .other = other, .frame = frame };
}

// ---------------------------------------------------------------------------------------------
// Slot sources, templates, sub-grammars
// ---------------------------------------------------------------------------------------------

pub const Src = enum {
    subject,
    other,
    m0, // 1st / 2nd / 3rd attested phrase of the answer type's lens
    m1,
    m2,
    a0, // subject's 1st / 2nd "is a" phrase, with a/an
    a1,
    b0, // second subject's 1st "is a" phrase, with a/an
    c0b, // same, bare
    cl0, // attested clauses of the answer lens
    cl1,
    c0, // the "is a" phrase of a0's head noun (its type), with a/an
    gloss, // taught idiom gloss, in order
};

pub const NT = enum { also };

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
    &.{ L.s(.subject), L.t(" is "), L.s(.a0), L.n(.also), L.t(".") },
};
const cause_t = [_]Template{
    &.{ L.s(.cl0), L.t(", and "), L.s(.cl1), L.t(".") },
    &.{ L.s(.cl0), L.t(".") },
};
const justify_t = [_]Template{
    &.{ L.t("Because "), L.s(.m0), L.t(".") },
    &.{ L.t("One reason is that "), L.s(.m0), L.t("; another is that "), L.s(.m1), L.t(".") },
};
const means_t = [_]Template{
    &.{ L.s(.cl0), L.t(", and "), L.s(.cl1), L.t(".") },
    &.{ L.s(.cl0), L.t(".") },
};
const advise_t = [_]Template{
    &.{ L.s(.cl0), L.t(".") },
};
const place_t = [_]Template{
    &.{ L.s(.cl0), L.t("; also "), L.s(.cl1), L.t(".") },
    &.{ L.s(.cl0), L.t(".") },
};
const agent_t = [_]Template{
    &.{ L.s(.cl0), L.t("; also "), L.s(.cl1), L.t(".") },
    &.{ L.s(.cl0), L.t(".") },
};
const compare_t = [_]Template{
    &.{ L.s(.subject), L.t(" is "), L.s(.a0), L.t(", while "), L.s(.other), L.t(" is "), L.s(.b0), L.t(".") },
};
const confirm_t = [_]Template{
    &.{ L.t("Yes, "), L.s(.subject), L.t(" is "), L.s(.a0), L.t(", which is a type of "), L.s(.c0b), L.t(".") },
    &.{ L.t("Yes, "), L.s(.subject), L.t(" is "), L.s(.a0), L.t(".") },
};
const correct_t = [_]Template{
    &.{ L.t("No, "), L.s(.subject), L.t(" is "), L.s(.a0), L.t(", which is a type of "), L.s(.c0b), L.t(".") },
    &.{ L.t("No, "), L.s(.subject), L.t(" is "), L.s(.a0), L.t(".") },
};
const idiom_t = [_]Template{
    &.{ L.t("\""), L.s(.subject), L.t("\" means "), L.s(.gloss), L.t(".") },
};

fn templatesFor(k: AnswerType) []const Template {
    return switch (k) {
        .define => &define_t,
        .cause => &cause_t,
        .justify => &justify_t,
        .means => &means_t,
        .advise => &advise_t,
        .place => &place_t,
        .agent => &agent_t,
        .compare => &compare_t,
        .yesno => &confirm_t,
        .confirm => &confirm_t,
        .correct => &correct_t,
        .idiom => &idiom_t,
    };
}

/// Sub-grammar alternatives; the first whose sources are all present is used.
fn altsFor(n: NT) []const Template {
    return switch (n) {
        .also => &also_alts,
    };
}
const also_alts = [_]Template{
    &.{ L.t(", and also "), L.s(.a1) },
    &.{},
};

// the lens each answer type looks through
const because_ops = [_][]const []const u8{ &.{"because"}, &.{ "due", "to" }, &.{"since"}, &.{ "as", "a", "result", "of" } };
const reason_ops = [_][]const []const u8{ &.{"because"}, &.{ "so", "that" }, &.{ "in", "order", "to" } };
const way_ops = [_][]const []const u8{ &.{"by"}, &.{"through"}, &.{"using"}, &.{"via"} };
const modal_ops = [_][]const []const u8{ &.{"should"}, &.{"must"}, &.{ "needs", "to" }, &.{ "ought", "to" } };
const where_ops = [_][]const []const u8{ &.{"in"}, &.{"at"}, &.{"near"}, &.{ "located", "in" }, &.{ "found", "in" } };
const who_ops = [_][]const []const u8{ &.{"by"}, &.{ "founded", "by" }, &.{ "invented", "by" }, &.{ "played", "by" }, &.{ "created", "by" } };

fn lensFor(k: AnswerType) ?lens.Lens {
    return switch (k) {
        .cause => .{ .ops = &because_ops, .gap = 12, .max_words = 7, .stop_at_func = false },
        .justify => .{ .ops = &reason_ops, .gap = 12, .max_words = 7, .stop_at_func = false },
        .means => .{ .ops = &way_ops, .gap = 6, .max_words = 5, .stop_at_func = false },
        .advise => .{ .ops = &modal_ops, .gap = 2, .max_words = 5, .stop_at_func = false },
        .place => .{ .ops = &where_ops, .gap = 3, .max_words = 3, .stop_at_func = false },
        .agent => .{ .ops = &who_ops, .gap = 3, .max_words = 3, .stop_at_func = false },
        else => null,
    };
}

pub const Answer = struct {
    text: []u8,
    /// tape position of the first matching occurrence, for the evidence line
    evidence_pos: ?u32 = null,
    kind: AnswerType,
};

const MissingSource = error{Missing};

pub const Realiser = struct {
    a: std.mem.Allocator,
    ix: *const lens.Index,
    q: Question,
    matches: []lens.Match = &.{}, // the answer type's own lens
    a_m: []lens.Match = &.{}, // subject's "is a" phrases
    b_m: []lens.Match = &.{}, // second subject's
    c_m: []lens.Match = &.{}, // type of a0's head noun
    evidence: ?u32 = null,

    pub fn init(a: std.mem.Allocator, ix: *const lens.Index, q0: Question) !Realiser {
        var r = Realiser{ .a = a, .ix = ix, .q = q0 };
        if (lensFor(q0.kind)) |l| r.matches = try lens.find(a, ix, q0.subject, l);
        const needs_isa = switch (q0.kind) {
            .define, .compare, .yesno, .confirm, .correct => true,
            else => false,
        };
        if (needs_isa) {
            r.a_m = try lens.find(a, ix, q0.subject, lens.isa_lens);
            if (r.a_m.len > 0) {
                const m = r.a_m[0];
                r.c_m = try lens.find(a, ix, m.ids[m.len - 1], lens.isa_lens);
                // only definitional (title-led / paragraph-initial) statements may name a type
                if (r.c_m.len > 0 and r.c_m[0].prio > 1) r.c_m = r.c_m[0..0];
            }
            if (q0.other != Question.none) r.b_m = try lens.find(a, ix, q0.other, lens.isa_lens);
        }
        if (q0.kind == .yesno) {
            // Yes if every word of the claimed type is in some attested "subject is a ..." phrase or in
            // the type of its head noun; a claimed word the tape has never seen cannot be.
            var all = q0.nrest > 0 and !q0.rest_unknown;
            for (q0.rest[0..q0.nrest]) |w| {
                var found = false;
                for (r.a_m) |m| for (m.ids[0..m.len]) |id| {
                    if (id == w) found = true;
                };
                for (r.c_m) |m| for (m.ids[0..m.len]) |id| {
                    if (id == w) found = true;
                };
                if (!found) all = false;
            }
            if (r.a_m.len > 0) r.q.kind = if (all) .confirm else .correct;
        }
        if (r.matches.len > 0) r.evidence = r.matches[0].pos else if (r.a_m.len > 0) r.evidence = r.a_m[0].pos;
        return r;
    }

    pub fn deinit(self: *Realiser) void {
        self.a.free(self.matches);
        self.a.free(self.a_m);
        self.a.free(self.b_m);
        self.a.free(self.c_m);
    }

    fn article(self: *Realiser, out: *std.ArrayList(u8), m: lens.Match) !void {
        const first = self.ix.spell(m.ids[0]);
        const vowel = first.len > 0 and std.mem.indexOfScalar(u8, "aeiou", first[0]) != null;
        try out.appendSlice(self.a, if (vowel) "an " else "a ");
    }

    fn emit(self: *Realiser, out: *std.ArrayList(u8), s: Src) !void {
        switch (s) {
            .subject => try out.appendSlice(self.a, self.ix.spell(self.q.subject)),
            .other => {
                if (self.q.other == Question.none) return MissingSource.Missing;
                try out.appendSlice(self.a, self.ix.spell(self.q.other));
            },
            .m0, .m1, .m2 => {
                const k = @intFromEnum(s) - @intFromEnum(Src.m0);
                if (k >= self.matches.len) return MissingSource.Missing;
                try lens.phraseText(self.a, self.ix, self.matches[k], out);
            },
            .cl0, .cl1 => {
                const k = @intFromEnum(s) - @intFromEnum(Src.cl0);
                if (k >= self.matches.len) return MissingSource.Missing;
                try out.appendSlice(self.a, self.ix.spell(self.q.subject));
                try out.append(self.a, ' ');
                try lens.clauseText(self.a, self.ix, self.matches[k], out);
            },
            .c0b => {
                if (self.c_m.len == 0) return MissingSource.Missing;
                try lens.phraseText(self.a, self.ix, self.c_m[0], out);
            },
            .a0, .a1 => {
                const k = @intFromEnum(s) - @intFromEnum(Src.a0);
                if (k >= self.a_m.len or (k > 0 and self.a_m[k].prio > 1)) return MissingSource.Missing;
                try self.article(out, self.a_m[k]);
                try lens.phraseText(self.a, self.ix, self.a_m[k], out);
            },
            .b0 => {
                if (self.b_m.len == 0) return MissingSource.Missing;
                try self.article(out, self.b_m[0]);
                try lens.phraseText(self.a, self.ix, self.b_m[0], out);
            },
            .c0 => {
                if (self.c_m.len == 0) return MissingSource.Missing;
                try self.article(out, self.c_m[0]);
                try lens.phraseText(self.a, self.ix, self.c_m[0], out);
            },
            .gloss => {
                const g = self.ix.glossOf(self.ix.units[self.q.subject]) orelse return MissingSource.Missing;
                if (g.len == 0) return MissingSource.Missing;
                for (g, 0..) |h, i| {
                    if (i > 0) try out.append(self.a, ' ');
                    const id = self.ix.idOf(h) orelse return MissingSource.Missing;
                    try out.appendSlice(self.a, self.ix.spell(id));
                }
            },
        }
    }

    fn renderParts(self: *Realiser, out: *std.ArrayList(u8), parts: Template, depth: usize) anyerror!void {
        for (parts) |p| switch (p) {
            .lit => |l| try out.appendSlice(self.a, l),
            .src => |s| try self.emit(out, s),
            .sub => |n| {
                if (depth >= 3) continue;
                // first alternative whose sources are all present
                for (altsFor(n)) |alt| {
                    const mark = out.items.len;
                    if (self.renderParts(out, alt, depth + 1)) |_| break else |e| {
                        out.shrinkRetainingCapacity(mark);
                        if (e != MissingSource.Missing) return e;
                    }
                }
            },
        };
    }

    /// The first template whose every slot the tape can fill; else an honest "the tape does not say".
    pub fn render(self: *Realiser) !Answer {
        var out: std.ArrayList(u8) = .empty;
        for (templatesFor(self.q.kind)) |t| {
            out.clearRetainingCapacity();
            if (self.renderParts(&out, t, 0)) |_| {
                if (out.items.len > 0) out.items[0] = std.ascii.toUpper(out.items[0]);
                return .{ .text = try out.toOwnedSlice(self.a), .evidence_pos = self.evidence, .kind = self.q.kind };
            } else |e| if (e != MissingSource.Missing) return e;
        }
        out.clearRetainingCapacity();
        try out.print(self.a, "The tape does not say ({s} of \"{s}\").", .{ @tagName(self.q.kind), self.ix.spell(self.q.subject) });
        return .{ .text = try out.toOwnedSlice(self.a), .evidence_pos = null, .kind = self.q.kind };
    }
};

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

const idiom = @import("idiom.zig");

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

fn ask(a: std.mem.Allocator, ix: *const lens.Index, q: []const u8) ![]u8 {
    const qq = (try parseQuestion(a, ix, q)) orelse return a.dupe(u8, "(no known subject)");
    var r = try Realiser.init(a, ix, qq);
    const ans = try r.render();
    return ans.text;
}

test "gen: answers come from the tape; yes/no corrects with the attested type; missing slots are admitted" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const aa = ar.allocator();
    var sp = tok.Spellings.init(aa);
    var toks: std.ArrayList(u64) = .empty;
    const text =
        \\Pizza is an Italian dish.
        \\
        \\An Italian dish is a food. Pizza was invented in Naples.
        \\
        \\Tetris is a video game. The cook will dish out the soup.
        \\
        \\A cat is an animal.
        \\Scurvy happens because people lack vitamin c on long voyages.
        \\Many things happen in many places and the people go to the market and the park and the shop and the house and the school.
        \\
    ;
    try tok.tokenize(aa, text, &toks, &sp);
    var bad: usize = 0;
    var es = try idiom.parse(aa, "\"figure out\" means to understand by calculating\n", &sp, &bad);
    const hits = try aa.alloc(usize, es.list.items.len);
    @memset(hits, 0);
    var fused = try idiom.fuse(aa, toks.items, &es, hits);
    for (es.list.items) |e| try sp.put(e.unit, e.name);
    const img = try lens.build(aa, fused.items, &sp, &es);
    var ix = try lens.Index.fromBytes(aa, img);

    const expect = [_][2][]const u8{
        .{ "What is pizza?", "Pizza is an italian dish." },
        .{ "Is pizza a food?", "Yes, pizza is an italian dish, which is a type of food." },
        .{ "Is pizza a sandwich?", "No, pizza is an italian dish, which is a type of food." },
        .{ "Is tetris a video game?", "Yes, tetris is a video game." },
        .{ "Why does scurvy happen?", "Scurvy happens because people lack vitamin c on long voyages." },
        .{ "Where was pizza invented?", "Pizza was invented in naples." },
        .{ "What is a cat?", "Cat is an animal." },
        .{ "What does \"figure out\" mean?", "\"figure out\" means to understand by calculating." },
        .{ "What is the difference between pizza and tetris?", "Pizza is an italian dish, while tetris is a video game." },
        .{ "What is zzzzz?", "(no known subject)" },
        .{ "How can scurvy be cured?", "The tape does not say (means of \"scurvy\")." },
    };
    for (expect) |e| try std.testing.expectEqualStrings(e[1], try ask(aa, &ix, e[0]));
    _ = &fused;
}
