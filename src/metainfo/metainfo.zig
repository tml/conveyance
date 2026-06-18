const std = @import("std");
const dec = @import("../bencode/decode.zig");

pub const FileEntry = struct {
    length: u64,
    /// path components joined with '/'. Allocated in the caller's arena.
    path: []const u8,
};

pub const Metainfo = struct {
    name: []const u8, // slice into source buffer
    piece_length: u64,
    /// concatenated 20-byte SHA-1 piece hashes (slice into source buffer)
    pieces: []const u8,
    total_length: u64,
    files: []FileEntry, // single-file torrents get one entry
    info_hash: [20]u8,
    announce: ?[]const u8,

    pub fn pieceCount(self: *const Metainfo) usize {
        return self.pieces.len / 20;
    }
};

pub const Error = error{ MissingField, BadType } || dec.Error;

fn get(v: dec.Value, key: []const u8) ?dec.Value {
    if (v != .dict) return null;
    for (v.dict) |pair| if (std.mem.eql(u8, pair.key, key)) return pair.value;
    return null;
}

fn getStr(v: dec.Value, key: []const u8) Error![]const u8 {
    const f = get(v, key) orelse return Error.MissingField;
    if (f != .str) return Error.BadType;
    return f.str;
}

fn getInt(v: dec.Value, key: []const u8) Error!i64 {
    const f = get(v, key) orelse return Error.MissingField;
    if (f != .int) return Error.BadType;
    return f.int;
}

fn getU64(v: dec.Value, key: []const u8) Error!u64 {
    const n = try getInt(v, key);
    if (n < 0) return Error.BadType;
    return @intCast(n);
}

/// Parses `.torrent` bytes. Allocations (files slice) come from `arena`.
/// String fields are slices into `bytes`, so `bytes` must outlive the result.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!Metainfo {
    var p = dec.Parser.init(arena, bytes);
    const root = try p.parseTop();
    const info = get(root, "info") orelse return Error.MissingField;

    // Recompute the raw info-dict span for the infohash (independent walk).
    var p2 = dec.Parser.init(arena, bytes);
    p2.pos += 1; // 'd'
    var info_span: []const u8 = &.{};
    while (p2.pos < bytes.len and bytes[p2.pos] != 'e') {
        const key = try p2.parseString();
        if (std.mem.eql(u8, key, "info")) {
            info_span = try p2.rawSpanOfValue();
            break;
        } else {
            _ = try p2.rawSpanOfValue();
        }
    }
    if (info_span.len == 0) return Error.MissingField;

    var ih: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(info_span, &ih, .{});

    const name = try getStr(info, "name");
    const piece_length: u64 = try getU64(info, "piece length");
    const pieces = try getStr(info, "pieces");
    if (pieces.len == 0 or pieces.len % 20 != 0) return Error.BadType;

    var files = std.ArrayList(FileEntry).init(arena);
    var total: u64 = 0;
    if (get(info, "files")) |files_v| {
        if (files_v != .list) return Error.BadType;
        for (files_v.list) |fe| {
            const len: u64 = try getU64(fe, "length");
            const path_v = get(fe, "path") orelse return Error.MissingField;
            if (path_v != .list) return Error.BadType;
            if (path_v.list.len == 0) return Error.MissingField;
            var parts = std.ArrayList(u8).init(arena);
            // TODO: sanitize path components ('..' / '/') before the storage
            // layer uses this for filesystem writes.
            for (path_v.list, 0..) |seg, i| {
                if (seg != .str) return Error.BadType;
                if (i != 0) try parts.append('/');
                try parts.appendSlice(seg.str);
            }
            try files.append(.{ .length = len, .path = try parts.toOwnedSlice() });
            total += len;
        }
    } else {
        const len: u64 = try getU64(info, "length");
        try files.append(.{ .length = len, .path = name });
        total = len;
    }

    return .{
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .total_length = total,
        .files = try files.toOwnedSlice(),
        .info_hash = ih,
        .announce = getStr(root, "announce") catch |e| switch (e) {
            error.MissingField => null,
            else => return e,
        },
    };
}

test "metainfo: parses single-file fixture" {
    const bytes = @embedFile("../tests/fixtures/single.torrent");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mi = try parse(arena.allocator(), bytes);

    try std.testing.expectEqualStrings("hello.txt", mi.name);
    try std.testing.expectEqual(@as(u64, 16384), mi.piece_length);
    try std.testing.expectEqual(@as(u64, 11), mi.total_length);
    try std.testing.expectEqual(@as(usize, 1), mi.files.len);
    try std.testing.expectEqual(@as(usize, 1), mi.pieceCount());
    try std.testing.expectEqualStrings("http://tracker:6969/", mi.announce.?);

    const expected_hex = "e797b1908e6938957d0d5c4598e57abc9ee3a60b";
    var got_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&got_hex, "{s}", .{std.fmt.fmtSliceHexLower(&mi.info_hash)}) catch unreachable;
    try std.testing.expectEqualStrings(expected_hex, &got_hex);
}

test "metainfo: rejects negative length" {
    // info dict with length = -1 (malformed)
    const bytes =
        "d8:announce20:http://tracker:6969/4:infod6:lengthi-1e4:name9:hello.txt12:piece lengthi16384e6:pieces20:" ++
        ("\x00" ** 20) ++ "ee";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.BadType, parse(arena.allocator(), bytes));
}

test "metainfo: rejects pieces length not multiple of 20" {
    // pieces blob is 19 bytes — invalid
    const bytes =
        "d8:announce20:http://tracker:6969/4:infod6:lengthi11e4:name9:hello.txt12:piece lengthi16384e6:pieces19:" ++
        ("\x00" ** 19) ++ "ee";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.BadType, parse(arena.allocator(), bytes));
}

test "metainfo: announce of wrong type is rejected, not silently null" {
    // announce is an integer (42) instead of a string
    const bytes =
        "d8:announcei42e4:infod6:lengthi11e4:name9:hello.txt12:piece lengthi16384e6:pieces20:" ++
        ("\x00" ** 20) ++ "ee";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.BadType, parse(arena.allocator(), bytes));
}
