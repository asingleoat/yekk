//! Linux adapter: Zig application code calling generated library bindings.
pub const types = @import("linux_types.zig");
pub const image = @import("linux_image.zig");
pub const render = @import("linux_render.zig");
pub const window = @import("linux_window.zig");
pub const input = @import("linux_input.zig");
pub const desktop = @import("linux_desktop.zig");
pub const Image = types.Image;
pub const Frame = types.Frame;
pub const Event = types.Event;
pub const Window = types.Window;
pub const Geometry = types.Geometry;
pub const Metadata = types.Metadata;
pub const Selection = types.Selection;
pub const window_limit = types.window_limit;
pub fn shutdown() void {
    render.contextFinish();
    image.shutdown();
}
