const std = @import("std");

/// Result of waiting for a subprocess to finish.
pub const ExitResult = struct {
    exit_code: u32,
    stderr_output: []const u8,

    /// Frees stderr_output.
    pub fn deinit(self: ExitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr_output);
    }
};

/// A spawned child process.
pub const Subprocess = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,

    /// Spawns a new process with the given argument vector.
    /// stderr is captured as a pipe; stdout is suppressed.
    /// Returns `error.SpawnFailed` if the binary cannot be launched.
    pub fn spawn(argv: []const []const u8, allocator: std.mem.Allocator) !Subprocess {
        var child = std.process.Child.init(argv, allocator);
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.spawn() catch {
            return error.SpawnFailed;
        };
        return Subprocess{ .child = child, .allocator = allocator };
    }

    /// Waits for the process to exit and collects its stderr output.
    /// Caller owns ExitResult and must call result.deinit(allocator).
    pub fn wait(self: *Subprocess) !ExitResult {
        // Drain stderr before calling wait() to avoid pipe-buffer deadlock.
        const stderr_output: []const u8 = blk: {
            if (self.child.stderr) |stderr_file| {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                errdefer buf.deinit(self.allocator);
                var read_buf: [4096]u8 = undefined;
                while (true) {
                    const n = try stderr_file.read(&read_buf);
                    if (n == 0) break;
                    try buf.appendSlice(self.allocator, read_buf[0..n]);
                }
                break :blk try buf.toOwnedSlice(self.allocator);
            }
            break :blk try self.allocator.dupe(u8, "");
        };
        errdefer self.allocator.free(stderr_output);

        const term = try self.child.wait();
        const exit_code: u32 = switch (term) {
            .Exited => |code| @as(u32, code),
            .Signal => |sig| @as(u32, @intCast(sig)) + 128,
            .Stopped => |sig| @as(u32, @intCast(sig)) + 128,
            .Unknown => |code| @as(u32, @intCast(code)),
        };
        return ExitResult{ .exit_code = exit_code, .stderr_output = stderr_output };
    }

    /// Sends SIGKILL and reaps the process. Safe to call instead of wait().
    pub fn kill(self: *Subprocess) void {
        _ = self.child.kill() catch {};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "subprocess: echo exits 0" {
    const argv = [_][]const u8{ "echo", "hello" };
    var sub = try Subprocess.spawn(&argv, std.testing.allocator);
    const result = try sub.wait();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
}

test "subprocess: sh -c exit 42 -> exit_code 42" {
    const argv = [_][]const u8{ "sh", "-c", "exit 42" };
    var sub = try Subprocess.spawn(&argv, std.testing.allocator);
    const result = try sub.wait();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 42), result.exit_code);
}

test "subprocess: nonexistent binary returns error at spawn or wait" {
    // In Zig 0.15.2 on POSIX, spawn() forks without blocking on exec errors.
    // Exec failure is detected either at spawn() time (on some platforms)
    // or at wait() time via the err_pipe mechanism.
    const argv = [_][]const u8{"/nonexistent/binary/that/does/not/exist"};
    var sub = Subprocess.spawn(&argv, std.testing.allocator) catch {
        return; // spawn-time detection: any error is acceptable
    };
    // If spawn succeeded, exec error propagates through wait()
    const result = sub.wait() catch {
        return; // wait-time exec error: acceptable
    };
    defer result.deinit(std.testing.allocator);
    // Fallback: non-zero exit code from failed exec
    try std.testing.expect(result.exit_code != 0);
}

test "subprocess: stderr captured" {
    const argv = [_][]const u8{ "sh", "-c", "echo 'captured error' >&2; exit 0" };
    var sub = try Subprocess.spawn(&argv, std.testing.allocator);
    const result = try sub.wait();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr_output, "captured error") != null);
}

test "subprocess: kill terminates long-running process" {
    const argv = [_][]const u8{ "sleep", "100" };
    var sub = try Subprocess.spawn(&argv, std.testing.allocator);
    // kill() should return without hanging
    sub.kill();
}
