const std = @import("std");

// Pull in command files so their tests are compiled when running `zig build test`.
comptime {
    _ = @import("commands/record.zig");
    _ = @import("commands/slice.zig");
    _ = @import("commands/prompt.zig");
}

pub const SubcommandTag = enum { record, slice, prompt };

/// Route `args[0]` to the appropriate subcommand.
/// Returns `error.UnknownSubcommand` if the subcommand is not recognized.
/// Returns `error.MissingSubcommand` if args is empty.
pub fn run(args: []const []const u8, allocator: std.mem.Allocator) !SubcommandTag {
    _ = allocator; // not needed at routing level yet
    if (args.len == 0) {
        printUsage();
        return error.MissingSubcommand;
    }

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "record")) {
        return .record;
    } else if (std.mem.eql(u8, cmd, "slice")) {
        return .slice;
    } else if (std.mem.eql(u8, cmd, "prompt")) {
        return .prompt;
    } else {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Unknown subcommand: ") catch {};
        stderr.writeAll(cmd) catch {};
        stderr.writeAll("\n") catch {};
        printUsage();
        return error.UnknownSubcommand;
    }
}

fn printUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\Usage: context-slicer <command> [options]
        \\
        \\Commands:
        \\  record  <scenario>   Record a scenario (static analysis + runtime trace)
        \\  slice                Re-run the Zig pipeline on existing recorded data
        \\  prompt  "<task>"     Generate a Claude prompt from the recorded slice
        \\
    ) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "record subcommand routes correctly" {
    const args = [_][]const u8{ "record", "submit-order" };
    const tag = try run(&args, std.testing.allocator);
    try std.testing.expectEqual(SubcommandTag.record, tag);
}

test "slice subcommand routes correctly" {
    const args = [_][]const u8{"slice"};
    const tag = try run(&args, std.testing.allocator);
    try std.testing.expectEqual(SubcommandTag.slice, tag);
}

test "prompt subcommand routes correctly" {
    const args = [_][]const u8{ "prompt", "Add idempotency" };
    const tag = try run(&args, std.testing.allocator);
    try std.testing.expectEqual(SubcommandTag.prompt, tag);
}

test "unknown subcommand returns error" {
    const args = [_][]const u8{"unknown"};
    const result = run(&args, std.testing.allocator);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "empty args returns error" {
    const args = [_][]const u8{};
    const result = run(&args, std.testing.allocator);
    try std.testing.expectError(error.MissingSubcommand, result);
}
