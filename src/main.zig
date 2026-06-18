const std = @import("std");
const logmod = @import("log/logger.zig");
const Logger = logmod.Logger;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr();
    const is_tty = std.posix.isatty(stderr.handle);

    const log = try logmod.Log.init(allocator, 1024, .info, .{
        .writer = stderr.writer().any(),
        .format = if (is_tty) .pretty else .ndjson,
        .color = is_tty,
    });
    defer {
        log.deinit();
        allocator.destroy(log);
    }

    const l = Logger.init(log, .session);
    l.info("conveyance.start", &.{
        .{ .key = "version", .value = .{ .str = "0.0.0" } },
        .{ .key = "milestone", .value = .{ .str = "M0" } },
    });
}
