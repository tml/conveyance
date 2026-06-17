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
