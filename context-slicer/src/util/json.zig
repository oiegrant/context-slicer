const std = @import("std");
const fs = @import("fs.zig");

/// Reads a JSON file and parses it into a std.json.Value (dynamic tree).
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn parseFileAlloc(path: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const data = fs.readFileAlloc(path, allocator) catch |err| {
        return err;
    };
    defer allocator.free(data);
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        return err;
    };
}

/// Parses a JSON string into a typed struct T.
/// Caller owns the returned Parsed value and must call parsed.deinit().
/// Uses alloc_always to ensure string slices are copied into the arena
/// (safe to free the source buffer after this returns).
pub fn parseTypedFromSlice(comptime T: type, data: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Reads a JSON file and parses it into a typed struct T.
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn parseTypedFromFile(comptime T: type, path: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(T) {
    const data = try fs.readFileAlloc(path, allocator);
    defer allocator.free(data);
    return parseTypedFromSlice(T, data, allocator);
}

/// Serializes a value to JSON and writes it to a file.
pub fn writeToFile(value: anytype, path: []const u8, allocator: std.mem.Allocator) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try fs.writeFile(path, bytes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseFileAlloc parses known JSON file" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);

    try fs.writeFile(json_path, "{\"key\": \"value\", \"num\": 42}");

    var parsed = try parseFileAlloc(json_path, std.testing.allocator);
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);
}

test "parseFileAlloc on malformed JSON returns error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);

    try fs.writeFile(json_path, "{invalid json!!!");

    const result = parseFileAlloc(json_path, std.testing.allocator);
    try std.testing.expectError(error.SyntaxError, result);
}

test "writeToFile then parseTypedFromFile round-trip" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rt.json", .{tmp_path});
    defer std.testing.allocator.free(json_path);

    const MyStruct = struct { label: []const u8, count: u32 };
    const original = MyStruct{ .label = "hello", .count = 99 };

    try writeToFile(original, json_path, std.testing.allocator);

    var parsed = try parseTypedFromFile(MyStruct, json_path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(original.label, parsed.value.label);
    try std.testing.expectEqual(original.count, parsed.value.count);
}

test "parseTypedFromSlice ignores unknown fields" {
    const MyStruct = struct { known: u32 };
    const json_str = "{\"known\": 5, \"unknown_extra\": \"ignored\"}";

    var parsed = try parseTypedFromSlice(MyStruct, json_str, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 5), parsed.value.known);
}
