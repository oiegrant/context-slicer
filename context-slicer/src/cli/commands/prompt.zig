const std = @import("std");
const util_fs = @import("../../util/fs.zig");
const prompt_builder = @import("../../ai/prompt_builder.zig");

/// Minimal view of metadata.json used for freshness / health checks.
const SliceMetadata = struct {
    timestampUnix: ?i64 = null,
    runtimeCaptured: ?bool = null,
};

fn printPromptUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\Usage: context-slicer prompt "<your task>"
        \\
        \\Build a context prompt from the recorded slice and write it to .context-slice/prompt.md.
        \\Requires a prior `record` run. The generated file can be pasted into any AI agent.
        \\
        \\Arguments:
        \\  "<your task>"    Description of the coding task you want help with
        \\
        \\Options:
        \\  --help           Show this help message
        \\
    ) catch {};
}

/// Run the `prompt` command: load slice, build prompt, write to .context-slice/prompt.md.
/// Returns `error.HelpRequested` if task is `--help` or `-h`.
/// Returns `error.MissingTaskString` if no task argument is given.
/// Returns `error.NoSliceFound` if `.context-slice/metadata.json` does not exist.
pub fn run(
    task: ?[]const u8,
    project_root: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Check for --help
    if (task != null and
        (std.mem.eql(u8, task.?, "--help") or std.mem.eql(u8, task.?, "-h")))
    {
        printPromptUsage();
        return error.HelpRequested;
    }

    if (task == null or task.?.len == 0) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Usage: context-slice prompt \"<your task>\"\n") catch {};
        return error.MissingTaskString;
    }

    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/.context-slice/metadata.json", .{project_root});
    defer allocator.free(metadata_path);

    if (!util_fs.fileExists(metadata_path)) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("No slice found. Run `record` first.\n") catch {};
        return error.NoSliceFound;
    }

    // P-003 / P-004: Check slice freshness and runtime_captured status (non-fatal warnings)
    checkSliceHealth(metadata_path, allocator);

    const slice_dir = try std.fmt.allocPrint(allocator, "{s}/.context-slice", .{project_root});
    defer allocator.free(slice_dir);

    // Build the prompt from the slice
    const prompt = try prompt_builder.build(slice_dir, task.?, allocator);
    defer allocator.free(prompt);

    // Write prompt to .context-slice/prompt.md
    const out_path = try std.fmt.allocPrint(allocator, "{s}/.context-slice/prompt.md", .{project_root});
    defer allocator.free(out_path);
    try util_fs.writeFile(out_path, prompt);

    const stdout = std.fs.File.stdout();
    stdout.writeAll("Prompt written to: ") catch {};
    stdout.writeAll(out_path) catch {};
    stdout.writeAll("\n\nOpen this file and paste its contents into your AI agent of choice.\n") catch {};
}

/// Emit non-fatal warnings about slice age and runtime capture status.
fn checkSliceHealth(metadata_path: []const u8, allocator: std.mem.Allocator) void {
    const content = util_fs.readFileAlloc(metadata_path, allocator) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(
        SliceMetadata,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    ) catch return;
    defer parsed.deinit();

    const md = parsed.value;
    const stderr = std.fs.File.stderr();

    // P-003: Freshness warning — warn if slice is older than 24 hours
    if (md.timestampUnix) |ts| {
        if (ts > 0) {
            const now = std.time.timestamp();
            if (now - ts > 86400) {
                stderr.writeAll(
                    "Warning: This slice is more than 24 hours old. Consider re-running `record`.\n",
                ) catch {};
            }
        }
    }

    // P-004: Runtime capture warning
    if (md.runtimeCaptured) |rc| {
        if (!rc) {
            stderr.writeAll(
                "Warning: This slice is static-only. Runtime instrumentation failed. Results may be less accurate.\n",
            ) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prompt: missing task string returns error" {
    const result = run(null, "/tmp", std.testing.allocator);
    try std.testing.expectError(error.MissingTaskString, result);
}

test "prompt: empty task string returns error" {
    const result = run("", "/tmp", std.testing.allocator);
    try std.testing.expectError(error.MissingTaskString, result);
}

test "prompt: --help returns HelpRequested" {
    const result = run("--help", "/tmp", std.testing.allocator);
    try std.testing.expectError(error.HelpRequested, result);
}

test "prompt: -h returns HelpRequested" {
    const result = run("-h", "/tmp", std.testing.allocator);
    try std.testing.expectError(error.HelpRequested, result);
}

test "prompt: missing .context-slice returns NoSliceFound" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const result = run("Add idempotency", tmp_path, std.testing.allocator);
    try std.testing.expectError(error.NoSliceFound, result);
}

test "prompt: with metadata.json present succeeds" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const cs_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice", .{tmp_path});
    defer std.testing.allocator.free(cs_dir);
    try util_fs.createDirIfAbsent(cs_dir);

    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice/metadata.json", .{tmp_path});
    defer std.testing.allocator.free(md_path);
    try util_fs.writeFile(md_path, "{\"scenarioName\":\"test\"}");

    // Write a minimal relevant_files.txt so prompt_builder doesn't fail
    const files_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/relevant_files.txt", .{cs_dir});
    defer std.testing.allocator.free(files_path);
    try util_fs.writeFile(files_path, "");

    // Should succeed: builds prompt and writes it to .context-slice/prompt.md
    try run("Add idempotency", tmp_path, std.testing.allocator);
}

test "checkSliceHealth: runtimeCaptured=false does not crash" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metadata.json", .{tmp_path});
    defer std.testing.allocator.free(md_path);
    try util_fs.writeFile(md_path, "{\"runtimeCaptured\":false,\"timestampUnix\":1}");

    // Should emit a warning to stderr but not crash or return an error
    checkSliceHealth(md_path, std.testing.allocator);
}

test "checkSliceHealth: missing file does not crash" {
    // Non-existent path — should silently return
    checkSliceHealth("/nonexistent/metadata.json", std.testing.allocator);
}

test "checkSliceHealth: malformed JSON does not crash" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metadata.json", .{tmp_path});
    defer std.testing.allocator.free(md_path);
    try util_fs.writeFile(md_path, "not valid json {{{{");

    // Should silently return on parse failure
    checkSliceHealth(md_path, std.testing.allocator);
}
