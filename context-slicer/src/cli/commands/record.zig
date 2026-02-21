const std = @import("std");

/// Parsed arguments for the `record` subcommand.
pub const RecordArgs = struct {
    scenario_name: []const u8,
    config_file: ?[]const u8,
    run_args: []const []const u8,
};

/// Parse `record` subcommand arguments.
/// Expected format: record <scenario_name> [--config <file>] [--args "<run-args>"]
///
/// Returns `error.MissingScenarioName` if no positional arg is given.
/// Returns `error.UnknownFlag` for unrecognized flags.
pub fn parse(
    args: []const []const u8,
    allocator: std.mem.Allocator,
) !RecordArgs {
    if (args.len == 0) {
        return error.MissingScenarioName;
    }

    const scenario_name = args[0];
    var config_file: ?[]const u8 = null;
    var run_args: []const []const u8 = &[_][]const u8{};

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            config_file = args[i];
        } else if (std.mem.eql(u8, arg, "--args")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            // Split the run-args string on spaces (simple split, no quoting support)
            const raw = args[i];
            var parts: std.ArrayListUnmanaged([]const u8) = .{};
            errdefer parts.deinit(allocator);
            var iter = std.mem.splitScalar(u8, raw, ' ');
            while (iter.next()) |part| {
                if (part.len > 0) try parts.append(allocator, part);
            }
            run_args = try parts.toOwnedSlice(allocator);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        }
        i += 1;
    }

    return RecordArgs{
        .scenario_name = scenario_name,
        .config_file = config_file,
        .run_args = run_args,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse record: scenario name + config" {
    const args = [_][]const u8{ "submit-order", "--config", "app.yml" };
    const result = try parse(&args, std.testing.allocator);
    defer if (result.run_args.len > 0) std.testing.allocator.free(result.run_args);

    try std.testing.expectEqualStrings("submit-order", result.scenario_name);
    try std.testing.expect(result.config_file != null);
    try std.testing.expectEqualStrings("app.yml", result.config_file.?);
}

test "parse record: missing scenario name returns error" {
    const args = [_][]const u8{};
    const result = parse(&args, std.testing.allocator);
    try std.testing.expectError(error.MissingScenarioName, result);
}

test "parse record: --args flag is parsed" {
    const args = [_][]const u8{ "submit-order", "--args", "--tenant=abc" };
    const result = try parse(&args, std.testing.allocator);
    defer std.testing.allocator.free(result.run_args);

    try std.testing.expectEqualStrings("submit-order", result.scenario_name);
    try std.testing.expectEqual(@as(usize, 1), result.run_args.len);
    try std.testing.expectEqualStrings("--tenant=abc", result.run_args[0]);
}

test "parse record: unknown flag returns error" {
    const args = [_][]const u8{ "submit-order", "--foo" };
    const result = parse(&args, std.testing.allocator);
    try std.testing.expectError(error.UnknownFlag, result);
}
