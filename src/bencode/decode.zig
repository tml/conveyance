const std = @import("std");

pub const Error = error{
    Truncated,
    InvalidInteger,
    InvalidString,
    InvalidStructure,
    TrailingData,
    NestingDepth,
    OutOfMemory,
};

/// Maximum nesting depth for lists/dicts. Generous compared to real-world
/// torrents (Transmission uses ~64); set to 512 to allow uncommon-but-valid
/// nesting while still bounding stack use to a few hundred KB.
pub const max_depth: usize = 512;

pub const Value = union(enum) {
    int: i64,
    /// Slice into the *input* buffer (zero-copy). Valid only while input lives.
    str: []const u8,
    list: []Value,
    dict: []Pair,
};

pub const Pair = struct { key: []const u8, value: Value };

/// Cursor over the input. `pos` advances as values are parsed; on any error
/// return, `pos` is undefined and the parser must not be reused.
///
/// `allocator` MUST be an arena (or arena-backed). `parseList`/`parseDict` allocate
/// the list/dict slices via it; Value trees have no recursive destructor. On
/// partial-parse failure, `errdefer` only frees the outer ArrayList — already-
/// appended child trees stay alive until the arena is reset. Do NOT pass a GPA
/// expecting per-Value cleanup on error.
pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    depth: usize = 0,
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

    /// Parse the next value from the current position. Does NOT verify that
    /// the input has been fully consumed; use parseTop for complete-document
    /// parsing.
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
        if (self.depth >= max_depth) return Error.NestingDepth;
        self.depth += 1;
        defer self.depth -= 1;
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
        if (self.depth >= max_depth) return Error.NestingDepth;
        self.depth += 1;
        defer self.depth -= 1;
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
    /// On error, `pos` is undefined — do not reuse the parser.
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
                if (self.depth >= max_depth) return Error.NestingDepth;
                self.depth += 1;
                defer self.depth -= 1;
                self.pos += 1;
                while (try self.peek() != 'e') try self.parseValueSkip();
                self.pos += 1;
            },
            'd' => {
                if (self.depth >= max_depth) return Error.NestingDepth;
                self.depth += 1;
                defer self.depth -= 1;
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

test "decode: structurally nested list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "lli1eee");
    const v = try p.parseTop();
    try std.testing.expectEqual(@as(usize, 1), v.list.len);
    try std.testing.expectEqual(@as(usize, 1), v.list[0].list.len);
    try std.testing.expectEqual(@as(i64, 1), v.list[0].list[0].int);
}

test "decode: nesting depth limit enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // max_depth+1 levels of 'l' opens — must error before stack overflow.
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const over = max_depth + 1;
    var i: usize = 0;
    while (i < over) : (i += 1) try buf.append('l');
    i = 0;
    while (i < over) : (i += 1) try buf.append('e');
    var p = Parser.init(arena.allocator(), buf.items);
    try std.testing.expectError(Error.NestingDepth, p.parseTop());
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
