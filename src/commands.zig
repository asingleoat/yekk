//! Explicit user hooks only. One worker owns the child and drains its output.
const std = @import("std");
const c = @import("system");
const n = @import("runtime");
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" var environ: [*:null]?[*:0]u8;
pub const Result = struct {
    status: c_int = -1,
    cancelled: bool = false,
    output: [1024]u8 = undefined,
    len: usize = 0,
    pub fn exitCode(self: *const Result) ?c_int {
        return if (self.status >= 0 and self.status & 0x7f == 0) (self.status >> 8) & 0xff else null;
    }
    pub fn success(self: *const Result) bool {
        return !self.cancelled and self.status == 0;
    }
};
fn capturePipe() ![2]c_int {
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) return error.PipeFailed;
    errdefer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }
    // Keep the pipe separate from standard descriptors, even when closed.
    for (&pipe) |*fd| if (fd.* < 3) {
        const moved = c.fcntl(fd.*, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) return error.PipeFailed;
        _ = c.close(fd.*);
        fd.* = moved;
    };
    if (c.fcntl(pipe[0], c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0 or c.fcntl(pipe[1], c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.PipeFailed;
    if (c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PipeFailed;
    return pipe;
}

fn drain(fd: c_int, result: *Result) bool {
    var buffer: [4096]u8 = undefined;
    // Limit each batch so output cannot delay cancellation indefinitely.
    for (0..16) |_| {
        const count = c.read(fd, &buffer, buffer.len);
        if (count <= 0) return false;
        const keep = @min(@as(usize, @intCast(count)), result.output.len - result.len);
        @memcpy(result.output[result.len..][0..keep], buffer[0..keep]);
        result.len += keep;
    }
    return true;
}

pub fn run(command: [:0]const u8, cancel: *const std.atomic.Value(bool)) !Result {
    return runWithOutput(command, cancel, .capture);
}

pub fn runInfo(command: [:0]const u8, cancel: *const std.atomic.Value(bool)) !Result {
    return runWithOutput(command, cancel, .stdout_only);
}

pub fn runWithOutput(command: [:0]const u8, cancel: *const std.atomic.Value(bool), output: enum { capture, inherit, stdout_only }) !Result {
    var result: Result = .{};
    if (cancel.load(.acquire)) {
        result.cancelled = true;
        return result;
    }
    const pipe = if (output != .inherit) try capturePipe() else null;
    var write_open = true;
    defer if (pipe) |fds| {
        _ = c.close(fds[0]);
        if (write_open) _ = c.close(fds[1]);
    };
    var files: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&files) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&files);
    if (c.posix_spawn_file_actions_addopen(&files, 0, "/dev/null", c.O_RDONLY, 0) != 0) return error.SpawnFailed;
    if (pipe) |fds| {
        if (c.posix_spawn_file_actions_adddup2(&files, fds[1], 1) != 0 or
            (if (output == .stdout_only) c.posix_spawn_file_actions_addopen(&files, 2, "/dev/null", c.O_WRONLY, 0) else c.posix_spawn_file_actions_adddup2(&files, fds[1], 2)) != 0 or
            c.posix_spawn_file_actions_addclose(&files, fds[0]) != 0 or
            c.posix_spawn_file_actions_addclose(&files, fds[1]) != 0) return error.SpawnFailed;
    } else if (n.darwin) {
        // CLOEXEC_DEFAULT requires an explicit action for each inherited fd.
        for ([_]c_int{ 1, 2 }) |fd| {
            if (c.fcntl(fd, c.F_GETFD) >= 0 and c.posix_spawn_file_actions_addinherit_np(&files, fd) != 0) return error.SpawnFailed;
        }
    }
    if (!n.darwin and c.posix_spawn_file_actions_addclosefrom_np(&files, 3) != 0) return error.SpawnFailed;
    var attrs: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attrs) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawnattr_destroy(&attrs);
    var mask: c.sigset_t = undefined;
    if (c.sigemptyset(&mask) != 0 or c.posix_spawnattr_setsigmask(&attrs, &mask) != 0) return error.SpawnFailed;
    if (c.posix_spawnattr_setpgroup(&attrs, 0) != 0 or
        c.posix_spawnattr_setflags(&attrs, c.POSIX_SPAWN_SETPGROUP | (if (n.darwin) c.POSIX_SPAWN_CLOEXEC_DEFAULT else 0) | c.POSIX_SPAWN_SETSIGMASK) != 0) return error.SpawnFailed;
    const args = [_:null]?[*:0]const u8{ "sh", "-c", command.ptr };
    var pid: c.pid_t = undefined;
    if (c.posix_spawn(&pid, "/bin/sh", &files, &attrs, @ptrCast(@constCast(&args)), if (n.darwin) _NSGetEnviron().* else environ) != 0) return error.SpawnFailed;
    if (pipe) |fds| {
        _ = c.close(fds[1]);
        write_open = false;
    }
    const deadline = if (output == .stdout_only) n.now() + 5 else std.math.inf(f64);
    var terminated_at: ?f64 = null;
    while (true) {
        const drained_batch = if (pipe) |fds| drain(fds[0], &result) else false;
        if (terminated_at == null and (cancel.load(.acquire) or n.now() >= deadline)) {
            result.cancelled = true;
            _ = c.kill(-pid, c.SIGTERM);
            terminated_at = n.now();
        }
        if (terminated_at) |at| if (n.now() - at > 0.3) {
            _ = c.kill(-pid, c.SIGKILL);
        };
        const waited = c.waitpid(pid, &result.status, c.WNOHANG);
        if (waited == pid) {
            if (result.cancelled) _ = c.kill(-pid, c.SIGKILL);
            // waitpid may observe a fast exit just after the earlier read.
            if (pipe) |fds| _ = drain(fds[0], &result);
            break;
        }
        if (waited < 0 and n.errno().* != c.EINTR) return error.WaitFailed;
        // A worker sleeps; the UI keeps processing input and rendering.
        _ = c.poll(null, 0, if (drained_batch) @as(c_int, 0) else 10);
    }
    return result;
}
test "shell hooks complete, fail, and drain large output without blocking" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const ok = try run("printf ok", &cancel);
    try std.testing.expect(ok.success());
    try std.testing.expectEqualStrings("ok", ok.output[0..ok.len]);
    const failed = try run("exit 7", &cancel);
    try std.testing.expect(!failed.success());
    try std.testing.expectEqual(@as(c_int, 7), failed.exitCode().?);
    const verbose = try run("yes x | head -c 131072", &cancel);
    try std.testing.expect(verbose.success());
    try std.testing.expectEqual(@as(usize, 1024), verbose.len);
}
test "closing cancels a hook and reaps its child" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const worker = try std.Thread.spawn(.{}, struct {
        fn stop(flag: *std.atomic.Value(bool)) void {
            _ = c.poll(null, 0, 50);
            flag.store(true, .release);
        }
    }.stop, .{&cancel});
    defer worker.join();
    const started = n.now();
    const result = try run("trap '' TERM; sleep 30", &cancel);
    try std.testing.expect(result.cancelled);
    try std.testing.expect(n.now() - started < 2);
}

test "shell-safe expansion survives real execution" {
    const hooks = @import("hooks.zig");
    var buffer: [1024]u8 = undefined;
    const path = "/tmp/雪'$(exit 73)\n.png";
    const command = try hooks.format(&buffer, "printf '%%s' %F", .{ .path = path });
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try run(command, &cancel);
    try std.testing.expect(result.success());
    try std.testing.expectEqualStrings(path, result.output[0..result.len]);
}
