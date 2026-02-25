const std = @import("std");
const types = @import("types.zig");
const json_util = @import("../util/json.zig");

/// Loads and parses a static_ir.json file into an IrRoot.
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn loadStatic(path: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(types.IrRoot) {
    return json_util.parseTypedFromFile(types.IrRoot, path, allocator);
}

/// Loads and parses a runtime_trace.json file into a RuntimeTrace.
/// Caller owns the returned Parsed value and must call parsed.deinit().
pub fn loadRuntime(path: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(types.RuntimeTrace) {
    return json_util.parseTypedFromFile(types.RuntimeTrace, path, allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Helper: path from the Zig project root to the ir fixtures directory.
/// When `zig build test` runs, CWD is the project root (context-slicer/).
const FIXTURE_DIR = "../test-fixtures/ir";

test "loadStatic reads ir_version and language" {
    const path = FIXTURE_DIR ++ "/static_ir.json";
    var parsed = try loadStatic(path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("0.1", parsed.value.ir_version);
    try std.testing.expectEqualStrings("java", parsed.value.language);
}

test "loadStatic symbol count and first symbol fields" {
    const path = FIXTURE_DIR ++ "/static_ir.json";
    var parsed = try loadStatic(path, std.testing.allocator);
    defer parsed.deinit();

    // static_ir.json fixture has 17 symbols
    try std.testing.expectEqual(@as(usize, 17), parsed.value.symbols.len);

    const first = parsed.value.symbols[0];
    try std.testing.expect(first.id.len > 0);
    try std.testing.expect(first.file_id != null);
}

test "loadStatic call_edges non-empty" {
    const path = FIXTURE_DIR ++ "/static_ir.json";
    var parsed = try loadStatic(path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.call_edges.len > 0);
}

test "loadRuntime observed_symbols non-empty" {
    const path = FIXTURE_DIR ++ "/runtime_trace.json";
    var parsed = try loadRuntime(path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.observed_symbols.len > 0);
}

test "loadStatic file not found returns error" {
    const result = loadStatic("/nonexistent/path/static_ir.json", std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, result);
}

test "loadRuntime parses method_transforms from fixture" {
    const path = FIXTURE_DIR ++ "/runtime_trace_with_transforms.json";
    var parsed = try loadRuntime(path, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.method_transforms.len);

    // First transform: StripeOrderService.createOrder
    const mt0 = parsed.value.method_transforms[0];
    try std.testing.expect(std.mem.indexOf(u8, mt0.symbol_id, "StripeOrderService") != null);
    try std.testing.expectEqual(@as(usize, 1), mt0.parameters.len);
    try std.testing.expect(mt0.parameters[0].mutated);
    try std.testing.expectEqual(@as(usize, 2), mt0.parameters[0].changed_fields.len);
    try std.testing.expectEqualStrings("orderId", mt0.parameters[0].changed_fields[0].field);
    try std.testing.expectEqualStrings("null", mt0.parameters[0].changed_fields[0].before);
    try std.testing.expectEqualStrings("ord-abc123", mt0.parameters[0].changed_fields[0].after);
    try std.testing.expect(mt0.return_type != null);
    try std.testing.expect(mt0.return_value != null);
}

test "loadRuntime without method_transforms parses successfully (backwards compat)" {
    const path = FIXTURE_DIR ++ "/runtime_trace.json";
    var parsed = try loadRuntime(path, std.testing.allocator);
    defer parsed.deinit();

    // Old trace has no method_transforms — should default to empty slice
    try std.testing.expectEqual(@as(usize, 0), parsed.value.method_transforms.len);
}

test "loadStatic malformed JSON returns error (not panic)" {
    // Write a temp file with malformed JSON
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const bad_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.json", .{tmp_path});
    defer std.testing.allocator.free(bad_path);

    // Write invalid JSON
    const file = try std.fs.cwd().createFile(bad_path, .{});
    try file.writeAll("{invalid json!!!");
    file.close();

    const result = loadStatic(bad_path, std.testing.allocator);
    // Should return a JSON parse error, not panic
    try std.testing.expect(std.meta.isError(result));
}

