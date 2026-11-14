//! Cache policy contains no native operations and performs no allocations.
const std = @import("std");
pub const Pressure = enum { normal, warning, critical };
pub const decode_lanes = 2;
pub const speculative_lanes = 1;
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
