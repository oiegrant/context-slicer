const std = @import("std");
const compressor = @import("../compression/compressor.zig");
const util_fs = @import("../util/fs.zig");

/// Writes `config_usage.md` to `output_dir`.
///
/// Format (Markdown table):
/// ```
/// # Config Usage
///
/// | Config Key | Resolved Value | Influenced By |
/// |---|---|---|
/// | order.payment.provider | stripe | StripePaymentService::charge(...) |
/// ```
pub fn write(
    slice: compressor.Slice,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("# Config Usage\n\n");
    try writer.writeAll("| Config Key | Resolved Value | Influenced By |\n");
    try writer.writeAll("|---|---|---|\n");

    for (slice.config_influences) |ci| {
        const value = ci.resolved_value orelse "(unknown)";
        // Influenced-by: comma-separated short names
        var influenced_buf: std.ArrayListUnmanaged(u8) = .{};
        defer influenced_buf.deinit(allocator);
        const iw = influenced_buf.writer(allocator);
        for (ci.influenced_by, 0..) |sym_id, i| {
            if (i > 0) try iw.writeAll(", ");
            try iw.writeAll(shortName(sym_id));
        }
        try writer.print("| {s} | {s} | {s} |\n", .{
            ci.config_key,
            value,
            influenced_buf.items,
        });
    }

    const out_path = try std.fmt.allocPrint(allocator, "{s}/config_usage.md", .{output_dir});
    defer allocator.free(out_path);

    try util_fs.createDirIfAbsent(output_dir);
    try util_fs.writeFile(out_path, buf.items);
}

/// Return the short display name from a symbol ID.
fn shortName(id: []const u8) []const u8 {
    var rest = id;
    if (std.mem.indexOf(u8, rest, "::")) |idx| {
        rest = rest[idx + 2 ..];
    }
    if (std.mem.lastIndexOf(u8, rest, "::")) |idx| {
        const class_part = rest[0..idx];
        const method_part = rest[idx + 2 ..];
        const simple_class = if (std.mem.lastIndexOf(u8, class_part, ".")) |dot|
            class_part[dot + 1 ..]
        else
            class_part;
        _ = method_part;
        return simple_class;
    }
    if (std.mem.lastIndexOf(u8, rest, ".")) |dot| {
        return rest[dot + 1 ..];
    }
    return rest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeConfigInfluence(key: []const u8, value: ?[]const u8, sym: []const u8) compressor.ConfigInfluence {
    return compressor.ConfigInfluence{
        .config_key = key,
        .resolved_value = value,
        .influenced_by = @constCast(&[_][]const u8{sym}),
    };
}

test "write produces config_usage.md" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const ci = makeConfigInfluence("order.payment.provider", "stripe",
        "java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)");
    const slice = compressor.Slice{
        .ordered_symbols = &[_]@import("../ir/types.zig").Symbol{},
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = @constCast(&[_]compressor.ConfigInfluence{ci}),
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config_usage.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(content.len > 0);
}

test "config_usage.md contains markdown table headers" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const slice = compressor.Slice{
        .ordered_symbols = &[_]@import("../ir/types.zig").Symbol{},
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config_usage.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "| Config Key |") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "| Resolved Value |") != null);
}

test "config_usage.md contains row for order.payment.provider" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const ci = makeConfigInfluence("order.payment.provider", "stripe",
        "java::com.contextslice.fixture.StripePaymentService::charge(PaymentRequest)");
    const slice = compressor.Slice{
        .ordered_symbols = &[_]@import("../ir/types.zig").Symbol{},
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = @constCast(&[_]compressor.ConfigInfluence{ci}),
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    try write(slice, tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config_usage.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "order.payment.provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "stripe") != null);
}

test "empty config_influences writes header + empty table body" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const slice = compressor.Slice{
        .ordered_symbols = &[_]@import("../ir/types.zig").Symbol{},
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]@import("../compression/filter.zig").FilteredEdge{},
        ._alloc = std.testing.allocator,
    };

    // Should not error even with empty config
    try write(slice, tmp_path, std.testing.allocator);

    const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config_usage.md", .{tmp_path});
    defer std.testing.allocator.free(out_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "# Config Usage") != null);
}
