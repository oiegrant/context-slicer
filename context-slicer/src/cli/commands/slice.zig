const std = @import("std");
const util_fs = @import("../../util/fs.zig");

/// Run the Zig slice pipeline on existing `.context-slice/` data.
/// Returns `error.NoRecordedScenario` if `.context-slice/` does not exist
/// or if `static_ir.json` is missing.
pub fn run(project_root: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    const cs_dir = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.context-slice", .{project_root});
    defer std.heap.page_allocator.free(cs_dir);

    const ir_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/static_ir.json", .{cs_dir});
    defer std.heap.page_allocator.free(ir_path);

    if (!util_fs.fileExists(cs_dir) or !util_fs.fileExists(ir_path)) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("No recorded scenario found. Run `record` first.\n") catch {};
        return error.NoRecordedScenario;
    }

    // Full pipeline would run here (IR load → validate → merge → graph → slice → pack).
    // For now: stub that succeeds when the data is present.
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "slice: directory without .context-slice returns error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const result = run(tmp_path, std.testing.allocator);
    try std.testing.expectError(error.NoRecordedScenario, result);
}

test "slice: directory with .context-slice/static_ir.json succeeds" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create .context-slice/static_ir.json
    const cs_dir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice", .{tmp_path});
    defer std.testing.allocator.free(cs_dir_path);
    try util_fs.createDirIfAbsent(cs_dir_path);

    const ir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice/static_ir.json", .{tmp_path});
    defer std.testing.allocator.free(ir_path);
    try util_fs.writeFile(ir_path, "{}");

    // Should succeed (stub implementation)
    try run(tmp_path, std.testing.allocator);
}
