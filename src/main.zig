const app = @import("app.zig");
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const result = app.run(argc, argv);
    return if (@import("memory.zig").finish()) result else 1;
}
