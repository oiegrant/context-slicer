const std = @import("std");
const types = @import("../ir/types.zig");
const compressor = @import("../compression/compressor.zig");
const util_fs = @import("../util/fs.zig");

/// Writes `architecture.md` to `output_dir`.
///
/// Format:
/// ```
/// # Architecture: <scenario_name>
///
/// ## Call Path
///
/// 1. `ClassName.methodName()` — `src/path/to/File.java`
/// 2. ...
///
/// ## Framework Annotations
/// ...
/// ```
pub fn write(
    slice: compressor.Slice,
    scenario_name: []const u8,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("# Architecture: {s}\n\n", .{scenario_name});
    try writer.writeAll("## Call Path\n\n");

    for (slice.ordered_symbols, 1..) |sym, i| {
        // Display name: last two components of ID (ClassName::method)
        const display = displayName(sym.id);
        // Find file path (it's in relevant_file_paths only if the symbol has a file)
        // We derive file info from the symbol's annotations and kind
        const kind_str: []const u8 = switch (sym.kind) {
            .class => "class",
            .interface => "interface",
            .method => "method",
            .constructor => "constructor",
        };
        _ = kind_str;
        try writer.print("{d}. `{s}`\n", .{ i, display });
    }

    if (slice.relevant_file_paths.len > 0) {
        try writer.writeAll("\n## Source Files\n\n");
        for (slice.relevant_file_paths) |path| {
            try writer.print("- `{s}`\n", .{path});
        }
    }

    const out_path = try std.fmt.allocPrint(allocator, "{s}/architecture.md", .{output_dir});
    defer allocator.free(out_path);

    try util_fs.createDirIfAbsent(output_dir);
    try util_fs.writeFile(out_path, buf.items);
}

/// Extract a human-readable display name from a symbol ID like
/// `java::com.example.Foo::bar(Baz)` → `Foo::bar(Baz)`
fn displayName(id: []const u8) []const u8 {
    // Skip the language prefix (e.g. "java::")
    var rest = id;
    if (std.mem.indexOf(u8, rest, "::")) |idx| {
        rest = rest[idx + 2 ..];
    }
    // Now rest is "com.example.Foo::bar(Baz)" or "com.example.Foo"
    // Find the LAST occurrence of "::" to get "bar(Baz)"
    // Or find the last "." to get "Foo"
    if (std.mem.lastIndexOf(u8, rest, "::")) |_| {
        // e.g. "com.example.Foo::bar(Baz)" — return full path after lang prefix
        return rest;
    }
    // No method — just the class: "com.example.Foo" → "Foo"
    if (std.mem.lastIndexOf(u8, rest, ".")) |dot_idx| {
        return rest[dot_idx + 1 ..];
    }
    return rest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeSymbol(id: []const u8, kind: types.SymbolKind) types.Symbol {
    return types.Symbol{
        .id = id, .kind = kind, .name = id, .language = "java",
        .file_id = null, .line_start = 1, .line_end = 1,
        .visibility = "public", .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = false, .is_generated = false,
    };
}

test "write produces architecture.md" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const syms = [_]types.Symbol{
        makeSymbol("java::com.example.OrderController::createOrder(OrderRequest)", .method),
        makeSymbol("java::com.example.StripeOrderService::createOrder(OrderRequest)", .method),
    };
    const slice = compressor.Slice{
        .ordered_symbols = @constCast(&syms),
        .relevant_file_paths = @constCast(&[_][]const u8{ "src/OrderController.java", "src/StripeOrderService.java" }),
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, "submit-order", tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/architecture.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);

    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, "# Architecture:"));
}

test "architecture.md starts with # Architecture: header" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const syms = [_]types.Symbol{makeSymbol("java::com.example.Foo::bar()", .method)};
    const slice = compressor.Slice{
        .ordered_symbols = @constCast(&syms),
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, "my-scenario", tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/architecture.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, "# Architecture: my-scenario"));
}

test "StripeOrderService.createOrder appears in architecture.md" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const stripe_id = "java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)";
    const syms = [_]types.Symbol{makeSymbol(stripe_id, .method)};
    const slice = compressor.Slice{
        .ordered_symbols = @constCast(&syms),
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, "submit-order", tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/architecture.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "StripeOrderService") != null);
}
