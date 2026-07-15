const std = @import("std");
const logmod = @import("log/logger.zig");
const Logger = logmod.Logger;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) std.debug.print("conveyance: GPA reported memory leak on exit\n", .{});
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr();
    const is_tty = std.posix.isatty(stderr.handle);

    // Ring capacity: 1024 records. Tune in M1 when startup-log fanout is known.
    const log = try logmod.Log.init(allocator, 1024, .info, .{
        .writer = stderr.writer().any(),
        .format = if (is_tty) .pretty else .ndjson,
        .color = is_tty,
    });
    // deinit() drains the ring + joins the writer thread; destroy() frees the
    // Log allocation itself. Order matters — both lines run top-to-bottom.
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
