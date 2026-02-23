const std = @import("std");

/// Global verbose flag. Set to true by passing `--verbose` on the CLI before running commands.
/// Not thread-safe after initialization — set once during program startup.
pub var verbose: bool = false;

/// Emit a debug message to stderr. No-op unless `verbose` is true.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!verbose) return;
    std.debug.print("[debug] " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "debug is a no-op when verbose=false" {
    verbose = false;
    // Calling this must not panic:
    debug("count={d}", .{42});
}

test "debug does not panic when verbose=true" {
    verbose = true;
    defer verbose = false;
    debug("symbols={d} edges={d}", .{ 10, 5 });
}
