const std = @import("std");
const dec = @import("decode.zig");

/// Encodes a Value tree to `w`. Dict keys are emitted in the order given
/// (callers that need canonical form must pre-sort).
pub fn write(w: anytype, v: dec.Value) !void {
    switch (v) {
        .int => |n| try w.print("i{d}e", .{n}),
        .str => |s| try w.print("{d}:{s}", .{ s.len, s }),
        .list => |items| {
            try w.writeByte('l');
            for (items) |item| try write(w, item);
            try w.writeByte('e');
        },
        .dict => |pairs| {
            try w.writeByte('d');
            for (pairs) |pair| {
                try w.print("{d}:{s}", .{ pair.key.len, pair.key });
                try write(w, pair.value);
            }
            try w.writeByte('e');
        },
    }
}

test "encode: scalars" {
    var buf: [64]u8 = undefined;
    var s = std.io.fixedBufferStream(&buf);
    try write(s.writer(), .{ .int = -7 });
    try std.testing.expectEqualStrings("i-7e", s.getWritten());

    var s2 = std.io.fixedBufferStream(&buf);
    try write(s2.writer(), .{ .str = "spam" });
    try std.testing.expectEqualStrings("4:spam", s2.getWritten());
}

test "encode: round-trips a parsed dict byte-for-byte" {
    const input = "d3:cow3:moo4:spaml1:a1:bee";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = dec.Parser.init(arena.allocator(), input);
    const v = try p.parseTop();

    var buf: [128]u8 = undefined;
    var s = std.io.fixedBufferStream(&buf);
    try write(s.writer(), v);
    try std.testing.expectEqualStrings(input, s.getWritten());
}
