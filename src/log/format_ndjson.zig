const std = @import("std");
const rec = @import("record.zig");

/// Writes one ndjson object (no trailing newline) for `r` to `w`.
pub fn write(w: anytype, r: *const rec.Record) !void {
    try w.writeAll("{");
    try w.print("\"ts\":{d},\"level\":\"{s}\",\"subsys\":\"{s}\",\"msg\":", .{
        r.ts_ns, r.level.label(), r.subsystem.label(),
    });
    try writeJsonString(w, r.msg);
    for (r.fieldSlice()) |f| {
        try w.writeAll(",");
        try writeJsonString(w, f.key);
        try w.writeAll(":");
        try writeValue(w, f.value);
    }
    try w.writeAll("}");
}

fn writeValue(w: anytype, v: rec.Value) !void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .uint => |n| try w.print("{d}", .{n}),
        .piece => |n| try w.print("{d}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .str => |s| try writeJsonString(w, s),
        .infohash => |h| {
            try w.writeAll("\"");
            try w.print("{s}", .{std.fmt.fmtSliceHexLower(&h)});
            try w.writeAll("\"");
        },
        .peer => |addr| {
            try w.print("\"{any}\"", .{addr});
        },
    }
}

/// Minimal RFC 8259 string escaping (the subset our keys/messages use).
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

test "ndjson: basic record with fields" {
    var r = rec.Record{ .ts_ns = 1234, .level = .info, .subsystem = .loader, .msg = "torrent.loaded" };
    r.addField(.{ .key = "torrent", .value = .{ .uint = 7 } });
    r.addField(.{ .key = "name", .value = .{ .str = "ubuntu" } });

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try write(stream.writer(), &r);

    try std.testing.expectEqualStrings(
        "{\"ts\":1234,\"level\":\"info\",\"subsys\":\"loader\",\"msg\":\"torrent.loaded\",\"torrent\":7,\"name\":\"ubuntu\"}",
        stream.getWritten(),
    );
}

test "ndjson: escapes quotes and control chars in strings" {
    var r = rec.Record{ .ts_ns = 0, .level = .warn, .subsystem = .rpc, .msg = "say \"hi\"\n" };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try write(stream.writer(), &r);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "say \\\"hi\\\"\\n") != null);
}

test "ndjson: infohash renders as 40 hex chars" {
    var r = rec.Record{ .ts_ns = 0, .level = .debug, .subsystem = .peer, .msg = "x" };
    r.addField(.{ .key = "ih", .value = .{ .infohash = [_]u8{0xab} ** 20 } });
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try write(stream.writer(), &r);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "\"ih\":\"" ++ ("ab" ** 20) ++ "\"") != null);
}
