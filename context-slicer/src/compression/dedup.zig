const std = @import("std");
const filter = @import("filter.zig");

pub const FilteredEdge = filter.FilteredEdge;

/// Merge multiple edges between the same caller→callee pair into one:
/// - Sums call_count
/// - OR-s runtime_observed
/// - is_static: true if any edge was static
///
/// Caller owns the returned slice (free with allocator.free).
pub fn deduplicateEdges(
    edges: []const FilteredEdge,
    allocator: std.mem.Allocator,
) ![]FilteredEdge {
    // Key: "caller\x00callee" → index in result list
    var key_arena = std.heap.ArenaAllocator.init(allocator);
    defer key_arena.deinit();
    const ka = key_arena.allocator();

    var edge_map = std.StringHashMap(usize).init(allocator);
    defer edge_map.deinit();

    var result: std.ArrayListUnmanaged(FilteredEdge) = .{};
    errdefer result.deinit(allocator);

    for (edges) |e| {
        const key = try std.fmt.allocPrint(ka, "{s}\x00{s}", .{ e.caller, e.callee });
        if (edge_map.get(key)) |idx| {
            // Merge into existing entry
            result.items[idx].call_count += e.call_count;
            result.items[idx].runtime_observed = result.items[idx].runtime_observed or e.runtime_observed;
            result.items[idx].is_static = result.items[idx].is_static or e.is_static;
        } else {
            const idx = result.items.len;
            try result.append(allocator, e);
            try edge_map.put(key, idx);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Detect trivial A→B→A cycles and remove the back-edge (B→A).
/// "Trivial" means a 2-node cycle; longer cycles are untouched in this MVP.
/// Returns a new edge list. Caller owns it (free with allocator.free).
pub fn collapseRecursion(
    edges: []const FilteredEdge,
    allocator: std.mem.Allocator,
) ![]FilteredEdge {
    // Build set of existing edges for fast lookup
    var edge_set = std.StringHashMap(void).init(allocator);
    defer edge_set.deinit();

    var key_arena = std.heap.ArenaAllocator.init(allocator);
    defer key_arena.deinit();
    const ka = key_arena.allocator();

    for (edges) |e| {
        const key = try std.fmt.allocPrint(ka, "{s}\x00{s}", .{ e.caller, e.callee });
        try edge_set.put(key, {});
    }

    // Collect edges that are NOT back-edges of a 2-cycle
    var result: std.ArrayListUnmanaged(FilteredEdge) = .{};
    errdefer result.deinit(allocator);

    for (edges) |e| {
        // Check if there's a reverse edge
        const reverse_key = try std.fmt.allocPrint(ka, "{s}\x00{s}", .{ e.callee, e.caller });
        if (edge_set.contains(reverse_key)) {
            // This forms a 2-cycle A↔B; keep the forward edge (lower lex order)
            if (std.mem.lessThan(u8, e.callee, e.caller)) {
                // This edge is the "back" edge — skip it
                continue;
            }
        }
        try result.append(allocator, e);
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "two edges A→B with counts 3 and 2 merge to count 5" {
    const edges = [_]FilteredEdge{
        .{ .caller = "A", .callee = "B", .call_count = 3, .runtime_observed = true, .is_static = true },
        .{ .caller = "A", .callee = "B", .call_count = 2, .runtime_observed = false, .is_static = false },
    };

    const result = try deduplicateEdges(&edges, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u32, 5), result[0].call_count);
    try std.testing.expect(result[0].runtime_observed);
}

test "A→B (runtimeObserved=false) + A→B (runtimeObserved=true) merged with runtimeObserved=true" {
    const edges = [_]FilteredEdge{
        .{ .caller = "A", .callee = "B", .call_count = 0, .runtime_observed = false, .is_static = true },
        .{ .caller = "A", .callee = "B", .call_count = 1, .runtime_observed = true, .is_static = false },
    };

    const result = try deduplicateEdges(&edges, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].runtime_observed);
    try std.testing.expectEqual(@as(u32, 1), result[0].call_count);
}

test "graph with A→B→A cycle: collapseRecursion removes back-edge" {
    const edges = [_]FilteredEdge{
        .{ .caller = "A", .callee = "B", .call_count = 1, .runtime_observed = true, .is_static = true },
        .{ .caller = "B", .callee = "A", .call_count = 1, .runtime_observed = true, .is_static = true },
    };

    const result = try collapseRecursion(&edges, std.testing.allocator);
    defer std.testing.allocator.free(result);

    // One of the two back-edges should be removed
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "no duplicates or cycles: output identical to input" {
    const edges = [_]FilteredEdge{
        .{ .caller = "A", .callee = "B", .call_count = 1, .runtime_observed = true, .is_static = true },
        .{ .caller = "B", .callee = "C", .call_count = 2, .runtime_observed = true, .is_static = true },
    };

    const deduped = try deduplicateEdges(&edges, std.testing.allocator);
    defer std.testing.allocator.free(deduped);
    try std.testing.expectEqual(@as(usize, 2), deduped.len);

    const collapsed = try collapseRecursion(&edges, std.testing.allocator);
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqual(@as(usize, 2), collapsed.len);
}
