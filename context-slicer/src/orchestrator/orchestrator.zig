const std = @import("std");
const detector = @import("detector.zig");
const manifest_mod = @import("manifest.zig");
const subprocess = @import("subprocess.zig");
const util_fs = @import("../util/fs.zig");
const RecordArgs = @import("../cli/commands/record.zig").RecordArgs;

const embedded_jars = @import("embedded_jars");

/// Returned on successful orchestration.
pub const OrchestrationResult = struct {
    /// Caller owns this string and must free it with allocator.free().
    output_dir: []const u8,

    pub fn deinit(self: OrchestrationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
    }
};

fn extractEmbeddedJars(allocator: std.mem.Allocator) !struct { adapter: []const u8, agent: []const u8 } {
    const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";

    const adapter_path = try std.fs.path.join(allocator, &.{ tmp, "context-adapter-java-0.1.0.jar" });
    errdefer allocator.free(adapter_path);
    {
        const f = try std.fs.createFileAbsolute(adapter_path, .{});
        defer f.close();
        try f.writeAll(embedded_jars.adapter);
    }

    const agent_path = try std.fs.path.join(allocator, &.{ tmp, "context-agent-java-0.1.0.jar" });
    errdefer allocator.free(agent_path);
    {
        const f = try std.fs.createFileAbsolute(agent_path, .{});
        defer f.close();
        try f.writeAll(embedded_jars.agent);
    }

    return .{ .adapter = adapter_path, .agent = agent_path };
}

/// Runs the full record pipeline:
///   detect language → write manifest → spawn adapter → wait for exit.
///
/// Returns `error.UnsupportedLanguage` if language detection fails.
/// Returns `error.AdapterFailed` if the adapter subprocess exits non-zero.
pub fn run(
    args: RecordArgs,
    project_root: []const u8,
    allocator: std.mem.Allocator,
) !OrchestrationResult {
    const jars = try extractEmbeddedJars(allocator);
    defer {
        allocator.free(jars.adapter);
        allocator.free(jars.agent);
    }

    // --- Language detection ---
    const lang = try detector.detect(project_root, allocator);
    if (lang == .unknown) return error.UnsupportedLanguage;

    // --- Create output directory ---
    const output_dir = try std.fmt.allocPrint(allocator, "{s}/.context-slice", .{project_root});
    errdefer allocator.free(output_dir);
    try util_fs.createDirIfAbsent(output_dir);

    // --- Read existing project manifest if present (preserves run_script, server_port, etc.) ---
    var existing_parsed = try manifest_mod.readIfExists(project_root, allocator);
    defer if (existing_parsed) |*p| p.deinit();

    const existing = if (existing_parsed) |*p| &p.value else null;

    // CLI overrides: config_files and run_args only override if explicitly provided.
    const config_files: []const []const u8 = if (args.config_file) |cf|
        &[_][]const u8{cf}
    else if (existing) |e| e.config_files
    else
        &.{};

    const run_args: []const []const u8 = if (args.run_args.len > 0)
        args.run_args
    else if (existing) |e| e.run_args
    else
        &.{};

    const entry_points: []const []const u8 = if (existing) |e| e.entry_points else &.{};
    const namespace: ?[]const u8 = args.namespace orelse
        if (existing) |e| e.namespace else null;
    const server_port: ?i64 = args.server_port orelse
        if (existing) |e| e.server_port else null;
    const run_script: ?[]const u8 = args.run_script orelse
        if (existing) |e| e.run_script else null;

    // --- Write manifest to project root (adapter uses parent dir of manifest as project root) ---
    const m = manifest_mod.Manifest{
        .scenario_name = args.scenario_name,
        .entry_points = entry_points,
        .run_args = run_args,
        .config_files = config_files,
        .output_dir = output_dir,
        .namespace = namespace,
        .server_port = server_port,
        .run_script = run_script,
    };
    try manifest_mod.write(m, project_root, allocator);

    // --- Build manifest path for adapter invocation ---
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{project_root});
    defer allocator.free(manifest_path);

    // --- Spawn adapter subprocess ---
    const argv = try buildAdapterCommand(
        jars.adapter,
        jars.agent,
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

/// Returns the path to the `java` binary.
/// Prefers $JAVA_HOME/bin/java over the bare "java" on PATH (avoids macOS stub).
fn resolveJavaBinary(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "JAVA_HOME")) |java_home| {
        defer allocator.free(java_home);
        const bin = try std.fmt.allocPrint(allocator, "{s}/bin/java", .{java_home});
        // Confirm the resolved binary exists; fall through if not.
        std.fs.cwd().access(bin, .{}) catch {
            allocator.free(bin);
            return allocator.dupe(u8, "java");
        };
        return bin;
    } else |_| {}
    return allocator.dupe(u8, "java");
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

    try argv.append(allocator, try resolveJavaBinary(allocator));
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
        .run_script = null,
        .namespace = null,
        .server_port = null,
    };

    const result = run(args, tmp_path, std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLanguage, result);
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
