const std = @import("std");
const util_fs = @import("../util/fs.zig");

const SYSTEM_PREAMBLE =
    \\You are a senior software engineer working on a large Java codebase.
    \\The following context was automatically extracted by Context Slice from a live scenario recording.
    \\Review the architecture and relevant source files, then complete the task described at the end.
    \\
;

/// Assembles a Claude prompt from a populated `.context-slice/` directory.
///
/// Structure:
///   [System preamble]
///   ## Architecture
///   [architecture.md contents]
///   ## Configuration
///   [config_usage.md contents]
///   ## Source Files
///   [contents of each file listed in relevant_files.txt]
///   ## Task
///   [user_task]
///
/// Returns `error.SliceNotFound` if `relevant_files.txt` does not exist.
/// Files listed in `relevant_files.txt` that no longer exist on disk are
/// skipped with a warning to stderr (not fatal).
///
/// Caller owns the returned slice and must free it with allocator.free().
pub fn build(slice_dir: []const u8, user_task: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Verify slice exists
    const files_path = try std.fmt.allocPrint(allocator, "{s}/relevant_files.txt", .{slice_dir});
    defer allocator.free(files_path);
    if (!util_fs.fileExists(files_path)) return error.SliceNotFound;

    // Read architecture.md (optional — skip if missing)
    const arch_path = try std.fmt.allocPrint(allocator, "{s}/architecture.md", .{slice_dir});
    defer allocator.free(arch_path);
    const arch_opt: ?[]const u8 = util_fs.readFileAlloc(arch_path, allocator) catch null;
    defer if (arch_opt) |a| allocator.free(a);
    const arch_content = arch_opt orelse "";

    // Read config_usage.md (optional)
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config_usage.md", .{slice_dir});
    defer allocator.free(config_path);
    const config_opt: ?[]const u8 = util_fs.readFileAlloc(config_path, allocator) catch null;
    defer if (config_opt) |c| allocator.free(c);
    const config_content = config_opt orelse "";

    // Read relevant_files.txt
    const files_content = try util_fs.readFileAlloc(files_path, allocator);
    defer allocator.free(files_content);

    // Build prompt
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll(SYSTEM_PREAMBLE);
    try writer.writeAll("\n## Architecture\n\n");
    try writer.writeAll(arch_content);
    try writer.writeAll("\n## Configuration\n\n");
    try writer.writeAll(config_content);
    try writer.writeAll("\n## Source Files\n\n");

    // Parse each line in relevant_files.txt
    var line_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, files_content, "\n\r"), '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const src = util_fs.readFileAlloc(trimmed, allocator) catch {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("Warning: skipping missing file: ") catch {};
            stderr.writeAll(trimmed) catch {};
            stderr.writeAll("\n") catch {};
            continue;
        };
        defer allocator.free(src);

        try writer.print("### {s}\n\n```\n", .{trimmed});
        try writer.writeAll(src);
        try writer.writeAll("\n```\n\n");
    }

    try writer.writeAll("## Task\n\n");
    try writer.writeAll(user_task);
    try writer.writeAll("\n");

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn writeSliceDir(
    tmp_path: []const u8,
    arch_content: []const u8,
    config_content: []const u8,
    files_list: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const arch_path = try std.fmt.allocPrint(allocator, "{s}/architecture.md", .{tmp_path});
    defer allocator.free(arch_path);
    try util_fs.writeFile(arch_path, arch_content);

    const config_path_str = try std.fmt.allocPrint(allocator, "{s}/config_usage.md", .{tmp_path});
    defer allocator.free(config_path_str);
    try util_fs.writeFile(config_path_str, config_content);

    const files_path = try std.fmt.allocPrint(allocator, "{s}/relevant_files.txt", .{tmp_path});
    defer allocator.free(files_path);
    try util_fs.writeFile(files_path, files_list);
}

test "prompt_builder: missing relevant_files.txt returns SliceNotFound" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const result = build(tmp_path, "Add idempotency", std.testing.allocator);
    try std.testing.expectError(error.SliceNotFound, result);
}

test "prompt_builder: prompt contains architecture.md content" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try writeSliceDir(tmp_path, "# Architecture: submit-order\n\nOrder flow here.", "", "", std.testing.allocator);

    const prompt = try build(tmp_path, "Add idempotency", std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Architecture: submit-order") != null);
}

test "prompt_builder: prompt contains config_usage.md content" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try writeSliceDir(tmp_path, "", "| order.payment.provider | stripe |", "", std.testing.allocator);

    const prompt = try build(tmp_path, "task", std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "order.payment.provider") != null);
}

test "prompt_builder: user task appears at end of prompt" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try writeSliceDir(tmp_path, "", "", "", std.testing.allocator);

    const prompt = try build(tmp_path, "Add idempotency key support", std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Add idempotency key support") != null);
    // Task should be near the end — after the ## Task heading
    const task_heading_pos = std.mem.indexOf(u8, prompt, "## Task").?;
    const task_pos = std.mem.indexOf(u8, prompt, "Add idempotency key support").?;
    try std.testing.expect(task_pos > task_heading_pos);
}

test "prompt_builder: source file content included with header" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Write a source file
    const src_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/Foo.java", .{tmp_path});
    defer std.testing.allocator.free(src_path);
    try util_fs.writeFile(src_path, "public class Foo {}");

    // relevant_files.txt lists the source file
    try writeSliceDir(tmp_path, "", "", src_path, std.testing.allocator);

    const prompt = try build(tmp_path, "task", std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    // Source file header and content should appear
    try std.testing.expect(std.mem.indexOf(u8, prompt, src_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "public class Foo {}") != null);
}

test "prompt_builder: missing source file is skipped gracefully" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try writeSliceDir(tmp_path, "", "", "/nonexistent/path/Missing.java", std.testing.allocator);

    // Should succeed (not fatal) even though the file is missing
    const prompt = try build(tmp_path, "task", std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(prompt.len > 0);
}
