# Conveyance M0 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Conveyance Zig project with a buildable/testable skeleton, a structured non-blocking logging facility, and the three pure parsers (`bencode`, `metainfo`, `resume`) that every later milestone depends on.

**Architecture:** Pure leaf modules with no engine dependencies, each unit-tested in isolation. A single `src/root.zig` aggregates every module's tests so `zig build test` runs them all. Logging records are built by producers and drained by a dedicated writer thread over a bounded MPSC ring (non-blocking producers). Parsers are zero-copy where practical (slices into the caller's input buffer).

**Tech Stack:** Zig **0.14.x** (pinned), `std.crypto.hash.Sha1`, `std.json`, `std.Thread.{Mutex,Condition}`, `std.ArrayList`. No third-party dependencies in M0.

> **Zig version note:** All code targets Zig **0.14.x**. If the installed std/build API has drifted, the per-task `zig build test` step will surface it; adapt the call site to the installed API and keep the test's intent. Do not change a test's asserted behavior to make it pass.

---

## File structure

```
conveyance/
  build.zig                 # build: exe "conveyance", `run` step, `test` step
  build.zig.zon             # package manifest
  src/
    main.zig                # daemon entry stub (prints version, exits) — fleshed out in M1
    root.zig                # test aggregator: `_ = @import(...)` every module
    log/
      record.zig            # Level, Value, Field, Record types + value formatting
      format_ndjson.zig     # Record -> one JSON object line
      format_pretty.zig     # Record -> aligned colored line
      ring.zig              # bounded MPSC ring buffer (mutex+condvar)
      logger.zig            # Logger facade: bound-context .with(), writer thread, dropped counter
    bencode/
      decode.zig            # streaming decoder -> Value tree (zero-copy string slices)
      encode.zig            # Value tree -> bytes
    metainfo/
      metainfo.zig          # parse .torrent -> Metainfo; infohash (SHA-1 of raw info dict)
    resume_state/
      import.zig            # parse transmission .resume bencode -> ResumeState
      sidecar.zig           # write/read our own JSON resume sidecar (round-trip)
  tests/
    fixtures/               # sample .torrent / .resume files (added in tasks that need them)
```

> Directory is named `resume_state/` (not `resume/`) because `resume` is awkward as a Zig identifier in some contexts and avoids confusion with the on-disk `resume/` dir we read from.

---

## Task 1: Project scaffold + toolchain

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `src/root.zig`

- [ ] **Step 1: Install Zig 0.14.x**

Run:
```bash
cd /home/joey/src/conveyance
ZIG_VER=0.14.1
curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-linux-x86_64-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz \
  || curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz
mkdir -p "$HOME/.local/zig" && tar -xf /tmp/zig.tar.xz -C "$HOME/.local/zig" --strip-components=1
ln -sf "$HOME/.local/zig/zig" "$HOME/.local/bin/zig"
export PATH="$HOME/.local/bin:$PATH"
zig version
```
Expected: prints `0.14.1` (or the chosen 0.14.x). If that exact patch 404s, list available versions at https://ziglang.org/download/ and pick the latest `0.14.x`.

- [ ] **Step 2: Write `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "conveyance",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the conveyance daemon");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 3: Write `build.zig.zon`**

```zig
.{
    .name = .conveyance,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .minimum_zig_version = "0.14.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

> If `zig build` complains that `.fingerprint = 0x0` is invalid, replace it with the value Zig prints in the error message (Zig generates a per-package fingerprint), then re-run.

- [ ] **Step 4: Write `src/main.zig` (stub)**

```zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("conveyance 0.0.0\n", .{});
}
```

- [ ] **Step 5: Write `src/root.zig` (test aggregator)**

```zig
// Aggregates every module's tests so `zig build test` runs them all.
// Add a line here for each new module file as it is created.
test {
    _ = @import("main.zig");
}
```

- [ ] **Step 6: Verify build + test run**

Run:
```bash
cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build && PATH="$HOME/.local/bin:$PATH" zig build test
```
Expected: both succeed with no errors (zero tests run is fine at this point). `zig-out/bin/conveyance` exists; running it prints `conveyance 0.0.0`.

- [ ] **Step 7: Commit**

```bash
git add build.zig build.zig.zon src/main.zig src/root.zig
git commit -m "chore: scaffold Zig project (build, run, test steps)"
```

---

## Task 2: Logging core types (`log/record.zig`)

**Files:**
- Create: `src/log/record.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/log/record.zig`:
```zig
const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }
};

pub const Subsystem = enum {
    loader,
    scanner,
    session,
    tracker,
    peer,
    picker,
    storage,
    rpc,
    net,

    pub fn label(self: Subsystem) []const u8 {
        return @tagName(self);
    }
};

/// A typed log field value. Owns no memory; string slices must outlive the record.
pub const Value = union(enum) {
    int: i64,
    uint: u64,
    str: []const u8,
    boolean: bool,
    infohash: [20]u8, // raw, rendered as 40 hex chars
    peer: std.net.Address,
    piece: u32,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub const max_fields = 12;

pub const Record = struct {
    ts_ns: i128,
    level: Level,
    subsystem: Subsystem,
    msg: []const u8,
    fields: [max_fields]Field = undefined,
    field_count: usize = 0,

    pub fn addField(self: *Record, f: Field) void {
        if (self.field_count >= max_fields) return; // silently drop overflow fields
        self.fields[self.field_count] = f;
        self.field_count += 1;
    }

    pub fn fieldSlice(self: *const Record) []const Field {
        return self.fields[0..self.field_count];
    }
};

test "addField appends up to max_fields then drops overflow" {
    var r = Record{ .ts_ns = 0, .level = .info, .subsystem = .session, .msg = "hi" };
    var i: usize = 0;
    while (i < max_fields + 3) : (i += 1) {
        r.addField(.{ .key = "k", .value = .{ .uint = i } });
    }
    try std.testing.expectEqual(@as(usize, max_fields), r.field_count);
    try std.testing.expectEqual(@as(usize, max_fields), r.fieldSlice().len);
}

test "Level.label" {
    try std.testing.expectEqualStrings("error", Level.err.label());
    try std.testing.expectEqualStrings("trace", Level.trace.label());
}
```

- [ ] **Step 2: Register module in `root.zig`**

In `src/root.zig`, add inside the `test` block:
```zig
    _ = @import("log/record.zig");
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS (both `record.zig` tests).

- [ ] **Step 4: Commit**

```bash
git add src/log/record.zig src/root.zig
git commit -m "feat(log): record/field/level/subsystem types"
```

---

## Task 3: ndjson formatter (`log/format_ndjson.zig`)

**Files:**
- Create: `src/log/format_ndjson.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/log/format_ndjson.zig`:
```zig
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

/// Minimal RFC8259 string escaping (the subset our keys/messages use).
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("log/format_ndjson.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. If `std.fmt.fmtSliceHexLower` or `fixedBufferStream` was renamed in the installed version, adapt the call (intent: lowercase hex; an in-memory writer).

- [ ] **Step 4: Commit**

```bash
git add src/log/format_ndjson.zig src/root.zig
git commit -m "feat(log): ndjson record formatter"
```

---

## Task 4: Pretty formatter (`log/format_pretty.zig`)

**Files:**
- Create: `src/log/format_pretty.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/log/format_pretty.zig`:
```zig
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
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[32m", // green
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("log/format_pretty.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. (If width-padding spec `{s: <5}` differs, the no-color assertion will show the actual string — match the assertion to the format you chose, keeping fields space-separated.)

- [ ] **Step 4: Commit**

```bash
git add src/log/format_pretty.zig src/root.zig
git commit -m "feat(log): pretty/TTY record formatter"
```

---

## Task 5: Bounded MPSC ring (`log/ring.zig`)

**Files:**
- Create: `src/log/ring.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/log/ring.zig`:
```zig
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
    try std.testing.expectEqual(@as(?rec.Record, null), ring.pop());
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("log/ring.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. The concurrency test must drain exactly `total` records (no spin-drop since the single producer retries until space frees up).

- [ ] **Step 4: Commit**

```bash
git add src/log/ring.zig src/root.zig
git commit -m "feat(log): bounded MPSC ring buffer"
```

---

## Task 6: Logger facade + writer thread (`log/logger.zig`)

**Files:**
- Create: `src/log/logger.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/log/logger.zig`:
```zig
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
    dropped: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, level: rec.Level, sink: Sink) !*Log {
        const self = try allocator.create(Log);
        self.* = .{ .ring = try Ring.init(allocator, capacity), .sink = sink, .level = level };
        self.thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        return self;
    }

    /// Stops the writer thread, drains remaining records, frees the ring.
    /// Does not free `self` itself — caller's allocator owns that.
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
        var buf: [4096]u8 = undefined;
        while (self.ring.pop()) |r| {
            var stream = std.io.fixedBufferStream(&buf);
            const w = stream.writer();
            switch (self.sink.format) {
                .ndjson => ndjson.write(w, &r) catch continue,
                .pretty => pretty.write(w, &r, self.sink.color) catch continue,
            }
            w.writeByte('\n') catch {};
            self.sink.writer.writeAll(stream.getWritten()) catch {};
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("log/logger.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. Common drift points: `std.io.AnyWriter` / `.writer().any()` (the type-erased writer) and `std.ArrayList(u8).init(allocator)`. If the installed std renamed these, adapt — intent is "an erased writer the logger thread writes formatted lines to."

- [ ] **Step 4: Commit**

```bash
git add src/log/logger.zig src/root.zig
git commit -m "feat(log): async Logger facade with bound context + writer thread"
```

---

## Task 7: Bencode decoder — scalars (`bencode/decode.zig`)

**Files:**
- Create: `src/bencode/decode.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/bencode/decode.zig`:
```zig
const std = @import("std");

pub const Error = error{
    Truncated,
    InvalidInteger,
    InvalidString,
    InvalidStructure,
    TrailingData,
    OutOfMemory,
};

pub const Value = union(enum) {
    int: i64,
    /// Slice into the *input* buffer (zero-copy). Valid only while input lives.
    str: []const u8,
    list: []Value,
    dict: []Pair,
};

pub const Pair = struct { key: []const u8, value: Value };

/// Cursor over the input. `pos` advances as values are parsed.
pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{ .input = input, .allocator = allocator };
    }

    fn peek(self: *Parser) Error!u8 {
        if (self.pos >= self.input.len) return Error.Truncated;
        return self.input[self.pos];
    }

    pub fn parseInt(self: *Parser) Error!i64 {
        if (try self.peek() != 'i') return Error.InvalidInteger;
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != 'e') self.pos += 1;
        if (self.pos >= self.input.len) return Error.Truncated;
        const digits = self.input[start..self.pos];
        self.pos += 1; // consume 'e'
        if (digits.len == 0) return Error.InvalidInteger;
        // reject leading zeros ("i03e") and "-0"
        if (std.mem.eql(u8, digits, "-0")) return Error.InvalidInteger;
        if (digits[0] == '0' and digits.len > 1) return Error.InvalidInteger;
        if (digits.len > 1 and digits[0] == '-' and digits[1] == '0') return Error.InvalidInteger;
        return std.fmt.parseInt(i64, digits, 10) catch Error.InvalidInteger;
    }

    pub fn parseString(self: *Parser) Error![]const u8 {
        const c = try self.peek();
        if (c < '0' or c > '9') return Error.InvalidString;
        const colon = std.mem.indexOfScalarPos(u8, self.input, self.pos, ':') orelse return Error.Truncated;
        const len = std.fmt.parseInt(usize, self.input[self.pos..colon], 10) catch return Error.InvalidString;
        const start = colon + 1;
        const end = std.math.add(usize, start, len) catch return Error.InvalidString;
        if (end > self.input.len) return Error.Truncated;
        self.pos = end;
        return self.input[start..end];
    }
};

test "decode: positive and negative integers" {
    var p = Parser.init(std.testing.allocator, "i42e");
    try std.testing.expectEqual(@as(i64, 42), try p.parseInt());

    var p2 = Parser.init(std.testing.allocator, "i-13e");
    try std.testing.expectEqual(@as(i64, -13), try p2.parseInt());
}

test "decode: rejects leading-zero and negative-zero integers" {
    var a = Parser.init(std.testing.allocator, "i03e");
    try std.testing.expectError(Error.InvalidInteger, a.parseInt());
    var b = Parser.init(std.testing.allocator, "i-0e");
    try std.testing.expectError(Error.InvalidInteger, b.parseInt());
}

test "decode: string is a zero-copy slice of input" {
    const input = "5:hello";
    var p = Parser.init(std.testing.allocator, input);
    const s = try p.parseString();
    try std.testing.expectEqualStrings("hello", s);
    try std.testing.expect(s.ptr == input.ptr + 2); // points into input
}

test "decode: truncated string errors" {
    var p = Parser.init(std.testing.allocator, "5:hel");
    try std.testing.expectError(Error.Truncated, p.parseString());
}
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("bencode/decode.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/bencode/decode.zig src/root.zig
git commit -m "feat(bencode): scalar decode (int, string) with validation"
```

---

## Task 8: Bencode decoder — lists & dicts (`bencode/decode.zig`)

**Files:**
- Modify: `src/bencode/decode.zig`

- [ ] **Step 1: Write the failing test**

Append the recursive parser + tests to `src/bencode/decode.zig` (inside the `Parser` struct add these methods, then add tests at file end):

Add methods inside `Parser`:
```zig
    pub fn parseValue(self: *Parser) Error!Value {
        const c = try self.peek();
        return switch (c) {
            'i' => .{ .int = try self.parseInt() },
            'l' => try self.parseList(),
            'd' => try self.parseDict(),
            '0'...'9' => .{ .str = try self.parseString() },
            else => Error.InvalidStructure,
        };
    }

    fn parseList(self: *Parser) Error!Value {
        self.pos += 1; // 'l'
        var items = std.ArrayList(Value).init(self.allocator);
        errdefer items.deinit();
        while (true) {
            if (try self.peek() == 'e') {
                self.pos += 1;
                return .{ .list = try items.toOwnedSlice() };
            }
            try items.append(try self.parseValue());
        }
    }

    fn parseDict(self: *Parser) Error!Value {
        self.pos += 1; // 'd'
        var pairs = std.ArrayList(Pair).init(self.allocator);
        errdefer pairs.deinit();
        while (true) {
            if (try self.peek() == 'e') {
                self.pos += 1;
                return .{ .dict = try pairs.toOwnedSlice() };
            }
            const key = try self.parseString();
            const value = try self.parseValue();
            try pairs.append(.{ .key = key, .value = value });
        }
    }

    /// Parse exactly one top-level value; error if trailing bytes remain.
    pub fn parseTop(self: *Parser) Error!Value {
        const v = try self.parseValue();
        if (self.pos != self.input.len) return Error.TrailingData;
        return v;
    }

    /// Returns the byte range [start,end) of the raw encoding of the next value
    /// WITHOUT building a tree. Used to capture the info-dict bytes for infohash.
    pub fn rawSpanOfValue(self: *Parser) Error![]const u8 {
        const start = self.pos;
        _ = try self.parseValueSkip();
        return self.input[start..self.pos];
    }

    fn parseValueSkip(self: *Parser) Error!void {
        const c = try self.peek();
        switch (c) {
            'i' => _ = try self.parseInt(),
            '0'...'9' => _ = try self.parseString(),
            'l' => {
                self.pos += 1;
                while (try self.peek() != 'e') try self.parseValueSkip();
                self.pos += 1;
            },
            'd' => {
                self.pos += 1;
                while (try self.peek() != 'e') {
                    _ = try self.parseString();
                    try self.parseValueSkip();
                }
                self.pos += 1;
            },
            else => return Error.InvalidStructure,
        }
    }
```

> **Memory note:** `parseList`/`parseDict` allocate slices with `self.allocator`. Callers should use an arena allocator and free the whole arena at once (this is how `metainfo` and `resume_state` will use it). Individual `Value` trees are not recursively freed.

Add tests at end of file:
```zig
fn dictGet(v: Value, key: []const u8) ?Value {
    for (v.dict) |pair| if (std.mem.eql(u8, pair.key, key)) return pair.value;
    return null;
}

test "decode: nested list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "li1ei2e3:abce");
    const v = try p.parseTop();
    try std.testing.expectEqual(@as(usize, 3), v.list.len);
    try std.testing.expectEqual(@as(i64, 1), v.list[0].int);
    try std.testing.expectEqualStrings("abc", v.list[2].str);
}

test "decode: dict with mixed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "d3:cow3:moo4:spami42ee");
    const v = try p.parseTop();
    try std.testing.expectEqualStrings("moo", dictGet(v, "cow").?.str);
    try std.testing.expectEqual(@as(i64, 42), dictGet(v, "spam").?.int);
}

test "decode: trailing data rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "i1eX");
    try std.testing.expectError(Error.TrailingData, p.parseTop());
}

test "decode: rawSpanOfValue captures exact dict bytes" {
    const input = "d4:infod1:ai1eee"; // {info: {a:1}}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), input);
    // manually walk to the value of "info"
    p.pos += 1; // 'd'
    _ = try p.parseString(); // "info"
    const span = try p.rawSpanOfValue();
    try std.testing.expectEqualStrings("d1:ai1ee", span);
}
```

- [ ] **Step 2: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS (all decode tests including Task 7's).

- [ ] **Step 3: Commit**

```bash
git add src/bencode/decode.zig
git commit -m "feat(bencode): recursive list/dict decode + raw-span capture"
```

---

## Task 9: Bencode encoder (`bencode/encode.zig`)

**Files:**
- Create: `src/bencode/encode.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/bencode/encode.zig`:
```zig
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("bencode/encode.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/bencode/encode.zig src/root.zig
git commit -m "feat(bencode): Value-tree encoder with byte-exact round-trip"
```

---

## Task 10: Metainfo parse (`metainfo/metainfo.zig`)

**Files:**
- Create: `src/metainfo/metainfo.zig`
- Create: `tests/fixtures/single.torrent` (generated in Step 1)
- Modify: `src/root.zig`

- [ ] **Step 1: Generate a tiny fixture torrent**

Run (creates a valid single-file .torrent with known values):
```bash
cd /home/joey/src/conveyance && mkdir -p tests/fixtures
python3 - <<'PY'
import hashlib, pathlib
# info dict: name=hello.txt, piece length=16384, length=11, one 20-byte piece hash
pieces = hashlib.sha1(b"hello world").digest()
info = b"d6:lengthi11e4:name9:hello.txt12:piece lengthi16384e6:pieces20:" + pieces + b"e"
meta = b"d8:announce20:http://tracker:6969/4:info" + info + b"e"
pathlib.Path("tests/fixtures/single.torrent").write_bytes(meta)
print("infohash", hashlib.sha1(info).hexdigest())
PY
```
Record the printed infohash; the test below asserts it.

- [ ] **Step 2: Write the failing test**

Create `src/metainfo/metainfo.zig` (replace `INFOHASH_HEX` placeholder in the test with the value printed in Step 1):
```zig
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
    const piece_length: u64 = @intCast(try getInt(info, "piece length"));
    const pieces = try getStr(info, "pieces");

    var files = std.ArrayList(FileEntry).init(arena);
    var total: u64 = 0;
    if (get(info, "files")) |files_v| {
        if (files_v != .list) return Error.BadType;
        for (files_v.list) |fe| {
            const len: u64 = @intCast(try getInt(fe, "length"));
            const path_v = get(fe, "path") orelse return Error.MissingField;
            if (path_v != .list) return Error.BadType;
            var parts = std.ArrayList(u8).init(arena);
            for (path_v.list, 0..) |seg, i| {
                if (seg != .str) return Error.BadType;
                if (i != 0) try parts.append('/');
                try parts.appendSlice(seg.str);
            }
            try files.append(.{ .length = len, .path = try parts.toOwnedSlice() });
            total += len;
        }
    } else {
        const len: u64 = @intCast(try getInt(info, "length"));
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
        .announce = getStr(root, "announce") catch null,
    };
}

test "metainfo: parses single-file fixture" {
    const bytes = @embedFile("../../tests/fixtures/single.torrent");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mi = try parse(arena.allocator(), bytes);

    try std.testing.expectEqualStrings("hello.txt", mi.name);
    try std.testing.expectEqual(@as(u64, 16384), mi.piece_length);
    try std.testing.expectEqual(@as(u64, 11), mi.total_length);
    try std.testing.expectEqual(@as(usize, 1), mi.files.len);
    try std.testing.expectEqual(@as(usize, 1), mi.pieceCount());
    try std.testing.expectEqualStrings("http://tracker:6969/", mi.announce.?);

    const expected_hex = "INFOHASH_HEX"; // <-- paste from Step 1
    var got_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&got_hex, "{s}", .{std.fmt.fmtSliceHexLower(&mi.info_hash)}) catch unreachable;
    try std.testing.expectEqualStrings(expected_hex, &got_hex);
}
```

- [ ] **Step 3: Register in `root.zig`**

Add: `    _ = @import("metainfo/metainfo.zig");`

- [ ] **Step 4: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. If `@embedFile` path resolution differs, note `@embedFile` is relative to the importing file (`src/metainfo/metainfo.zig`), hence `../../tests/...`.

- [ ] **Step 5: Commit**

```bash
git add src/metainfo/metainfo.zig src/root.zig tests/fixtures/single.torrent
git commit -m "feat(metainfo): parse .torrent + compute infohash from raw info dict"
```

---

## Task 11: Import transmission `.resume` (`resume_state/import.zig`)

**Files:**
- Create: `src/resume_state/import.zig`
- Create: `tests/fixtures/sample.resume` (generated in Step 1)
- Modify: `src/root.zig`

- [ ] **Step 1: Generate a `.resume` fixture**

Run:
```bash
cd /home/joey/src/conveyance && python3 - <<'PY'
import pathlib
# Minimal transmission-style resume dict (bencode):
# name, downloaded, uploaded, paused, destination, progress->pieces bitfield
data = (b"d"
        b"4:name9:hello.txt"
        b"10:downloadedi11e"
        b"8:uploadedi0e"
        b"6:pausedi0e"
        b"11:destination4:/tmp"
        b"e")
pathlib.Path("tests/fixtures/sample.resume").write_bytes(data)
print("wrote", len(data), "bytes")
PY
```

- [ ] **Step 2: Write the failing test**

Create `src/resume_state/import.zig`:
```zig
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
        rs.downloaded = @intCast(v.int);
    }
    if (get(root, "uploaded")) |v| {
        if (v != .int) return Error.BadType;
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
    const bytes = @embedFile("../../tests/fixtures/sample.resume");
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
```

- [ ] **Step 3: Register in `root.zig`**

Add: `    _ = @import("resume_state/import.zig");`

- [ ] **Step 4: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/resume_state/import.zig src/root.zig tests/fixtures/sample.resume
git commit -m "feat(resume): import subset of transmission .resume state"
```

---

## Task 12: Our resume sidecar — write + read round-trip (`resume_state/sidecar.zig`)

**Files:**
- Create: `src/resume_state/sidecar.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test**

Create `src/resume_state/sidecar.zig`:
```zig
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
```

- [ ] **Step 2: Register in `root.zig`**

Add: `    _ = @import("resume_state/sidecar.zig");`

- [ ] **Step 3: Run tests**

Run: `cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test`
Expected: PASS. **Likely drift point:** `std.json.stringify(value, options, writer)` was reorganized in the writergate. If the installed std uses `std.json.Stringify` or `std.json.fmt`, adapt the `write` body — intent: emit the struct as a JSON object. Keep the `read` side using `parseFromSlice`.

- [ ] **Step 4: Commit**

```bash
git add src/resume_state/sidecar.zig src/root.zig
git commit -m "feat(resume): own JSON resume sidecar with write/read round-trip"
```

---

## Task 13: M0 wrap-up — wire main + smoke check

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Replace `main.zig` to exercise the logger end-to-end**

```zig
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
```

- [ ] **Step 2: Build, test, and smoke-run**

Run:
```bash
cd /home/joey/src/conveyance && PATH="$HOME/.local/bin:$PATH" zig build test \
  && PATH="$HOME/.local/bin:$PATH" zig build \
  && ./zig-out/bin/conveyance 2>&1 | cat
```
Expected: all tests PASS; the binary prints one ndjson line containing `"msg":"conveyance.start"` and `"version":"0.0.0"` (piped through `cat`, so non-TTY → ndjson).

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat: wire async logger into daemon entry (M0 smoke path)"
```

---

## Self-review (completed by plan author)

**Spec coverage (M0 portion of the spec):**
- Build/test scaffolding (spec §12) → Task 1. ✓
- Structured records + typed fields (spec §6) → Task 2. ✓
- ndjson + pretty formats, isatty-selected (spec §6) → Tasks 3, 4, 13. ✓
- Bound-context loggers (spec §6) → Task 6. ✓
- Non-blocking ring + dropped counter (spec §3, §6) → Tasks 5, 6. ✓
- bencode decode/encode (spec §4) → Tasks 7–9. ✓
- metainfo parse + infohash (spec §4, §5.1) → Task 10. ✓
- resume import (read-compat) (spec §7) → Task 11. ✓
- own resume write format (spec §7) → Task 12. ✓

**Deferred to later milestone plans (correctly out of M0 scope):** session thread, loader pool, reactor/net, tracker, peer, picker, storage, RPC, settings.json reader, graceful shutdown. These belong to M1+ plans.

**Placeholder scan:** The only intentional fill-in is `INFOHASH_HEX` in Task 10, which Step 1 of that task computes and prints for the engineer to paste. No other placeholders.

**Type consistency:** `rec.Record`/`rec.Field`/`rec.Value`/`rec.Level`/`rec.Subsystem` are defined in Task 2 and used unchanged in Tasks 3–6 and 13. `dec.Value`/`dec.Pair`/`Parser` defined in Task 7, extended in Task 8, consumed in Tasks 9–11. `ResumeState` defined in Task 11, consumed in Task 12. `Logger.with`/`.info`/`.log_` signatures are consistent between Task 6 and Task 13.
