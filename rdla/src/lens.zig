//! lens.zig - the tape and its positions index, memory-mapped, and the lens that reads it.
//!
//! The file holds the TAPE (every token, in order, exactly as ingested) plus an inverted index
//! (unit -> every position it occurs at) and the spellings. Nothing is extracted or summarised at
//! build time. A question is a slot requirement (a Lens); answering walks the occurrences of the
//! subject through the index and reads the tape around each one. Every match is a real place in the
//! tape, so each answer can point at its evidence, and different senses ("an Italian dish", "dish
//! out", "satellite dish") are different occurrences and stay apart.
//!
//! Layout (little-endian, sections 64-byte aligned):
//!   Header(128)
//!   units   [nunits]u64   unit hashes, sorted ascending (the unit id is the rank)
//!   tape    [n]u32        unit id per token position
//!   offs    [nunits+1]u64 start of each unit's positions in `pos`
//!   pos     [n]u32        positions, grouped by unit id, ascending within a unit
//!   spoffs  [nunits+1]u64 + spblob: spellings
//!   gloss   u64 count, then per entry: unit hash, ntok, ntok token hashes (taught idiom glosses, in order)
const std = @import("std");
const Io = std.Io;
const tok = @import("tok.zig");
const idiom = @import("idiom.zig");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) @compileError("lens.zig needs a little-endian target");
}

pub const MAGIC = [8]u8{ 'R', 'D', 'L', 'T', 0x00, 0x01, 0x00, 0x01 };

pub const Header = extern struct {
    magic: [8]u8 = MAGIC,
    version: u32 = 1,
    pad: u32 = 0,
    n: u64 = 0,
    nunits: u64 = 0,
    off_units: u64 = 0,
    off_tape: u64 = 0,
    off_offs: u64 = 0,
    off_pos: u64 = 0,
    off_spoffs: u64 = 0,
    off_spblob: u64 = 0,
    spblob_len: u64 = 0,
    off_gloss: u64 = 0,
    gloss_len: u64 = 0,
    total: u64 = 0,
    reserved: [2]u64 = .{ 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Header) == 128);
}

pub const Error = error{ BadMagic, BadVersion, Truncated };

fn spOf(sp: *const tok.Spellings, h: u64) []const u8 {
    return sp.get(h) orelse "";
}

fn alignUp(x: usize) usize {
    return (x + 63) & ~@as(usize, 63);
}

/// Builds the file image in memory. `tokens` is the unit sequence (idioms already fused).
pub fn build(a: std.mem.Allocator, tokens: []const u64, sp: *const tok.Spellings, entries: *const idiom.Entries) ![]align(64) u8 {
    const n = tokens.len;
    var uniq: std.ArrayList(u64) = .empty;
    defer uniq.deinit(a);
    try uniq.appendSlice(a, tokens);
    // taught idioms and their gloss words are units even if the tape never uses them (spellings must resolve)
    for (entries.list.items) |e| {
        try uniq.append(a, e.unit);
        try uniq.appendSlice(a, e.gloss);
    }
    std.mem.sort(u64, uniq.items, {}, std.sort.asc(u64));
    var w: usize = 0;
    for (uniq.items, 0..) |h, i| {
        if (i == 0 or h != uniq.items[w - 1]) {
            uniq.items[w] = h;
            w += 1;
        }
    }
    uniq.shrinkRetainingCapacity(w);
    const nu = w;

    var sp_len: usize = 0;
    for (uniq.items) |h| sp_len += spOf(sp, h).len;
    var gloss_words: usize = 0;
    for (entries.list.items) |e| gloss_words += 2 + e.gloss.len;

    var h = Header{};
    h.n = n;
    h.nunits = nu;
    var off: usize = 128;
    h.off_units = off;
    off = alignUp(off + nu * 8);
    h.off_tape = off;
    off = alignUp(off + n * 4);
    h.off_offs = off;
    off = alignUp(off + (nu + 1) * 8);
    h.off_pos = off;
    off = alignUp(off + n * 4);
    h.off_spoffs = off;
    off = alignUp(off + (nu + 1) * 8);
    h.off_spblob = off;
    h.spblob_len = sp_len;
    off = alignUp(off + sp_len);
    h.off_gloss = off;
    h.gloss_len = (1 + gloss_words) * 8;
    off = alignUp(off + h.gloss_len);
    h.total = off;

    const img = try a.alignedAlloc(u8, .fromByteUnits(64), off);
    @memset(img, 0);
    @memcpy(img[0..128], std.mem.asBytes(&h));
    const units: []u64 = @as([*]u64, @ptrCast(@alignCast(img.ptr + h.off_units)))[0..nu];
    @memcpy(units, uniq.items);
    const tape: []u32 = @as([*]u32, @ptrCast(@alignCast(img.ptr + h.off_tape)))[0..n];
    const offs: []u64 = @as([*]u64, @ptrCast(@alignCast(img.ptr + h.off_offs)))[0 .. nu + 1];
    const pos: []u32 = @as([*]u32, @ptrCast(@alignCast(img.ptr + h.off_pos)))[0..n];
    for (tokens, 0..) |t, i| {
        const id = std.sort.binarySearch(u64, units, t, struct {
            fn cmp(key: u64, item: u64) std.math.Order {
                return std.math.order(key, item);
            }
        }.cmp).?;
        tape[i] = @intCast(id);
        offs[id + 1] += 1;
    }
    for (1..nu + 1) |i| offs[i] += offs[i - 1];
    const fill = try a.alloc(u64, nu);
    defer a.free(fill);
    @memcpy(fill, offs[0..nu]);
    for (tape, 0..) |id, i| {
        pos[fill[id]] = @intCast(i);
        fill[id] += 1;
    }
    const spoffs: []u64 = @as([*]u64, @ptrCast(@alignCast(img.ptr + h.off_spoffs)))[0 .. nu + 1];
    var at: usize = 0;
    for (units, 0..) |u, i| {
        spoffs[i] = at;
        const s = spOf(sp, u);
        @memcpy(img[h.off_spblob + at ..][0..s.len], s);
        at += s.len;
    }
    spoffs[nu] = at;
    const gl: []u64 = @as([*]u64, @ptrCast(@alignCast(img.ptr + h.off_gloss)))[0 .. h.gloss_len / 8];
    gl[0] = entries.list.items.len;
    var gi: usize = 1;
    for (entries.list.items) |e| {
        gl[gi] = e.unit;
        gl[gi + 1] = e.gloss.len;
        @memcpy(gl[gi + 2 ..][0..e.gloss.len], e.gloss);
        gi += 2 + e.gloss.len;
    }
    return img;
}

pub fn write(io: Io, path: []const u8, img: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, img, 0);
}

pub const Index = struct {
    map: ?[]align(std.heap.page_size_min) u8 = null,
    n: usize,
    units: []const u64,
    tape: []const u32,
    offs: []const u64,
    pos: []const u32,
    spoffs: []const u64,
    spblob: []const u8,
    gloss: []const u64,
    /// unit ids of the most frequent units (function words and punctuation); computed on open
    func: []bool,
    boundary: []bool,
    alloc: std.mem.Allocator,

    pub fn open(io: Io, a: std.mem.Allocator, path: []const u8) !Index {
        const f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        const len = (try f.stat(io)).size;
        if (len < 128) return Error.Truncated;
        const map = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, f.handle, 0);
        errdefer std.posix.munmap(map);
        var ix = try fromBytes(a, map);
        ix.map = map;
        return ix;
    }

    pub fn fromBytes(a: std.mem.Allocator, bytes: []align(64) const u8) !Index {
        if (bytes.len < 128) return Error.Truncated;
        var h: Header = undefined;
        @memcpy(std.mem.asBytes(&h), bytes[0..128]);
        if (!std.mem.eql(u8, &h.magic, &MAGIC)) return Error.BadMagic;
        if (h.version != 1) return Error.BadVersion;
        if (bytes.len < h.total) return Error.Truncated;
        const nu: usize = @intCast(h.nunits);
        const n: usize = @intCast(h.n);
        var ix = Index{
            .n = n,
            .units = @as([*]const u64, @ptrCast(@alignCast(bytes.ptr + h.off_units)))[0..nu],
            .tape = @as([*]const u32, @ptrCast(@alignCast(bytes.ptr + h.off_tape)))[0..n],
            .offs = @as([*]const u64, @ptrCast(@alignCast(bytes.ptr + h.off_offs)))[0 .. nu + 1],
            .pos = @as([*]const u32, @ptrCast(@alignCast(bytes.ptr + h.off_pos)))[0..n],
            .spoffs = @as([*]const u64, @ptrCast(@alignCast(bytes.ptr + h.off_spoffs)))[0 .. nu + 1],
            .spblob = bytes[@intCast(h.off_spblob)..][0..@intCast(h.spblob_len)],
            .gloss = @as([*]const u64, @ptrCast(@alignCast(bytes.ptr + h.off_gloss)))[0..@intCast(h.gloss_len / 8)],
            .func = try a.alloc(bool, nu),
            .boundary = try a.alloc(bool, nu),
            .alloc = a,
        };
        @memset(ix.func, false);
        // Function words are the units present almost everywhere: split the tape into 64 equal stretches;
        // a unit seen in every one of them belongs to no topic ("the", "of", "is"), unlike "sport" or "pizza".
        const segs: usize = @min(64, @max(n / 8, 1));
        const seg_len = (n + segs - 1) / @max(segs, 1);
        for (0..nu) |i| {
            var last: usize = std.math.maxInt(usize);
            var present: usize = 0;
            for (ix.occ(@intCast(i))) |p| {
                const sg = p / @max(seg_len, 1);
                if (sg != last) {
                    present += 1;
                    last = sg;
                }
            }
            ix.func[i] = present == segs;
        }
        for (0..nu) |i| {
            const s = ix.spell(@intCast(i));
            ix.boundary[i] = s.len == 1 and std.mem.indexOfScalar(u8, ".,?!;:\n", s[0]) != null;
        }
        return ix;
    }

    pub fn deinit(self: *Index) void {
        self.alloc.free(self.func);
        self.alloc.free(self.boundary);
        if (self.map) |m| std.posix.munmap(m);
    }

    pub fn count(self: *const Index, id: u32) u64 {
        return self.offs[id + 1] - self.offs[id];
    }

    pub fn idOf(self: *const Index, hash: u64) ?u32 {
        const r = std.sort.binarySearch(u64, self.units, hash, struct {
            fn cmp(key: u64, item: u64) std.math.Order {
                return std.math.order(key, item);
            }
        }.cmp) orelse return null;
        return @intCast(r);
    }

    pub fn idOfWord(self: *const Index, word: []const u8) ?u32 {
        return self.idOf(tok.fnv(word));
    }

    pub fn spell(self: *const Index, id: u32) []const u8 {
        return self.spblob[self.spoffs[id]..self.spoffs[id + 1]];
    }

    pub fn occ(self: *const Index, id: u32) []const u32 {
        return self.pos[self.offs[id]..self.offs[id + 1]];
    }

    pub fn glossOf(self: *const Index, hash: u64) ?[]const u64 {
        var i: usize = 1;
        var k: usize = 0;
        while (k < self.gloss[0]) : (k += 1) {
            const len: usize = @intCast(self.gloss[i + 1]);
            if (self.gloss[i] == hash) return self.gloss[i + 2 ..][0..len];
            i += 2 + len;
        }
        return null;
    }

    /// The sentence around tape position `p`, as text (boundary tokens attach to the previous word).
    pub fn sentence(self: *const Index, a: std.mem.Allocator, p: usize) ![]u8 {
        var lo = p;
        while (lo > 0 and !self.boundary[self.tape[lo - 1]]) lo -= 1;
        var hi = p;
        while (hi < self.n and !self.boundary[self.tape[hi]]) hi += 1;
        if (hi < self.n and self.spell(self.tape[hi])[0] != '\n') hi += 1;
        var out: std.ArrayList(u8) = .empty;
        for (self.tape[lo..hi], 0..) |id, i| {
            const s = self.spell(id);
            if (!self.boundary[id] and i > 0) try out.append(a, ' ');
            try out.appendSlice(a, s);
        }
        return out.toOwnedSlice(a);
    }
};

// ---------------------------------------------------------------------------------------------
// The lens: a slot requirement over the tape
// ---------------------------------------------------------------------------------------------

/// "After the subject, within `gap` tokens, one of these operator word-sequences; the slot it opens is
/// the phrase that follows." Nothing else: no counts, no thresholds.
pub const Lens = struct {
    ops: []const []const []const u8,
    gap: u8 = 0,
    max_words: u8 = 2,
    /// Stop the phrase at the first function word / boundary after it has begun (noun-phrase slots).
    stop_at_func: bool = true,
    /// The subject must head its clause: sentence start, optionally after a determiner. ("dishes similar
    /// to pizza are ..." is not a statement about pizza.)
    subject_initial: bool = false,
    /// Noun-phrase slots end at the first inflected verb/adverb cue (-ly, -ed) after the first word.
    np_end_morph: bool = false,
};

fn endsWith(s: []const u8, suf: []const u8) bool {
    return s.len > suf.len + 1 and std.mem.endsWith(u8, s, suf);
}

pub const Match = struct {
    pos: u32, // subject position in the tape
    start: u32, // first phrase token position
    len: u8,
    ids: [8]u32,
    /// 0 = lead sentence under a title line that names the subject, 1 = paragraph-initial, 2 = anywhere
    prio: u8 = 2,
};

fn opIds(a: std.mem.Allocator, ix: *const Index, op: []const []const u8) !?[]u32 {
    const out = try a.alloc(u32, op.len);
    for (op, 0..) |w, i| out[i] = ix.idOfWord(w) orelse {
        a.free(out);
        return null;
    };
    return out;
}

/// Every distinct phrase the tape attests in `lens`'s slot after `subject`, in tape order.
pub fn find(a: std.mem.Allocator, ix: *const Index, subject: u32, lens: Lens) ![]Match {
    var ops: std.ArrayList([]u32) = .empty;
    defer {
        for (ops.items) |o| a.free(o);
        ops.deinit(a);
    }
    for (lens.ops) |op| if (try opIds(a, ix, op)) |ids| try ops.append(a, ids);

    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(a);
    for (ix.occ(subject)) |p| {
        // clause start: walk back to the previous boundary
        var cs: usize = p;
        var ok = true;
        while (cs > 0 and !ix.boundary[ix.tape[cs - 1]]) {
            cs -= 1;
            if (p - cs > 4) ok = false;
        }
        if (lens.subject_initial) {
            // the subject ends the clause-initial noun phrase: at most 4 tokens since the clause start, and
            // only the first of them may be a function word (a determiner)
            if (ok) for (ix.tape[cs..p], 0..) |id, j| {
                if (j > 0 and ix.func[id]) ok = false;
            };
            if (!ok) continue;
        }
        var prio: u8 = 2;
        if (cs == 0) {
            prio = 1;
        } else if (cs >= 2 and isNl(ix, ix.tape[cs - 1]) and isNl(ix, ix.tape[cs - 2])) {
            prio = 1;
            if (cs >= 3 and ix.tape[cs - 3] == subject) prio = 0;
        }
        var g: usize = 0;
        while (g <= lens.gap) : (g += 1) {
            const q = @as(usize, p) + 1 + g;
            if (q > p + 1 and q - 1 < ix.n and ix.boundary[ix.tape[q - 1]]) break;
            for (ops.items) |op| {
                if (q + op.len >= ix.n) continue;
                if (!std.mem.eql(u32, op, ix.tape[q..][0..op.len])) continue;
                var m = Match{ .pos = p, .start = @intCast(q + op.len), .len = 0, .ids = undefined };
                m.prio = prio;
                var r = q + op.len;
                while (m.len < lens.max_words and r < ix.n) : (r += 1) {
                    const id = ix.tape[r];
                    if (ix.boundary[id]) break;
                    if (lens.stop_at_func and ix.func[id]) {
                        if (m.len > 0) break;
                        continue; // leading determiners are skipped, not part of the phrase
                    }
                    if (lens.np_end_morph and m.len > 0) {
                        const sp_ = ix.spell(id);
                        if (endsWith(sp_, "ly") or endsWith(sp_, "ed")) break;
                    }
                    m.ids[m.len] = id;
                    m.len += 1;
                }
                if (m.len == 0) continue;
                var dup = false;
                for (out.items) |e| if (e.len == m.len and std.mem.eql(u32, e.ids[0..e.len], m.ids[0..m.len])) {
                    dup = true;
                };
                if (!dup) try out.append(a, m);
                break;
            }
        }
    }
    std.sort.block(Match, out.items, {}, struct { // stable: tape order is kept within a priority
        fn lt(_: void, x: Match, y: Match) bool {
            return x.prio < y.prio;
        }
    }.lt);
    return out.toOwnedSlice(a);
}

fn isNl(ix: *const Index, id: u32) bool {
    return ix.boundary[id] and ix.spell(id)[0] == '\n';
}

/// The attested clause: the tape words from just after the subject through the end of the phrase.
pub fn clauseText(a: std.mem.Allocator, ix: *const Index, m: Match, out: *std.ArrayList(u8)) !void {
    const end = m.start + m.len;
    var p: usize = m.pos + 1;
    // include the stretch up to the phrase start, then the phrase words
    while (p < end and p < ix.n) : (p += 1) {
        if (p > m.pos + 1) try out.append(a, ' ');
        try out.appendSlice(a, ix.spell(ix.tape[p]));
    }
}

pub fn phraseText(a: std.mem.Allocator, ix: *const Index, m: Match, out: *std.ArrayList(u8)) !void {
    for (m.ids[0..m.len], 0..) |id, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, ix.spell(id));
    }
}

pub const copula_ops = [_][]const []const u8{
    &.{ "is", "a" },  &.{ "is", "an" },  &.{ "was", "a" },  &.{ "was", "an" },
    &.{ "are", "a" }, &.{ "are", "an" }, &.{ "is", "the" }, &.{ "are", "the" },
};
pub const isa_lens = Lens{ .ops = &copula_ops, .gap = 0, .max_words = 4, .stop_at_func = true, .subject_initial = true, .np_end_morph = true };

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

fn testIndex(a: std.mem.Allocator, text: []const u8, sp: *tok.Spellings) !struct { img: []align(64) u8, ix: Index } {
    var toks: std.ArrayList(u64) = .empty;
    defer toks.deinit(a);
    try tok.tokenize(a, text, &toks, sp);
    const es = idiom.Entries{};
    const img = try build(a, toks.items, sp, &es);
    return .{ .img = img, .ix = try Index.fromBytes(a, img) };
}

test "lens: one attestation is enough, senses stay apart, evidence is the real sentence" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const aa = ar.allocator();
    var sp = tok.Spellings.init(aa);
    const text =
        \\Pizza is an Italian dish. The cook will dish out the soup. Satellite dish. Curry is a Indian dish, and rice is the staple.
        \\Many things happen in many places and the people go to the market and the park and the shop and the house.
        \\
    ;
    var t = try testIndex(aa, text, &sp);
    const pizza = t.ix.idOfWord("pizza").?;
    const ms = try find(aa, &t.ix, pizza, isa_lens);
    try std.testing.expectEqual(@as(usize, 1), ms.len);
    var buf: std.ArrayList(u8) = .empty;
    try phraseText(aa, &t.ix, ms[0], &buf);
    try std.testing.expectEqualStrings("italian dish", buf.items);
    const ev = try t.ix.sentence(aa, ms[0].pos);
    try std.testing.expectEqualStrings("pizza is an italian dish.", ev);
    // "dish" is the head of two different frames' phrases, and also occurs in the verb and compound senses
    const dish = t.ix.idOfWord("dish").?;
    try std.testing.expectEqual(@as(usize, 4), t.ix.occ(dish).len);
    const as_subject = try find(aa, &t.ix, dish, isa_lens);
    try std.testing.expectEqual(@as(usize, 0), as_subject.len); // nobody says "dish is a ..." here
    const pizza_verb = try find(aa, &t.ix, t.ix.idOfWord("cook").?, isa_lens);
    try std.testing.expectEqual(@as(usize, 0), pizza_verb.len);
}

test "lens: image round-trips through bytes and the index is deterministic" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const aa = ar.allocator();
    var sp = tok.Spellings.init(aa);
    var t1 = try testIndex(aa, "a b c a b d a b c\n", &sp);
    var sp2 = tok.Spellings.init(aa);
    const t2 = try testIndex(aa, "a b c a b d a b c\n", &sp2);
    try std.testing.expectEqualSlices(u8, t1.img, t2.img);
    try std.testing.expectEqual(@as(usize, 3), t1.ix.occ(t1.ix.idOfWord("a").?).len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 6 }, t1.ix.occ(t1.ix.idOfWord("a").?));
}
