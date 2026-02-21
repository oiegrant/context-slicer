const std = @import("std");
const detector = @import("detector.zig");
const manifest_mod = @import("manifest.zig");
const subprocess = @import("subprocess.zig");
const util_fs = @import("../util/fs.zig");
const RecordArgs = @import("../cli/commands/record.zig").RecordArgs;

/// Returned on successful orchestration.
pub const OrchestrationResult = struct {
    /// Caller owns this string and must free it with allocator.free().
    output_dir: []const u8,

    pub fn deinit(self: OrchestrationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
    }
};

/// Runs the full record pipeline:
///   detect language → write manifest → spawn adapter → wait for exit.
///
/// Returns `error.UnsupportedLanguage` if language detection fails.
/// Returns `error.AdapterNotFound` if adapter_jar_path does not exist.
/// Returns `error.AdapterFailed` if the adapter subprocess exits non-zero.
pub fn run(
    args: RecordArgs,
    project_root: []const u8,
    adapter_jar_path: []const u8,
    agent_jar_path: []const u8,
    allocator: std.mem.Allocator,
) !OrchestrationResult {
    // --- Language detection ---
    const lang = try detector.detect(project_root, allocator);
    if (lang == .unknown) return error.UnsupportedLanguage;

    // --- Validate adapter JAR existence ---
    if (!util_fs.fileExists(adapter_jar_path)) return error.AdapterNotFound;

    // --- Create output directory ---
    const output_dir = try std.fmt.allocPrint(allocator, "{s}/.context-slice", .{project_root});
    errdefer allocator.free(output_dir);
    try util_fs.createDirIfAbsent(output_dir);

    // --- Write manifest ---
    const config_files: []const []const u8 = if (args.config_file) |cf|
        &[_][]const u8{cf}
    else
        &.{};

    const m = manifest_mod.Manifest{
        .scenario_name = args.scenario_name,
        .entry_points = &.{},
        .run_args = args.run_args,
        .config_files = config_files,
        .output_dir = output_dir,
    };
    try manifest_mod.write(m, output_dir, allocator);

    // --- Build manifest path for adapter invocation ---
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{output_dir});
    defer allocator.free(manifest_path);

    // --- Spawn adapter subprocess ---
    const argv = try buildAdapterCommand(
        adapter_jar_path,
        agent_jar_path,
        manifest_path,
        output_dir,
        allocator,
    );
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    var sub = try subprocess.Subprocess.spawn(argv, allocator);
    const exit_result = try sub.wait();
    defer exit_result.deinit(allocator);

    if (exit_result.exit_code != 0) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Adapter failed with exit code ") catch {};
        var code_buf: [12]u8 = undefined;
        const code_str = std.fmt.bufPrint(&code_buf, "{d}\n", .{exit_result.exit_code}) catch "?\n";
        stderr.writeAll(code_str) catch {};
        stderr.writeAll(exit_result.stderr_output) catch {};
        return error.AdapterFailed;
    }

    return OrchestrationResult{ .output_dir = output_dir };
}

fn buildAdapterCommand(
    adapter_jar: []const u8,
    agent_jar: []const u8,
    manifest_path: []const u8,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    var argv = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupe(u8, "java"));
    try argv.append(allocator, try allocator.dupe(u8, "-jar"));
    try argv.append(allocator, try allocator.dupe(u8, adapter_jar));
    try argv.append(allocator, try allocator.dupe(u8, "record"));
    try argv.append(allocator, try allocator.dupe(u8, "--manifest"));
    try argv.append(allocator, try allocator.dupe(u8, manifest_path));
    try argv.append(allocator, try allocator.dupe(u8, "--output"));
    try argv.append(allocator, try allocator.dupe(u8, output_dir));
    try argv.append(allocator, try allocator.dupe(u8, "--agent"));
    try argv.append(allocator, try allocator.dupe(u8, agent_jar));

    return argv.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "orchestrator: unknown language returns error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // No build files → language = .unknown
    const args = RecordArgs{
        .scenario_name = "test",
        .config_file = null,
        .run_args = &.{},
    };

    const result = run(args, tmp_path, "/fake/adapter.jar", "/fake/agent.jar", std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLanguage, result);
}

test "orchestrator: adapter JAR not found returns error" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create pom.xml so language detection succeeds
    const pom = try std.fmt.allocPrint(std.testing.allocator, "{s}/pom.xml", .{tmp_path});
    defer std.testing.allocator.free(pom);
    try util_fs.writeFile(pom, "<project/>");

    const args = RecordArgs{
        .scenario_name = "test",
        .config_file = null,
        .run_args = &.{},
    };

    const result = run(args, tmp_path, "/nonexistent/adapter.jar", "/nonexistent/agent.jar", std.testing.allocator);
    try std.testing.expectError(error.AdapterNotFound, result);
}

test "orchestrator: manifest written before subprocess spawned" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create pom.xml so language detection succeeds
    const pom = try std.fmt.allocPrint(std.testing.allocator, "{s}/pom.xml", .{tmp_path});
    defer std.testing.allocator.free(pom);
    try util_fs.writeFile(pom, "<project/>");

    // Create a fake adapter JAR that just exits successfully
    // We use "true" (a shell built-in) but need a real file path.
    // Use /bin/sh as the "adapter JAR" — but that won't work as "java -jar".
    // Instead, check that manifest.json is written even though subprocess fails.
    const fake_jar = try std.fmt.allocPrint(std.testing.allocator, "{s}/fake.jar", .{tmp_path});
    defer std.testing.allocator.free(fake_jar);
    try util_fs.writeFile(fake_jar, "");  // empty file exists

    const args = RecordArgs{
        .scenario_name = "submit-order",
        .config_file = null,
        .run_args = &.{},
    };

    // The adapter will fail (can't run an empty file as a JAR), but manifest should be written first.
    const result = run(args, tmp_path, fake_jar, fake_jar, std.testing.allocator);

    // Verify manifest was written (before the subprocess ran)
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.context-slice/manifest.json", .{tmp_path});
    defer std.testing.allocator.free(manifest_path);
    try std.testing.expect(util_fs.fileExists(manifest_path));

    // The run itself fails because java can't execute an empty JAR
    _ = result catch {}; // expected to fail — we just care manifest was written
}

test "orchestrator: buildAdapterCommand produces expected argv" {
    const argv = try buildAdapterCommand(
        "/path/to/adapter.jar",
        "/path/to/agent.jar",
        "/tmp/cs/manifest.json",
        "/tmp/cs",
        std.testing.allocator,
    );
    defer {
        for (argv) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(argv);
    }

    try std.testing.expectEqual(@as(usize, 10), argv.len);
    try std.testing.expectEqualStrings("java", argv[0]);
    try std.testing.expectEqualStrings("-jar", argv[1]);
    try std.testing.expectEqualStrings("/path/to/adapter.jar", argv[2]);
    try std.testing.expectEqualStrings("record", argv[3]);
    try std.testing.expectEqualStrings("--manifest", argv[4]);
    try std.testing.expectEqualStrings("/tmp/cs/manifest.json", argv[5]);
}
