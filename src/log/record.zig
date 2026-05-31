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
