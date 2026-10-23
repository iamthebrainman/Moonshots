//! tok.zig - tokenizer. A token's identity is the FNV-1a hash of its lowercased spelling,
//! so identity is a pure function of spelling (no vocabulary table, no ordering).
const std = @import("std");

pub fn fnv(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

pub const Spellings = std.AutoHashMap(u64, []const u8);

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '\'';
}

fn boundaryOf(c: u8) ?[]const u8 {
    return switch (c) {
        '.' => ".",
        ',' => ",",
        '?' => "?",
        '!' => "!",
        ';' => ";",
        ':' => ":",
        '\n' => "\n",
        else => null,
    };
}

/// Appends the unit hashes of `text` to `out`; records first-seen spellings.
/// Newlines are boundary tokens (one per line).
pub fn tokenize(alloc: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u64), sp: *Spellings) !void {
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < text.len) {
        const c = text[i];
        if (isWordChar(c)) {
            var n: usize = 0;
            while (i < text.len and isWordChar(text[i])) : (i += 1) {
                if (n < buf.len) {
                    buf[n] = std.ascii.toLower(text[i]);
                    n += 1;
                }
            }
            const h = fnv(buf[0..n]);
            try out.append(alloc, h);
            if (!sp.contains(h)) try sp.put(h, try alloc.dupe(u8, buf[0..n]));
        } else {
            if (boundaryOf(c)) |b| {
                const h = fnv(b);
                try out.append(alloc, h);
                if (!sp.contains(h)) try sp.put(h, b);
            }
            i += 1;
        }
    }
}

test "tokenize: identity is spelling" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(a);
    var sp = Spellings.init(a);
    defer {
        var it = sp.iterator();
        while (it.next()) |e| if (e.value_ptr.*.len > 1 or std.ascii.isAlphanumeric(e.value_ptr.*[0])) a.free(e.value_ptr.*);
        sp.deinit();
    }
    try tokenize(a, "Well, the Thing is.", &out, &sp);
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
    try std.testing.expectEqual(fnv("well"), out.items[0]);
    try std.testing.expectEqual(fnv(","), out.items[1]);
    try std.testing.expectEqual(fnv("thing"), out.items[3]);
}
