const std = @import("std");
const rec = @import("record.zig");
const Ring = @import("ring.zig").Ring;
const ndjson = @import("format_ndjson.zig");
const pretty = @import("format_pretty.zig");

pub const Format = enum { ndjson, pretty };

pub const Sink = struct {
    writer: std.io.AnyWriter,
    format: Format,
    color: bool,
};

/// Owns the writer thread and the ring. Create once at startup.
pub const Log = struct {
    ring: Ring,
    sink: Sink,
    level: rec.Level,
    /// Count of records refused because the ring was full. No reader in M0;
    /// a future milestone will expose a `droppedCount()` accessor.
    dropped: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thread: ?std.Thread = null,

    /// Heap-allocates Log and spawns the writer thread. Caller must call
    /// `deinit()` (drains + joins + frees the ring) AND `allocator.destroy(log)`
    /// to release the Log allocation itself.
    pub fn init(allocator: std.mem.Allocator, capacity: usize, level: rec.Level, sink: Sink) !*Log {
        const self = try allocator.create(Log);
        errdefer allocator.destroy(self);
        self.* = .{ .ring = try Ring.init(allocator, capacity), .sink = sink, .level = level };
        errdefer self.ring.deinit();
        self.thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        return self;
    }

    /// Stops the writer thread, drains remaining records, frees the ring.
    /// Does NOT free the Log allocation itself — caller must follow with
    /// `allocator.destroy(log)`.
    pub fn deinit(self: *Log) void {
        self.ring.close();
        if (self.thread) |t| t.join();
        self.ring.deinit();
    }

    pub fn enabled(self: *const Log, level: rec.Level) bool {
        return @intFromEnum(level) <= @intFromEnum(self.level);
    }

    /// Non-blocking emit. Drops + counts when the ring is full.
    pub fn emit(self: *Log, r: rec.Record) void {
        if (!self.enabled(r.level)) return;
        if (!self.ring.push(r)) _ = self.dropped.fetchAdd(1, .monotonic);
    }

    fn writerLoop(self: *Log) void {
        // Records whose formatted size exceeds 4095 bytes are silently dropped
        // via `catch continue` on the format call (FixedBufferStream returns
        // error.NoSpaceLeft). Adequate for typical records (12 short fields).
        var buf: [4096]u8 = undefined;
        while (self.ring.pop()) |r| {
            var stream = std.io.fixedBufferStream(&buf);
            const w = stream.writer();
            switch (self.sink.format) {
                .ndjson => ndjson.write(w, &r) catch continue,
                .pretty => pretty.write(w, &r, self.sink.color) catch continue,
            }
            self.sink.writer.writeAll(stream.getWritten()) catch {};
            self.sink.writer.writeByte('\n') catch {};
        }
    }
};

/// Lightweight, copyable handle that auto-attaches bound context fields to
/// every record. Create children with `.with(...)`.
pub const Logger = struct {
    log: *Log,
    subsystem: rec.Subsystem,
    bound: [rec.max_fields]rec.Field = undefined,
    bound_count: usize = 0,

    pub fn init(log: *Log, subsystem: rec.Subsystem) Logger {
        return .{ .log = log, .subsystem = subsystem };
    }

    /// Returns a child Logger with `extra` fields appended to the bound set.
    pub fn with(self: Logger, extra: []const rec.Field) Logger {
        var child = self;
        for (extra) |f| {
            if (child.bound_count >= rec.max_fields) break;
            child.bound[child.bound_count] = f;
            child.bound_count += 1;
        }
        return child;
    }

    pub fn log_(self: *const Logger, level: rec.Level, msg: []const u8, fields: []const rec.Field) void {
        if (!self.log.enabled(level)) return;
        var r = rec.Record{
            .ts_ns = std.time.nanoTimestamp(),
            .level = level,
            .subsystem = self.subsystem,
            .msg = msg,
        };
        for (self.bound[0..self.bound_count]) |f| r.addField(f);
        for (fields) |f| r.addField(f);
        self.log.emit(r);
    }

    pub fn info(self: *const Logger, msg: []const u8, fields: []const rec.Field) void {
        self.log_(.info, msg, fields);
    }
    pub fn debug(self: *const Logger, msg: []const u8, fields: []const rec.Field) void {
        self.log_(.debug, msg, fields);
    }
    pub fn warn(self: *const Logger, msg: []const u8, fields: []const rec.Field) void {
        self.log_(.warn, msg, fields);
    }
    pub fn err(self: *const Logger, msg: []const u8, fields: []const rec.Field) void {
        self.log_(.err, msg, fields);
    }
};

test "logger: level filtering drops below-threshold records" {
    var sink_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer sink_buf.deinit();

    const log = try Log.init(std.testing.allocator, 16, .info, .{
        .writer = sink_buf.writer().any(),
        .format = .ndjson,
        .color = false,
    });

    var l = Logger.init(log, .session);
    l.info("kept", &.{});
    l.debug("dropped-by-level", &.{}); // below .info threshold

    log.deinit(); // drains
    std.testing.allocator.destroy(log);

    try std.testing.expect(std.mem.indexOf(u8, sink_buf.items, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink_buf.items, "dropped-by-level") == null);
}

test "logger: bound context fields appear on every line" {
    var sink_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer sink_buf.deinit();

    const log = try Log.init(std.testing.allocator, 16, .debug, .{
        .writer = sink_buf.writer().any(),
        .format = .ndjson,
        .color = false,
    });

    const base = Logger.init(log, .loader);
    const child = base.with(&.{.{ .key = "torrent", .value = .{ .uint = 42 } }});
    child.info("torrent.loaded", &.{.{ .key = "name", .value = .{ .str = "x" } }});

    log.deinit();
    std.testing.allocator.destroy(log);

    try std.testing.expect(std.mem.indexOf(u8, sink_buf.items, "\"torrent\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink_buf.items, "\"name\":\"x\"") != null);
}
