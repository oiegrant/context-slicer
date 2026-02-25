const std = @import("std");

/// Parsed arguments for the `record` subcommand.
pub const RecordArgs = struct {
    scenario_name: []const u8,
    run_args: []const []const u8,
    run_script: ?[]const u8,
    namespace: ?[]const u8,
    server_port: ?i64,
    /// When false, transform capture is disabled (--no-transforms flag).
    transforms_enabled: bool = true,
};

fn printRecordUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\Usage: context-slicer record <scenario> [options]
        \\
        \\Record a scenario: runs static analysis and runtime instrumentation on the
        \\target Java project, producing a context slice in `.context-slice/`.
        \\
        \\Arguments:
        \\  <scenario>                  Name of the scenario to record (e.g. "submit-order")
        \\
        \\Options:
        \\  --run-script "<command>"    Shell command to trigger the scenario (e.g. a curl invocation)
        \\  --namespace <prefix>        Java package prefix to filter classes (e.g. com.example.)
        \\  --port <N>                  Port the target server listens on
        \\  --args "<run-args>"         Extra arguments to pass to the target application
        \\  --no-transforms             Disable data transform capture (faster, but no field-level diffs)
        \\  --help                      Show this help message
        \\
    ) catch {};
}

/// Parse `record` subcommand arguments.
/// Expected format: record <scenario_name> [--args "<run-args>"]
///
/// Returns `error.HelpRequested` if `--help` or `-h` is present.
/// Returns `error.MissingScenarioName` if no positional arg is given.
/// Returns `error.UnknownFlag` for unrecognized flags.
pub fn parse(
    args: []const []const u8,
    allocator: std.mem.Allocator,
) !RecordArgs {
    // Check for --help before anything else
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printRecordUsage();
            return error.HelpRequested;
        }
    }

    if (args.len == 0) {
        return error.MissingScenarioName;
    }

    const scenario_name = args[0];
    var run_args: []const []const u8 = &[_][]const u8{};
    var run_script: ?[]const u8 = null;
    var namespace: ?[]const u8 = null;
    var server_port: ?i64 = null;
    var transforms_enabled: bool = true;

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--args")) {
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
        } else if (std.mem.eql(u8, arg, "--run-script")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            run_script = args[i];
        } else if (std.mem.eql(u8, arg, "--namespace")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            namespace = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            server_port = try std.fmt.parseInt(i64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--no-transforms")) {
            transforms_enabled = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        }
        i += 1;
    }

    return RecordArgs{
        .scenario_name = scenario_name,
        .run_args = run_args,
        .run_script = run_script,
        .namespace = namespace,
        .server_port = server_port,
        .transforms_enabled = transforms_enabled,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse record: scenario name only" {
    const args = [_][]const u8{"submit-order"};
    const result = try parse(&args, std.testing.allocator);
    defer if (result.run_args.len > 0) std.testing.allocator.free(result.run_args);

    try std.testing.expectEqualStrings("submit-order", result.scenario_name);
    try std.testing.expect(result.run_script == null);
    try std.testing.expect(result.namespace == null);
    try std.testing.expect(result.server_port == null);
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

test "parse record: --help returns HelpRequested" {
    const args = [_][]const u8{ "submit-order", "--help" };
    const result = parse(&args, std.testing.allocator);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse record: -h returns HelpRequested" {
    const args = [_][]const u8{"-h"};
    const result = parse(&args, std.testing.allocator);
    try std.testing.expectError(error.HelpRequested, result);
}

test "parse record: --port invalid value returns error" {
    const args = [_][]const u8{ "submit-order", "--port", "notanumber" };
    const result = parse(&args, std.testing.allocator);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "parse record: transforms_enabled defaults to true" {
    const args = [_][]const u8{"submit-order"};
    const result = try parse(&args, std.testing.allocator);
    defer if (result.run_args.len > 0) std.testing.allocator.free(result.run_args);
    try std.testing.expect(result.transforms_enabled);
}

test "parse record: --no-transforms sets transforms_enabled false" {
    const args = [_][]const u8{ "submit-order", "--no-transforms" };
    const result = try parse(&args, std.testing.allocator);
    defer if (result.run_args.len > 0) std.testing.allocator.free(result.run_args);
    try std.testing.expect(!result.transforms_enabled);
}

test "parse record: --no-transforms combined with other flags" {
    const args = [_][]const u8{ "submit-order", "--no-transforms", "--namespace", "com.example" };
    const result = try parse(&args, std.testing.allocator);
    defer if (result.run_args.len > 0) std.testing.allocator.free(result.run_args);
    try std.testing.expect(!result.transforms_enabled);
    try std.testing.expectEqualStrings("com.example", result.namespace.?);
}
