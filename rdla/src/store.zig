//! store.zig - the accumulator as a memory-mapped table on disk (the CRSL idea: the array IS the file).
//!
//! Layout (little-endian, every section 64-byte aligned):
//!   0x00 Header (64 bytes)
//!        keys   [cap]u64        0 = empty slot
//!        count  [cap]u32
//!        left   [cap*D]i32
//!        right  [cap*D]i32
//!        spellings: [n:u32] then n * ([hash:u64][len:u16][bytes])   (offset in header, 0 = none)
//!
//! The Acc's slices point straight into the mapping, so ingestion writes the file directly and the
//! OS pages it; a 400 MB tape never needs the whole table resident. A fresh file is sparse (ftruncate),
//! so untouched slots cost no disk or RAM. Counters are integer sums, so the bytes are a pure
//! function of the tape (shard-independent) and identical runs give identical files.
const std = @import("std");
const ctx = @import("ctx.zig");
const tok = @import("tok.zig");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) @compileError("store.zig needs a little-endian target");
}

pub const MAGIC = [8]u8{ 'R', 'D', 'L', 'A', 0x00, 0x01, 0x00, 0x01 };
pub const VERSION: u32 = 1;

pub const Header = extern struct {
    magic: [8]u8 = MAGIC,
    version: u32 = VERSION,
    dim: u32 = ctx.D,
    cap: u64, // slot count, power of two
    used: u64 = 0,
    window: u32 = 0,
    reserved0: u32 = 0,
    checksum: u32 = 0, // XOR-fold of every section; 0 until sync(); checked only by verify()
    reserved1: u32 = 0,
    spell_off: u64 = 0,
    reserved2: u64 = 0,
};
comptime {
    std.debug.assert(@sizeOf(Header) == 64);
}

pub const Error = error{ BadMagic, BadVersion, BadDim, BadCap, Truncated, ChecksumMismatch, Misaligned };

const Layout = struct {
    keys: usize,
    count: usize,
    left: usize,
    right: usize,
    end: usize,

    fn of(cap: usize) Layout {
        const keys = 64;
        const count = keys + cap * 8;
        const left = alignUp(count + cap * 4);
        const right = left + cap * ctx.D * 4;
        return .{ .keys = keys, .count = count, .left = left, .right = right, .end = right + cap * ctx.D * 4 };
    }
};

fn alignUp(x: usize) usize {
    return (x + 63) & ~@as(usize, 63);
}

fn xorFold(data: []const u8) u32 {
    var h: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) h ^= std.mem.readInt(u32, data[i..][0..4], .little);
    var sh: u5 = 0;
    while (i < data.len) : (i += 1) {
        h ^= @as(u32, data[i]) << (sh * 8);
        sh +%= 1;
    }
    return h;
}

fn view(map: []align(std.heap.page_size_min) u8, cap: usize) ctx.Acc {
    const l = Layout.of(cap);
    const keys: [*]u64 = @ptrCast(@alignCast(map.ptr + l.keys));
    const count: [*]u32 = @ptrCast(@alignCast(map.ptr + l.count));
    const left: [*]i32 = @ptrCast(@alignCast(map.ptr + l.left));
    const right: [*]i32 = @ptrCast(@alignCast(map.ptr + l.right));
    return .{
        .alloc = undefined,
        .keys = keys[0..cap],
        .count = count[0..cap],
        .left = left[0 .. cap * ctx.D],
        .right = right[0 .. cap * ctx.D],
        .mask = cap - 1,
        .map = map,
    };
}

fn mapFile(file: std.fs.File, len: usize, writable: bool) ![]align(std.heap.page_size_min) u8 {
    const prot: u32 = if (writable) std.posix.PROT.READ | std.posix.PROT.WRITE else std.posix.PROT.READ;
    return std.posix.mmap(null, len, prot, .{ .TYPE = .SHARED }, file.handle, 0);
}

/// Creates (truncating) a file-backed accumulator with 2^cap_pow2 slots. Writes the header immediately.
pub fn create(path: []const u8, cap_pow2: u6, window: u32) !ctx.Acc {
    const cap: usize = @as(usize, 1) << cap_pow2;
    const l = Layout.of(cap);
    const f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer f.close();
    try f.setEndPos(l.end);
    const map = try mapFile(f, l.end, true);
    const hdr = Header{ .cap = cap, .window = window };
    @memcpy(map[0..64], std.mem.asBytes(&hdr));
    return view(map, cap);
}

pub const Opened = struct { acc: ctx.Acc, header: Header };

/// Maps an existing file. Validates magic/version/dimension/size only: O(1), nothing is read until touched.
pub fn open(path: []const u8, writable: bool) !Opened {
    const f = try std.fs.cwd().openFile(path, .{ .mode = if (writable) .read_write else .read_only });
    defer f.close();
    const len = (try f.stat()).size;
    if (len < 64) return Error.Truncated;
    const map = try mapFile(f, len, writable);
    errdefer std.posix.munmap(map);
    var hdr: Header = undefined;
    @memcpy(std.mem.asBytes(&hdr), map[0..64]);
    if (!std.mem.eql(u8, &hdr.magic, &MAGIC)) return Error.BadMagic;
    if (hdr.version != VERSION) return Error.BadVersion;
    if (hdr.dim != ctx.D) return Error.BadDim;
    if (hdr.cap == 0 or hdr.cap & (hdr.cap - 1) != 0 or hdr.cap > (1 << 40)) return Error.BadCap;
    const cap: usize = @intCast(hdr.cap);
    if (len < Layout.of(cap).end) return Error.Truncated;
    var acc = view(map, cap);
    acc.used = @intCast(hdr.used);
    return .{ .acc = acc, .header = hdr };
}

fn headerPtr(acc: *ctx.Acc) *Header {
    return @ptrCast(@alignCast(acc.map.?.ptr));
}

/// Records `used`, checksum and flushes dirty pages. The checksum folds every byte, so call it once at the end.
pub fn sync(acc: *ctx.Acc) !void {
    const m = acc.map.?;
    const h = headerPtr(acc);
    h.used = acc.used;
    h.checksum = 0;
    h.checksum = xorFold(m[64..Layout.of(acc.mask + 1).end]);
    try std.posix.msync(m, std.posix.MSF.SYNC);
}

/// Full integrity pass (reads the whole file).
pub fn verify(acc: *ctx.Acc) Error!void {
    const m = acc.map.?;
    const h = headerPtr(acc);
    if (xorFold(m[64..Layout.of(acc.mask + 1).end]) != h.checksum) return Error.ChecksumMismatch;
}

/// Appends the unit spellings after the table (so answers can name units). Call after the last sync()
/// has NOT been made: this rewrites the header offset, then the caller syncs again.
pub fn writeSpellings(path: []const u8, sp: *const tok.Spellings) !void {
    const f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer f.close();
    var hb: [64]u8 = undefined;
    _ = try f.preadAll(&hb, 0);
    var hdr: Header = undefined;
    @memcpy(std.mem.asBytes(&hdr), &hb);
    const base = Layout.of(@intCast(hdr.cap)).end;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;
    var n4: [4]u8 = undefined;
    std.mem.writeInt(u32, &n4, sp.count(), .little);
    try buf.appendSlice(a, &n4);
    var it = sp.iterator();
    while (it.next()) |e| {
        var r: [10]u8 = undefined;
        std.mem.writeInt(u64, r[0..8], e.key_ptr.*, .little);
        std.mem.writeInt(u16, r[8..10], @intCast(@min(e.value_ptr.*.len, 65535)), .little);
        try buf.appendSlice(a, &r);
        try buf.appendSlice(a, e.value_ptr.*[0..@min(e.value_ptr.*.len, 65535)]);
    }
    try f.pwriteAll(buf.items, base);
    try f.setEndPos(base + buf.items.len);
    hdr.spell_off = base;
    try f.pwriteAll(std.mem.asBytes(&hdr), 0);
}

pub fn readSpellings(a: std.mem.Allocator, path: []const u8, sp: *tok.Spellings) !void {
    const data = try std.fs.cwd().readFileAlloc(a, path, 1 << 40);
    defer a.free(data);
    var hdr: Header = undefined;
    @memcpy(std.mem.asBytes(&hdr), data[0..64]);
    if (hdr.spell_off == 0) return;
    var p: usize = @intCast(hdr.spell_off);
    const n = std.mem.readInt(u32, data[p..][0..4], .little);
    p += 4;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const k = std.mem.readInt(u64, data[p..][0..8], .little);
        const l = std.mem.readInt(u16, data[p + 8 ..][0..2], .little);
        p += 10;
        try sp.put(k, try a.dupe(u8, data[p..][0..l]));
        p += l;
    }
}

const testing = std.testing;

test "store: file-backed accumulator equals in-memory accumulator, survives reopen, detects corruption" {
    const a = testing.allocator;
    var units: [500]u64 = undefined;
    var s: u64 = 11;
    for (&units) |*u| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        u.* = 1 + (s >> 33) % 31;
    }
    var mem = try ctx.Acc.init(a, 6);
    defer mem.deinit();
    try mem.centers(&units, 0, units.len, 3);

    const path = "store_test.rdla";
    defer std.fs.cwd().deleteFile(path) catch {};
    {
        var disk = try create(path, 6, 3);
        defer disk.deinit();
        try disk.centers(&units, 0, units.len, 3);
        try sync(&disk);
        try testing.expect(mem.eql(&disk));
    }
    {
        var o = try open(path, false);
        defer o.acc.deinit();
        try testing.expect(mem.eql(&o.acc));
        try testing.expectEqual(@as(u32, 3), o.header.window);
        try verify(&o.acc);
    }
    {
        var o = try open(path, true);
        defer o.acc.deinit();
        o.acc.left[5] +%= 1;
        try testing.expectError(Error.ChecksumMismatch, verify(&o.acc));
    }
}

test "store: bad magic and truncation are rejected" {
    const path = "store_bad.rdla";
    defer std.fs.cwd().deleteFile(path) catch {};
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(&([_]u8{0xDE} ** 128));
    }
    try testing.expectError(Error.BadMagic, open(path, false));
    var d = try create(path, 6, 1);
    d.deinit();
    const f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    try f.setEndPos(1000);
    f.close();
    try testing.expectError(Error.Truncated, open(path, false));
}

test "store: spellings round-trip" {
    const a = testing.allocator;
    const path = "store_sp.rdla";
    defer std.fs.cwd().deleteFile(path) catch {};
    var d = try create(path, 6, 1);
    d.deinit();
    var sp = tok.Spellings.init(a);
    defer sp.deinit();
    try sp.put(42, "hello");
    try sp.put(7, "kick the bucket");
    try writeSpellings(path, &sp);
    var back = tok.Spellings.init(a);
    defer {
        var it = back.valueIterator();
        while (it.next()) |v| a.free(v.*);
        back.deinit();
    }
    try readSpellings(a, path, &back);
    try testing.expectEqualStrings("hello", back.get(42).?);
    try testing.expectEqualStrings("kick the bucket", back.get(7).?);
    var o = try open(path, false);
    o.acc.deinit();
}
