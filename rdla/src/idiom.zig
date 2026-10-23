//! idiom.zig - entries of the form   "phrase" means gloss   and longest-match fusing.
const std = @import("std");
const tok = @import("tok.zig");

pub const Entry = struct {
    phrase: []u64, // token hashes of the phrase
    gloss: []u64, // token hashes of the explanation
    unit: u64, // hash of the fused unit
    name: []const u8,
};

pub const Entries = struct {
    list: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Entries, a: std.mem.Allocator) void {
        for (self.list.items) |e| {
            a.free(e.phrase);
            a.free(e.gloss);
            a.free(e.name);
        }
        self.list.deinit(a);
    }
};

/// Parses lines `"phrase" means gloss...`. Lines that do not match are returned in `bad` (count).
pub fn parse(a: std.mem.Allocator, text: []const u8, sp: *tok.Spellings, bad: *usize) !Entries {
    var es = Entries{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != '"') {
            bad.* += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse {
            bad.* += 1;
            continue;
        };
        const phrase = line[1..close];
        const rest = std.mem.trim(u8, line[close + 1 ..], " \t");
        // `"phrase"` alone is a fusion-only operator (no taught gloss); otherwise `"phrase" means gloss`.
        if (rest.len != 0 and !std.mem.startsWith(u8, rest, "means")) {
            bad.* += 1;
            continue;
        }
        const gloss = if (rest.len == 0) "" else rest[5..];
        var pt: std.ArrayList(u64) = .empty;
        defer pt.deinit(a);
        var gt: std.ArrayList(u64) = .empty;
        defer gt.deinit(a);
        try tok.tokenize(a, phrase, &pt, sp);
        try tok.tokenize(a, gloss, &gt, sp);
        if (pt.items.len < 2) {
            bad.* += 1;
            continue;
        }
        const name = try a.dupe(u8, phrase);
        try es.list.append(a, .{
            .phrase = try a.dupe(u64, pt.items),
            .gloss = try a.dupe(u64, gt.items),
            .unit = tok.fnv(name) ^ 0x1D10_0000_0000_0001,
            .name = name,
        });
    }
    return es;
}

/// Replaces every longest-matching idiom phrase in `units` by its single fused unit.
/// Returns the fused sequence; `hits` counts matches per entry index.
pub fn fuse(a: std.mem.Allocator, units: []const u64, es: *const Entries, hits: []usize) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    var p: usize = 0;
    while (p < units.len) {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (es.list.items, 0..) |e, k| {
            const n = e.phrase.len;
            if (n > best_len and p + n <= units.len and std.mem.eql(u64, units[p .. p + n], e.phrase)) {
                best = k;
                best_len = n;
            }
        }
        if (best) |k| {
            try out.append(a, es.list.items[k].unit);
            hits[k] += 1;
            p += best_len;
        } else {
            try out.append(a, units[p]);
            p += 1;
        }
    }
    return out;
}

test "idiom: parse and longest-match fuse" {
    const a = std.testing.allocator;
    var sp = tok.Spellings.init(a);
    defer {
        var it = sp.iterator();
        while (it.next()) |e| if (e.value_ptr.*.len > 1 or std.ascii.isAlphanumeric(e.value_ptr.*[0])) a.free(e.value_ptr.*);
        sp.deinit();
    }
    var bad: usize = 0;
    var es = try parse(a, "\"kick the bucket\" means to die\n\"kick the\" means to hit\nnot an entry\n", &sp, &bad);
    defer es.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), bad);
    try std.testing.expectEqual(@as(usize, 2), es.list.items.len);
    var units: std.ArrayList(u64) = .empty;
    defer units.deinit(a);
    try tok.tokenize(a, "he will kick the bucket today", &units, &sp);
    var hits = [_]usize{ 0, 0 };
    var fused = try fuse(a, units.items, &es, &hits);
    defer fused.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), fused.items.len); // he will <unit> today
    try std.testing.expectEqual(es.list.items[0].unit, fused.items[2]);
    try std.testing.expectEqual(@as(usize, 1), hits[0]);
    try std.testing.expectEqual(@as(usize, 0), hits[1]);
}
