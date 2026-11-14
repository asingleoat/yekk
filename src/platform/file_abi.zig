//! SDK file types with the matching native symbols. The pinned translate-c
//! drops Darwin asm aliases; Intel still exports legacy inode32 names too.
const c = @import("system");
const builtin = @import("builtin");

fn bind(comptime name: []const u8) *const @TypeOf(@field(c, name)) {
    return if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64)
        @extern(*const @TypeOf(@field(c, name)), .{ .name = name ++ "$INODE64", .library_name = "c" })
    else
        &@field(c, name);
}

pub const stat = bind("stat");
pub const lstat = bind("lstat");
pub const fstat = bind("fstat");
pub const opendir = bind("opendir");
pub const readdir = bind("readdir");
