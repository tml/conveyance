const std = @import("std");
const ResumeState = @import("import.zig").ResumeState;

/// Our own resume format: a JSON object per torrent. Owned, not zero-copy.
/// `info_hash` keys the file on disk; included here for self-description.
pub const Sidecar = struct {
    info_hash_hex: [40]u8,
    name: []const u8,
    downloaded: u64,
    uploaded: u64,
    paused: bool,
    destination: ?[]const u8,

    pub fn fromImport(info_hash: [20]u8, rs: ResumeState) Sidecar {
        var hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&info_hash)}) catch unreachable;
        return .{
            .info_hash_hex = hex,
            .name = rs.name,
            .downloaded = rs.downloaded,
            .uploaded = rs.uploaded,
            .paused = rs.paused,
            .destination = rs.destination,
        };
    }
};

/// Serialize to JSON.
pub fn write(w: anytype, s: Sidecar) !void {
    try std.json.stringify(.{
        .info_hash = s.info_hash_hex,
        .name = s.name,
        .downloaded = s.downloaded,
        .uploaded = s.uploaded,
        .paused = s.paused,
        .destination = s.destination,
    }, .{}, w);
}

/// Parsed view; caller owns the returned Parsed and must `deinit()` it.
pub const Parsed = struct {
    arena: std.json.Parsed(Stored),
    pub fn value(self: *const Parsed) Stored {
        return self.arena.value;
    }
    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

const Stored = struct {
    info_hash: []const u8,
    name: []const u8,
    downloaded: u64,
    uploaded: u64,
    paused: bool,
    destination: ?[]const u8,
};

pub fn read(allocator: std.mem.Allocator, json_bytes: []const u8) !Parsed {
    const parsed = try std.json.parseFromSlice(Stored, allocator, json_bytes, .{});
    return .{ .arena = parsed };
}

test "sidecar: write then read round-trips fields" {
    const s = Sidecar{
        .info_hash_hex = ("ab" ** 20).*,
        .name = "hello.txt",
        .downloaded = 11,
        .uploaded = 3,
        .paused = true,
        .destination = "/tmp",
    };

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try write(buf.writer(), s);

    var parsed = try read(std.testing.allocator, buf.items);
    defer parsed.deinit();
    const v = parsed.value();

    try std.testing.expectEqualStrings("hello.txt", v.name);
    try std.testing.expectEqual(@as(u64, 11), v.downloaded);
    try std.testing.expectEqual(@as(u64, 3), v.uploaded);
    try std.testing.expectEqual(true, v.paused);
    try std.testing.expectEqualStrings("/tmp", v.destination.?);
    try std.testing.expectEqualStrings("ab" ** 20, v.info_hash);
}
