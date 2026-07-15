const std = @import("std");
const rec = @import("record.zig");

/// Writes one human-readable line (no trailing newline). `color` toggles ANSI.
/// Format: `LEVEL subsys msg key=val key=val`
pub fn write(w: anytype, r: *const rec.Record, color: bool) !void {
    const lvl = r.level.label();
    if (color) {
        try w.print("{s}{s: <5}{s} ", .{ levelColor(r.level), lvl, "\x1b[0m" });
    } else {
        try w.print("{s: <5} ", .{lvl});
    }
    try w.print("{s: <7} {s}", .{ r.subsystem.label(), r.msg });
    for (r.fieldSlice()) |f| {
        try w.print(" {s}=", .{f.key});
        try writeValue(w, f.value);
    }
}

fn levelColor(l: rec.Level) []const u8 {
    return switch (l) {
        .err => "\x1b[31m",   // red
        .warn => "\x1b[33m",  // yellow
        .info => "\x1b[32m",  // green
        .debug => "\x1b[36m", // cyan
        .trace => "\x1b[90m", // bright black
    };
}

fn writeValue(w: anytype, v: rec.Value) !void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .uint => |n| try w.print("{d}", .{n}),
        .piece => |n| try w.print("{d}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .str => |s| try w.print("{s}", .{s}),
        .infohash => |h| try w.print("{s}", .{std.fmt.fmtSliceHexLower(&h)}),
        .peer => |addr| try w.print("{any}", .{addr}),
    }
}

test "pretty: no-color layout" {
    var r = rec.Record{ .ts_ns = 0, .level = .info, .subsystem = .loader, .msg = "torrent.loaded" };
    r.addField(.{ .key = "torrent", .value = .{ .uint = 7 } });
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try write(stream.writer(), &r, false);
    try std.testing.expectEqualStrings("info  loader  torrent.loaded torrent=7", stream.getWritten());
}

test "pretty: color mode includes ANSI reset" {
    var r = rec.Record{ .ts_ns = 0, .level = .err, .subsystem = .peer, .msg = "drop" };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try write(stream.writer(), &r, true);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "\x1b[0m") != null);
}
