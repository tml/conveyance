const std = @import("std");
const dec = @import("../bencode/decode.zig");

/// Subset of transmission .resume state imported in M0. Extended in later milestones.
pub const ResumeState = struct {
    name: []const u8, // slice into source bytes
    downloaded: u64 = 0,
    uploaded: u64 = 0,
    paused: bool = false,
    destination: ?[]const u8 = null,
};

pub const Error = error{BadType} || dec.Error;

fn get(v: dec.Value, key: []const u8) ?dec.Value {
    if (v != .dict) return null;
    for (v.dict) |pair| if (std.mem.eql(u8, pair.key, key)) return pair.value;
    return null;
}

/// Parses a transmission `.resume` file. Missing fields take defaults
/// (resume files legitimately omit fields). `bytes` must outlive the result.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!ResumeState {
    var p = dec.Parser.init(arena, bytes);
    const root = try p.parseTop();
    if (root != .dict) return Error.BadType;

    var rs = ResumeState{ .name = "" };
    if (get(root, "name")) |v| {
        if (v != .str) return Error.BadType;
        rs.name = v.str;
    }
    if (get(root, "downloaded")) |v| {
        if (v != .int) return Error.BadType;
        if (v.int < 0) return Error.BadType;
        rs.downloaded = @intCast(v.int);
    }
    if (get(root, "uploaded")) |v| {
        if (v != .int) return Error.BadType;
        if (v.int < 0) return Error.BadType;
        rs.uploaded = @intCast(v.int);
    }
    if (get(root, "paused")) |v| {
        if (v != .int) return Error.BadType;
        rs.paused = v.int != 0;
    }
    if (get(root, "destination")) |v| {
        if (v != .str) return Error.BadType;
        rs.destination = v.str;
    }
    return rs;
}

test "resume import: parses subset fields" {
    const bytes = @embedFile("../tests/fixtures/sample.resume");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rs = try parse(arena.allocator(), bytes);
    try std.testing.expectEqualStrings("hello.txt", rs.name);
    try std.testing.expectEqual(@as(u64, 11), rs.downloaded);
    try std.testing.expectEqual(@as(u64, 0), rs.uploaded);
    try std.testing.expectEqual(false, rs.paused);
    try std.testing.expectEqualStrings("/tmp", rs.destination.?);
}

test "resume import: missing fields take defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rs = try parse(arena.allocator(), "d4:name1:xe");
    try std.testing.expectEqualStrings("x", rs.name);
    try std.testing.expectEqual(@as(u64, 0), rs.downloaded);
    try std.testing.expectEqual(false, rs.paused);
    try std.testing.expectEqual(@as(?[]const u8, null), rs.destination);
}
