const std = @import("std");

/// Creates a directory if it does not already exist.
/// Returns without error if the directory already exists.
pub fn createDirIfAbsent(path: []const u8) !void {
    std.fs.cwd().makeDir(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}

/// Reads an entire file into a caller-owned slice.
/// Caller must free the returned slice with allocator.free().
pub fn readFileAlloc(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try file.readAll(buf);
    if (n != stat.size) return error.UnexpectedEof;
    return buf;
}

/// Writes content to a file, creating or truncating it.
pub fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

/// Returns true if a file or directory exists at the given path.
pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Joins path segments with the OS directory separator.
/// Caller owns the returned slice and must free it.
pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var total_len: usize = 0;
    for (parts) |part| total_len += part.len;
    // Add separators between parts
    total_len += parts.len - 1;

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (parts, 0..) |part, i| {
        @memcpy(result[pos .. pos + part.len], part);
        pos += part.len;
        if (i < parts.len - 1) {
            result[pos] = std.fs.path.sep;
            pos += 1;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createDirIfAbsent creates a new directory" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const new_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/test_create", .{tmp_path});
    defer std.testing.allocator.free(new_dir);

    try createDirIfAbsent(new_dir);
    try std.testing.expect(fileExists(new_dir));
}

test "createDirIfAbsent on existing directory does not error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try createDirIfAbsent(tmp_path);  // already exists — should not error
}

test "readFileAlloc reads correct bytes" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/hello.txt", .{tmp_path});
    defer std.testing.allocator.free(file_path);

    try writeFile(file_path, "hello world");

    const data = try readFileAlloc(file_path, std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqualStrings("hello world", data);
}

test "readFileAlloc on nonexistent file returns error" {
    const result = readFileAlloc("/nonexistent/path/that/does/not/exist.txt", std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, result);
}

test "writeFile then readFileAlloc round-trip" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/roundtrip.txt", .{tmp_path});
    defer std.testing.allocator.free(file_path);

    const content = "the quick brown fox\njumps over the lazy dog";
    try writeFile(file_path, content);

    const read_back = try readFileAlloc(file_path, std.testing.allocator);
    defer std.testing.allocator.free(read_back);

    try std.testing.expectEqualStrings(content, read_back);
}

test "joinPath with 3 segments" {
    const result = try joinPath(std.testing.allocator, &[_][]const u8{ "a", "b", "c" });
    defer std.testing.allocator.free(result);

    const expected = "a" ++ &[_]u8{std.fs.path.sep} ++ "b" ++ &[_]u8{std.fs.path.sep} ++ "c";
    try std.testing.expectEqualStrings(expected, result);
}

test "fileExists returns false for missing file" {
    try std.testing.expect(!fileExists("/this/path/does/not/exist.txt"));
}
