const std = @import("std");
const compressor = @import("../compression/compressor.zig");
const arch_writer = @import("architecture_writer.zig");
const cfg_writer = @import("config_writer.zig");
const util_fs = @import("../util/fs.zig");
const util_json = @import("../util/json.zig");

/// Metadata about the scenario being packed.
pub const ScenarioMeta = struct {
    scenario_name: []const u8,
    adapter_version: []const u8,
    language: []const u8,
    timestamp_utc: []const u8, // ISO-8601 string
};

/// Pack a Slice into the output directory, producing 5 output files.
///
/// Files written:
///   - architecture.md
///   - config_usage.md
///   - relevant_files.txt  (one path per line, sorted, deduplicated)
///   - call_graph.json     (JSON array of edges)
///   - metadata.json       (scenario metadata)
pub fn pack(
    slice: compressor.Slice,
    meta: ScenarioMeta,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try util_fs.createDirIfAbsent(output_dir);

    // 1. architecture.md
    try arch_writer.write(slice, meta.scenario_name, output_dir, allocator);

    // 2. config_usage.md
    try cfg_writer.write(slice, output_dir, allocator);

    // 3. relevant_files.txt — sorted, deduplicated
    try writeRelevantFiles(slice, output_dir, allocator);

    // 4. call_graph.json
    try writeCallGraph(slice, output_dir, allocator);

    // 5. metadata.json
    try writeMetadata(meta, output_dir, allocator);
}

fn writeRelevantFiles(
    slice: compressor.Slice,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Deduplicate + sort
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(allocator);

    for (slice.relevant_file_paths) |p| {
        if (!seen.contains(p)) {
            try seen.put(p, {});
            try paths.append(allocator, p);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    for (paths.items) |p| {
        try writer.print("{s}\n", .{p});
    }

    const out_path = try std.fmt.allocPrint(allocator, "{s}/relevant_files.txt", .{output_dir});
    defer allocator.free(out_path);
    try util_fs.writeFile(out_path, buf.items);
}

/// A minimal JSON edge serialization without pulling in Zig's JSON library overhead.
fn writeCallGraph(
    slice: compressor.Slice,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\n  \"edges\": [\n");
    for (slice.call_graph_edges, 0..) |e, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.print(
            "    {{\"caller\":\"{s}\",\"callee\":\"{s}\",\"call_count\":{d},\"runtime_observed\":{s},\"is_static\":{s}}}",
            .{
                e.caller, e.callee, e.call_count,
                if (e.runtime_observed) "true" else "false",
                if (e.is_static) "true" else "false",
            },
        );
    }
    try writer.writeAll("\n  ]\n}\n");

    const out_path = try std.fmt.allocPrint(allocator, "{s}/call_graph.json", .{output_dir});
    defer allocator.free(out_path);
    try util_fs.writeFile(out_path, buf.items);
}

fn writeMetadata(
    meta: ScenarioMeta,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print(
        \\{{
        \\  "scenarioName": "{s}",
        \\  "adapterVersion": "{s}",
        \\  "language": "{s}",
        \\  "timestamp": "{s}",
        \\  "zigCoreVersion": "0.1.0"
        \\}}
        \\
    , .{ meta.scenario_name, meta.adapter_version, meta.language, meta.timestamp_utc });

    const out_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{output_dir});
    defer allocator.free(out_path);
    try util_fs.writeFile(out_path, buf.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const types = @import("../ir/types.zig");
const filter = @import("../compression/filter.zig");

fn emptySlice() compressor.Slice {
    return compressor.Slice{
        .ordered_symbols = &[_]types.Symbol{},
        .relevant_file_paths = &[_][]const u8{},
        .config_influences = &[_]compressor.ConfigInfluence{},
        .call_graph_edges = &[_]filter.FilteredEdge{},
        ._alloc = std.testing.allocator,
    };
}

const TEST_META = ScenarioMeta{
    .scenario_name = "submit-order",
    .adapter_version = "0.1.0",
    .language = "java",
    .timestamp_utc = "2026-02-20T00:00:00Z",
};

fn checkFileExists(dir: []const u8, name: []const u8, allocator: std.mem.Allocator) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);
    try std.testing.expect(util_fs.fileExists(path));
}

test "pack produces all 5 output files" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try pack(emptySlice(), TEST_META, tmp_path, std.testing.allocator);

    try checkFileExists(tmp_path, "architecture.md", std.testing.allocator);
    try checkFileExists(tmp_path, "config_usage.md", std.testing.allocator);
    try checkFileExists(tmp_path, "relevant_files.txt", std.testing.allocator);
    try checkFileExists(tmp_path, "call_graph.json", std.testing.allocator);
    try checkFileExists(tmp_path, "metadata.json", std.testing.allocator);
}

test "relevant_files.txt has no duplicate lines" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const paths = [_][]const u8{ "src/A.java", "src/B.java", "src/A.java" };
    var slice = emptySlice();
    slice.relevant_file_paths = @constCast(&paths);

    try pack(slice, TEST_META, tmp_path, std.testing.allocator);

    const rf_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/relevant_files.txt", .{tmp_path});
    defer std.testing.allocator.free(rf_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, rf_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    // Count occurrences of "src/A.java"
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (std.mem.eql(u8, line, "src/A.java")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "call_graph.json is valid JSON with edges array" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try pack(emptySlice(), TEST_META, tmp_path, std.testing.allocator);

    const cg_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/call_graph.json", .{tmp_path});
    defer std.testing.allocator.free(cg_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, cg_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"edges\"") != null);
}

test "metadata.json contains scenarioName, timestamp, language" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try pack(emptySlice(), TEST_META, tmp_path, std.testing.allocator);

    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metadata.json", .{tmp_path});
    defer std.testing.allocator.free(md_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, md_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"scenarioName\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"timestamp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"language\"") != null);
}

test "pack twice on same output dir overwrites without error (idempotent)" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try pack(emptySlice(), TEST_META, tmp_path, std.testing.allocator);
    try pack(emptySlice(), TEST_META, tmp_path, std.testing.allocator); // second call — must not error

    try checkFileExists(tmp_path, "metadata.json", std.testing.allocator);
}
