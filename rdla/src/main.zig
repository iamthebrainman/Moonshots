//! rdla - M1: deterministic total-context bundles, idiom fusing, operator report.
//!   rdla <tape.txt> [idioms.txt|-] [shards] [window] [out.rdla]
const std = @import("std");
const tok = @import("tok.zig");
const idiom = @import("idiom.zig");
const ctx = @import("ctx.zig");
const store = @import("store.zig");

test {
    _ = tok;
    _ = idiom;
    _ = ctx;
    _ = @import("store.zig");
}

const Row = struct { h: u64, asym: f64, n: u32 };

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: rdla <tape.txt> [idioms.txt] [shards] [window]\n", .{});
        return;
    }
    const shards: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 1;
    const window: usize = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 4;

    var sp = tok.Spellings.init(a);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(1 << 31));
    var raw: std.ArrayList(u64) = .empty;
    try tok.tokenize(a, text, &raw, &sp);

    var bad: usize = 0;
    var es = idiom.Entries{};
    if (args.len > 2 and !std.mem.eql(u8, args[2], "-")) {
        const itext = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(1 << 28));
        es = try idiom.parse(a, itext, &sp, &bad);
    }
    const hits = try a.alloc(usize, es.list.items.len);
    @memset(hits, 0);
    const units = try idiom.fuse(a, raw.items, &es, hits);
    for (es.list.items) |e| try sp.put(e.unit, e.name);

    // size the table from the true distinct-unit count (slots cost D*8 bytes each, so don't guess from tokens)
    var seen = std.AutoHashMap(u64, void).init(a);
    for (units.items) |u| try seen.put(u, {});
    for (es.list.items) |e| try seen.put(e.unit, {});
    var cap: u6 = 10;
    while ((@as(usize, 1) << cap) < seen.count() * 2 and cap < 40) cap += 1;
    const out_path: ?[]const u8 = if (args.len > 5) args[5] else null;
    var acc = if (out_path) |op| try store.create(io, op, cap, @intCast(window)) else try ctx.Acc.init(a, cap);
    const per = (units.items.len + shards - 1) / shards;
    var s: usize = 0;
    while (s < shards) : (s += 1) {
        const lo = @min(s * per, units.items.len);
        const hi = @min(lo + per, units.items.len);
        try acc.centers(units.items, lo, hi, window);
    }
    for (es.list.items) |e| try acc.gloss(e.unit, e.gloss, 1);

    if (out_path) |op| {
        try store.sync(&acc);
        try store.writeSpellings(io, op, &sp);
        std.debug.print("wrote {s}\n", .{op});
    }
    std.debug.print("tokens {d}  units {d}  distinct {d}  idioms {d} (bad lines {d})  shards {d}  window {d}  D {d}\n", .{ raw.items.len, units.items.len, acc.used, es.list.items.len, bad, shards, window, ctx.D });
    for (es.list.items, 0..) |e, k| std.debug.print("  idiom \"{s}\": {d} hits\n", .{ e.name, hits[k] });

    var rows: std.ArrayList(Row) = .empty;
    for (acc.keys, 0..) |k, i| {
        if (k == 0 or acc.count[i] < 50) continue;
        const n: usize = @as(usize, acc.count[i]) * window;
        const asym = ctx.coherence(acc.right[i * ctx.D ..][0..ctx.D], n) - ctx.coherence(acc.left[i * ctx.D ..][0..ctx.D], n);
        try rows.append(a, .{ .h = k, .asym = asym, .n = acc.count[i] });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            if (x.asym != y.asym) return x.asym > y.asym;
            return x.h < y.h;
        }
    }.lt);
    std.debug.print("\nmost operator-like units (coherence(right) - coherence(left)), count >= 50:\n", .{});
    for (rows.items[0..@min(25, rows.items.len)]) |r| std.debug.print("  {d:.3}  n={d:<7} {s}\n", .{ r.asym, r.n, sp.get(r.h) orelse "?" });
    std.debug.print("\nleast operator-like:\n", .{});
    const start = if (rows.items.len > 15) rows.items.len - 15 else 0;
    for (rows.items[start..]) |r| std.debug.print("  {d:.3}  n={d:<7} {s}\n", .{ r.asym, r.n, sp.get(r.h) orelse "?" });
}
