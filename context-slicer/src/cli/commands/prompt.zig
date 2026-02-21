const std = @import("std");
const util_fs = @import("../../util/fs.zig");

/// Run the `prompt` command: load slice, build prompt, call Claude.
/// Returns `error.MissingTaskString` if no task argument is given.
/// Returns `error.NoSliceFound` if `.context-slice/metadata.json` does not exist.
pub fn run(
    task: ?[]const u8,
    project_root: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;

    if (task == null or task.?.len == 0) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Usage: context-slice prompt \"<your task>\"\n") catch {};
        return error.MissingTaskString;
    }

    const metadata_path = try std.fmt.allocPrint(std.heap.page_allocator,
        "{s}/.context-slice/metadata.json", .{project_root});
    defer std.heap.page_allocator.free(metadata_path);

    if (!util_fs.fileExists(metadata_path)) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("No slice found. Run `record` first.\n") catch {};
        return error.NoSliceFound;
    }

    // Full implementation: load slice, build prompt, call Claude.
    // For MVP stub: succeed silently.
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

    try run("Add idempotency", tmp_path, std.testing.allocator);
}
