const std = @import("std");
pub const capacity = 8;
pub const Open = enum { ignore_cli_replay, reuse_empty, new_window, at_capacity };
pub fn route(cli_inputs: bool, launched: bool, empty: bool, active: usize) Open {
    if (cli_inputs and !launched) return .ignore_cli_replay;
    if (empty) return .reuse_empty;
    return if (active < capacity) .new_window else .at_capacity;
}
test "CLI startup replay cannot create windows even when repeated" {
    for (0..10000) |_| try std.testing.expectEqual(Open.ignore_cli_replay, route(true, false, false, 1));
}
test "native opens reuse an empty window and have a fixed upper bound" {
    try std.testing.expectEqual(Open.reuse_empty, route(false, false, true, 1));
    try std.testing.expectEqual(Open.new_window, route(false, true, false, 1));
    try std.testing.expectEqual(Open.at_capacity, route(false, true, false, capacity));
}
