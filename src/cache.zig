//! Cache policy contains no native operations and performs no allocations.
const std = @import("std");
pub const Pressure = enum { normal, warning, critical };
pub const decode_lanes = 2;
pub const speculative_lanes = 1;
/// One output plus decoder workspace, with compressed input accounted separately.
/// This is an admission estimate, not a cache-size limit.
pub fn prefetchEstimate(width: u32, height: u32, file_bytes: u64) u64 {
    return (@as(u64, width) * height) *| 16 +| file_bytes;
}
pub fn prefetchFits(available: u64, estimate: u64, foreground_reserve: u64) bool {
    return estimate <= available and foreground_reserve <= available - estimate;
}

/// Scan each remaining entry once. A deferred large image does not stop smaller
/// candidates. Retry only when enough RAM is available, at most once per second.
pub const PrefetchSweep = struct {
    pub const Config = struct { current: usize, count: usize, selection: u64, version: u64 = 0 };
    config: ?Config = null,
    phase: union(enum) {
        complete,
        scanning: struct { offset: usize = 1, minimum: ?u64 = null },
        waiting: struct { required: u64, retry_at: f64 },
    } = .complete,

    pub fn configure(self: *PrefetchSweep, config: Config) void {
        if (self.config) |old| if (std.meta.eql(old, config)) return;
        self.config = config;
        self.phase = if (config.current < config.count) .{ .scanning = .{} } else .complete;
    }
    pub fn ready(self: PrefetchSweep, now: f64) bool {
        return switch (self.phase) {
            .complete => false,
            .scanning => true,
            .waiting => |wait| now >= wait.retry_at,
        };
    }
    pub fn next(self: *PrefetchSweep, now: f64, available: u64) ?usize {
        if (self.phase == .waiting) {
            const wait = &self.phase.waiting;
            if (now < wait.retry_at) return null;
            if (available < wait.required) {
                wait.retry_at = now + 1;
                return null;
            }
            self.phase = .{ .scanning = .{} };
        }
        if (self.phase != .scanning) return null;
        const config = self.config.?;
        const scan = &self.phase.scanning;
        if (scan.offset >= config.count) {
            self.phase = if (scan.minimum) |required| .{ .waiting = .{ .required = required, .retry_at = now + 1 } } else .complete;
            return null;
        }
        const offset = scan.offset;
        scan.offset += 1;
        const to_end = config.count - config.current;
        return if (offset < to_end) config.current + offset else offset - to_end;
    }
    pub fn blocked(self: *PrefetchSweep, required: u64) void {
        if (self.phase == .scanning) {
            const minimum = &self.phase.scanning.minimum;
            minimum.* = if (minimum.*) |old| @min(old, required) else required;
        }
    }
    pub fn retryCandidate(self: *PrefetchSweep) void {
        std.debug.assert(self.phase == .scanning and self.phase.scanning.offset > 1);
        self.phase.scanning.offset -= 1;
    }
};
pub fn admitDecode(active: usize, speculative: usize, foreground: bool) bool {
    return active < decode_lanes and (foreground or speculative < speculative_lanes);
}
pub const State = enum { empty, loading, ready, failed };
pub const Record = struct {
    state: State = .empty,
    version: u64 = 0,
    touched: u64 = 0,
    lane: ?usize = null,
    displayed: bool = false,
    visited: bool = false,
};
pub fn reclaim(record: Record, pressure: Pressure, current: bool, neighbor: bool) bool {
    if (pressure == .normal or current or record.displayed or record.state != .ready) return false;
    if (pressure == .critical) return true;
    return !neighbor;
}
pub fn adjacent(current: usize, count: usize, forward: bool, wrap: bool) [2]?usize {
    if (count <= 1) return .{ null, null };
    const next: ?usize = if (current + 1 < count) current + 1 else if (wrap) 0 else null;
    const previous: ?usize = if (current > 0) current - 1 else if (wrap) count - 1 else null;
    return if (forward) .{ next, previous } else .{ previous, next };
}
test "normal pressure never evicts history and warning protects active neighborhood" {
    const r: Record = .{ .state = .ready };
    try std.testing.expect(!reclaim(r, .normal, false, false));
    try std.testing.expect(!reclaim(r, .warning, false, true));
    try std.testing.expect(reclaim(r, .warning, false, false));
    try std.testing.expect(!reclaim(r, .critical, true, false));
    try std.testing.expect(!reclaim(.{ .state = .loading }, .critical, false, false));
}
test "neighbors respect direction, boundaries, and wrapping" {
    try std.testing.expectEqual([2]?usize{ 1, null }, adjacent(0, 4, true, false));
    try std.testing.expectEqual([2]?usize{ 2, 0 }, adjacent(3, 4, false, true));
    try std.testing.expectEqual([2]?usize{ null, null }, adjacent(0, 1, true, true));
}

test "aggressive sweep skips the selected image and retries deferred entries after RAM recovers" {
    var sweep: PrefetchSweep = .{};
    sweep.configure(.{ .current = 2, .count = 5, .selection = 1 });
    for ([_]usize{ 3, 4, 0, 1 }) |expected| {
        try std.testing.expectEqual(expected, sweep.next(0, 100).?);
        sweep.blocked(if (expected == 3) 1000 else 200);
    }
    try std.testing.expect(sweep.next(0, 100) == null);
    try std.testing.expect(!sweep.ready(0.99));
    try std.testing.expect(sweep.next(1, 199) == null);
    try std.testing.expectEqual(@as(usize, 3), sweep.next(2, 200).?);
    sweep.configure(.{ .current = 4, .count = 5, .selection = 2 });
    try std.testing.expectEqual(@as(usize, 0), sweep.next(2, 100).?);
    sweep.configure(.{ .current = 0, .count = 1, .selection = 3 });
    try std.testing.expect(sweep.next(2, 100) == null);
    try std.testing.expect(sweep.phase == .complete);
}

test "prefetch headroom scales to hardware capacity and handles hostile size arithmetic" {
    const tib: u64 = 1 << 40;
    try std.testing.expect(prefetchFits(4 * tib, 2 * tib, tib));
    try std.testing.expect(!prefetchFits(tib, 2 * tib, 0));
    try std.testing.expect(!prefetchFits(100, 75, 26));
    try std.testing.expectEqual(std.math.maxInt(u64), prefetchEstimate(std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u64)));
}
