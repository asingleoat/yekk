const app = @import("linux_app.zig");
const memory = @import("memory.zig");
const runtime = @import("runtime");
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    var status: c_int = 0;
    app.run(argv[1..@intCast(argc)]) catch |err| {
        if (err != error.InvalidArguments) {
            runtime.output(2, @errorName(err));
            runtime.output(2, "\n");
        }
        status = if (err == error.InvalidArguments) 2 else 1;
    };
    return if (memory.finish()) status else 1;
}
