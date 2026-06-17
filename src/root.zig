// Aggregates every module's tests so `zig build test` runs them all.
// Add a line here for each new module file as it is created.
test {
    _ = @import("main.zig");
    _ = @import("log/record.zig");
    _ = @import("log/format_ndjson.zig");
    _ = @import("log/format_pretty.zig");
    _ = @import("log/ring.zig");
}
