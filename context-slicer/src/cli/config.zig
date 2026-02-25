const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const TransformConfig = struct {
    depth_limit: u32 = 2,
    max_collection_elements: u32 = 3,
};

pub const Config = struct {
    transforms: TransformConfig = .{},

    pub fn defaults() Config {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Internal JSON representation
// ---------------------------------------------------------------------------

/// Mirrors the context-slice.json schema with fully-optional fields.
/// std.json ignores unknown keys when ignore_unknown_fields = true.
const JsonConfig = struct {
    transforms: ?JsonTransformConfig = null,

    const JsonTransformConfig = struct {
        depth_limit: ?u32 = null,
        max_collection_elements: ?u32 = null,
    };
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Reads `context-slice.json` from `cwd_path`.
/// Returns `Config.defaults()` if the file is absent — no error.
/// Unknown top-level keys and unknown nested keys are silently ignored.
pub fn loadConfig(cwd_path: []const u8, allocator: std.mem.Allocator) !Config {
    const path = try std.fmt.allocPrint(allocator, "{s}/context-slice.json", .{cwd_path});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config.defaults(),
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(JsonConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var config = Config.defaults();
    if (parsed.value.transforms) |t| {
        if (t.depth_limit) |d| config.transforms.depth_limit = d;
        if (t.max_collection_elements) |m| config.transforms.max_collection_elements = m;
    }
    return config;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "loadConfig: file absent returns defaults" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const config = try loadConfig(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), config.transforms.depth_limit);
    try std.testing.expectEqual(@as(u32, 3), config.transforms.max_collection_elements);
}

test "loadConfig: depth_limit override" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Write context-slice.json
    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/context-slice.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);
    const f = try std.fs.createFileAbsolute(json_path, .{});
    defer f.close();
    try f.writeAll(
        \\{"transforms":{"depth_limit":3}}
    );

    const config = try loadConfig(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), config.transforms.depth_limit);
    try std.testing.expectEqual(@as(u32, 3), config.transforms.max_collection_elements); // default
}

test "loadConfig: max_collection_elements override" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/context-slice.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);
    const f = try std.fs.createFileAbsolute(json_path, .{});
    defer f.close();
    try f.writeAll(
        \\{"transforms":{"depth_limit":2,"max_collection_elements":5}}
    );

    const config = try loadConfig(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), config.transforms.depth_limit);
    try std.testing.expectEqual(@as(u32, 5), config.transforms.max_collection_elements);
}

test "loadConfig: unknown top-level key ignored" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/context-slice.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);
    const f = try std.fs.createFileAbsolute(json_path, .{});
    defer f.close();
    try f.writeAll(
        \\{"unknown_key":"ignored","transforms":{"depth_limit":4}}
    );

    const config = try loadConfig(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), config.transforms.depth_limit);
}
