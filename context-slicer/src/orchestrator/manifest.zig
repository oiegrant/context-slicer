const std = @import("std");
const util_fs = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");

/// Describes a recording scenario sent to the Java adapter.
/// Field names are snake_case to match the Java adapter's ManifestConfig.
pub const Manifest = struct {
    scenario_name: []const u8,
    entry_points: []const []const u8,
    run_args: []const []const u8,
    config_files: []const []const u8,
    output_dir: []const u8,
    // Optional fields read/preserved from the project's manifest.json
    namespace: ?[]const u8 = null,
    server_port: ?i64 = null,
    run_script: ?[]const u8 = null,
};

/// Serializes the manifest to `<dir>/manifest.json`.
/// Creates `dir` if it does not exist.
pub fn write(manifest: Manifest, dir: []const u8, allocator: std.mem.Allocator) !void {
    try util_fs.createDirIfAbsent(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(path);
    try json_util.writeToFile(manifest, path, allocator);
}

/// Reads and parses `<dir_path>/manifest.json`.
/// Returns null if the file does not exist.
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn readIfExists(dir_path: []const u8, allocator: std.mem.Allocator) !?std.json.Parsed(Manifest) {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir_path});
    defer allocator.free(path);
    if (!util_fs.fileExists(path)) return null;
    const parsed = try json_util.parseTypedFromFile(Manifest, path, allocator);
    return parsed;
}

/// Reads and parses `<dir_path>/manifest.json`.
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn read(dir_path: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(Manifest) {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir_path});
    defer allocator.free(path);
    return json_util.parseTypedFromFile(Manifest, path, allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "manifest: write then read round-trip" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const entry_points = [_][]const u8{"com.example.OrderController"};
    const run_args = [_][]const u8{"--port=8080"};
    const config_files = [_][]const u8{"application.yml"};

    const m = Manifest{
        .scenario_name = "submit-order",
        .entry_points = &entry_points,
        .run_args = &run_args,
        .config_files = &config_files,
        .output_dir = tmp_path,
    };

    try write(m, tmp_path, std.testing.allocator);

    var parsed = try read(tmp_path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("submit-order", parsed.value.scenario_name);
    try std.testing.expectEqualStrings(tmp_path, parsed.value.output_dir);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entry_points.len);
    try std.testing.expectEqualStrings("com.example.OrderController", parsed.value.entry_points[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.run_args.len);
    try std.testing.expectEqualStrings("--port=8080", parsed.value.run_args[0]);
}

test "manifest: JSON has expected keys" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const m = Manifest{
        .scenario_name = "test",
        .entry_points = &.{},
        .run_args = &.{},
        .config_files = &.{},
        .output_dir = tmp_path,
    };

    try write(m, tmp_path, std.testing.allocator);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);

    const content = try util_fs.readFileAlloc(json_path, std.testing.allocator);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "scenario_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "entry_points") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "run_args") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "config_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "output_dir") != null);
}

test "manifest: write creates output_dir if absent" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const new_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/new-output-dir", .{tmp_path});
    defer std.testing.allocator.free(new_dir);

    const m = Manifest{
        .scenario_name = "test",
        .entry_points = &.{},
        .run_args = &.{},
        .config_files = &.{},
        .output_dir = new_dir,
    };

    // Directory does not exist yet — write() should create it
    try write(m, new_dir, std.testing.allocator);
    try std.testing.expect(util_fs.fileExists(new_dir));
}
