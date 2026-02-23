const std = @import("std");
const util_fs = @import("../../util/fs.zig");
const log = @import("../../util/log.zig");
const loader = @import("../../ir/loader.zig");
const validator = @import("../../ir/validator.zig");
const merger = @import("../../ir/merger.zig");
const ir_types = @import("../../ir/types.zig");
const graph_builder = @import("../../graph/builder.zig");
const traversal = @import("../../graph/traversal.zig");
const expansion = @import("../../graph/expansion.zig");
const compressor = @import("../../compression/compressor.zig");
const packager = @import("../../packager/packager.zig");

pub fn printSliceUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\Usage: context-slicer slice
        \\
        \\Re-run the Zig pipeline on existing recorded data in `.context-slice/`.
        \\The adapter is NOT re-invoked — this only re-runs graph building,
        \\compression, and packaging on the already-captured IR.
        \\
        \\Options:
        \\  --help      Show this help message
        \\  --verbose   Enable debug logging to stderr
        \\
    ) catch {};
}

/// Run the Zig slice pipeline on existing `.context-slice/` data.
/// Returns `error.NoRecordedScenario` if `.context-slice/` does not exist
/// or if `static_ir.json` is missing.
/// Returns `error.HelpRequested` if `--help` or `-h` is in args.
pub fn run(project_root: []const u8, allocator: std.mem.Allocator) !void {
    const cs_dir = try std.fmt.allocPrint(allocator, "{s}/.context-slice", .{project_root});
    defer allocator.free(cs_dir);

    const ir_path = try std.fmt.allocPrint(allocator, "{s}/static_ir.json", .{cs_dir});
    defer allocator.free(ir_path);

    if (!util_fs.fileExists(cs_dir) or !util_fs.fileExists(ir_path)) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("No recorded scenario found. Run `record` first.\n") catch {};
        return error.NoRecordedScenario;
    }

    // --- Load and validate static IR ---
    log.debug("loading static IR from {s}", .{ir_path});
    var static_ir = try loader.loadStatic(ir_path, allocator);
    defer static_ir.deinit();

    var validated = try validator.validate(static_ir.value, allocator);
    defer validated.deinit();
    log.debug("validated: {d} symbols, {d} call edges", .{ validated.symbols.len, validated.call_edges.len });

    // --- Load runtime trace (optional) ---
    // The adapter writes runtime_trace.json into a runtime/ subdirectory.
    // Also check the top-level cs_dir for hand-crafted fixtures or older layouts.
    const runtime_path_sub = try std.fmt.allocPrint(allocator, "{s}/runtime/runtime_trace.json", .{cs_dir});
    defer allocator.free(runtime_path_sub);
    const runtime_path_top = try std.fmt.allocPrint(allocator, "{s}/runtime_trace.json", .{cs_dir});
    defer allocator.free(runtime_path_top);
    const runtime_path = if (util_fs.fileExists(runtime_path_sub)) runtime_path_sub else runtime_path_top;

    var merged_ir: merger.MergedIr = undefined;
    var runtime_parsed: ?std.json.Parsed(ir_types.RuntimeTrace) = null;
    defer if (runtime_parsed) |rp| rp.deinit();

    if (util_fs.fileExists(runtime_path)) {
        log.debug("loading runtime trace from {s}", .{runtime_path});
        const rt = try loader.loadRuntime(runtime_path, allocator);
        runtime_parsed = rt;
        merged_ir = try merger.merge(validated, rt.value, allocator);
    } else {
        log.debug("no runtime trace found; using empty trace", .{});
        const empty_rt = ir_types.RuntimeTrace{
            .observed_symbols = &.{},
            .observed_edges = &.{},
        };
        merged_ir = try merger.merge(validated, empty_rt, allocator);
    }
    defer merged_ir.deinit();
    log.debug("merged IR: {d} symbols", .{merged_ir.symbols.len});

    // --- Build graph ---
    var g = try graph_builder.build(merged_ir, allocator);
    defer g.deinit();
    log.debug("graph: {d} nodes, {d} edges", .{ g.nodeCount(), g.edgeCount() });

    // --- Traversal: hot path ---
    const hot = try traversal.hotPath(&g, allocator);
    defer allocator.free(hot);
    log.debug("hot path: {d} symbols", .{hot.len});

    // --- Expansion ---
    var expanded = try expansion.expand(&g, hot, &g.file_map, allocator);
    defer expanded.deinit();
    log.debug("expanded: {d} symbols", .{expanded.symbols.len});

    // --- Compress ---
    var slice = try compressor.compress(expanded, merged_ir, allocator);
    defer slice.deinit();
    log.debug("slice: {d} symbols, {d} files", .{ slice.ordered_symbols.len, slice.relevant_file_paths.len });

    // --- Pack ---
    const ts_unix = std.time.timestamp();
    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{ts_unix}) catch "0";

    const meta = packager.ScenarioMeta{
        .scenario_name = validated.scenario.name,
        .adapter_version = validated.adapter_version,
        .language = validated.language,
        .timestamp_utc = ts_str,
        .timestamp_unix = ts_unix,
        .runtime_captured = runtime_parsed != null,
    };
    try packager.pack(slice, meta, cs_dir, allocator);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("Slice written to .context-slice/\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "slice: directory without .context-slice returns error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const result = run(tmp_path, std.testing.allocator);
    try std.testing.expectError(error.NoRecordedScenario, result);
}

test "slice: directory with .context-slice/static_ir.json succeeds" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Load the real fixture to run the pipeline
    const fixture_ir = "../test-fixtures/ir/static_ir.json";
    const fixture_rt = "../test-fixtures/ir/runtime_trace.json";
    if (!util_fs.fileExists(fixture_ir)) return; // skip if fixture not present

    // Create .context-slice/
    const cs_dir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice", .{tmp_path});
    defer std.testing.allocator.free(cs_dir_path);
    try util_fs.createDirIfAbsent(cs_dir_path);

    // Copy fixture files into the temp dir
    const ir_content = try util_fs.readFileAlloc(fixture_ir, std.testing.allocator);
    defer std.testing.allocator.free(ir_content);
    const ir_dest = try std.fmt.allocPrint(std.testing.allocator, "{s}/static_ir.json", .{cs_dir_path});
    defer std.testing.allocator.free(ir_dest);
    try util_fs.writeFile(ir_dest, ir_content);

    if (util_fs.fileExists(fixture_rt)) {
        const rt_content = try util_fs.readFileAlloc(fixture_rt, std.testing.allocator);
        defer std.testing.allocator.free(rt_content);
        const rt_dest = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtime_trace.json", .{cs_dir_path});
        defer std.testing.allocator.free(rt_dest);
        try util_fs.writeFile(rt_dest, rt_content);
    }

    try run(tmp_path, std.testing.allocator);

    // Verify output files exist
    const arch_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/architecture.md", .{cs_dir_path});
    defer std.testing.allocator.free(arch_path);
    try std.testing.expect(util_fs.fileExists(arch_path));
}
