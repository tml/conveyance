const std = @import("std");
const rec = @import("record.zig");

/// Fixed-capacity MPSC ring of Records. Producers never block:
/// `push` returns false and the caller bumps a dropped-counter when full.
/// `pop` blocks until an item is available or `close()` is called.
pub const Ring = struct {
    buf: []rec.Record,
    head: usize = 0, // next pop
    tail: usize = 0, // next push
    len: usize = 0,
    closed: bool = false,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Ring {
        return .{ .buf = try allocator.alloc(rec.Record, capacity), .allocator = allocator };
    }

    pub fn deinit(self: *Ring) void {
        self.allocator.free(self.buf);
    }

    /// Non-blocking. Returns false if full (caller drops + counts).
    pub fn push(self: *Ring, r: rec.Record) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed or self.len == self.buf.len) return false;
        self.buf[self.tail] = r;
        self.tail = (self.tail + 1) % self.buf.len;
        self.len += 1;
        self.not_empty.signal();
        return true;
    }

    /// Blocks until an item is available. Returns null once closed AND drained.
    pub fn pop(self: *Ring) ?rec.Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == 0) {
            if (self.closed) return null;
            self.not_empty.wait(&self.mutex);
        }
        const r = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        return r;
    }

    pub fn close(self: *Ring) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }
};

fn mkRecord(n: u64) rec.Record {
    return .{ .ts_ns = @intCast(n), .level = .info, .subsystem = .session, .msg = "m" };
}

test "ring: fifo push/pop" {
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();
    try std.testing.expect(ring.push(mkRecord(1)));
    try std.testing.expect(ring.push(mkRecord(2)));
    try std.testing.expectEqual(@as(i128, 1), ring.pop().?.ts_ns);
    try std.testing.expectEqual(@as(i128, 2), ring.pop().?.ts_ns);
}

test "ring: push returns false when full" {
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();
    try std.testing.expect(ring.push(mkRecord(1)));
    try std.testing.expect(ring.push(mkRecord(2)));
    try std.testing.expect(!ring.push(mkRecord(3))); // full
}

test "ring: pop returns null after close+drain" {
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();
    try std.testing.expect(ring.push(mkRecord(1)));
    ring.close();
    try std.testing.expectEqual(@as(i128, 1), ring.pop().?.ts_ns);
    try std.testing.expect(ring.pop() == null);
}

test "ring: concurrent producers + single consumer drain all" {
    var ring = try Ring.init(std.testing.allocator, 64);
    defer ring.deinit();

    const Producer = struct {
        fn run(r: *Ring, count: usize, dropped: *std.atomic.Value(usize)) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                while (!r.push(mkRecord(@intCast(i)))) {
                    if (dropped.fetchAdd(0, .monotonic) == std.math.maxInt(usize)) break;
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    var dropped = std.atomic.Value(usize).init(0);
    var consumed: usize = 0;
    const total = 500;

    var consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *Ring, out: *usize) void {
            while (r.pop()) |_| out.* += 1;
        }
    }.run, .{ &ring, &consumed });

    var t1 = try std.Thread.spawn(.{}, Producer.run, .{ &ring, total, &dropped });
    t1.join();
    ring.close();
    consumer.join();

    try std.testing.expectEqual(@as(usize, total), consumed);
}
