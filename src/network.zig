//! Download HTTP and HTTPS through libcurl. A response body is streamed to disk.
const std = @import("std");
const c = @import("curl_bindings");
const posix = @import("system");
const runtime = @import("runtime");

var initialization: std.atomic.Value(enum(u8) { idle, running, ready, failed }) = .init(.idle);

fn initialize() !void {
    if (initialization.cmpxchgStrong(.idle, .running, .acq_rel, .acquire) == null) {
        initialization.store(if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) == c.CURLE_OK) .ready else .failed, .release);
    }
    while (initialization.load(.acquire) == .running) _ = posix.poll(null, 0, 1);
    if (initialization.load(.acquire) != .ready) return error.NetworkUnavailable;
}

const Transfer = struct {
    fd: c_int,
    cancel: ?*const std.atomic.Value(bool),

    fn cancelled(self: *const Transfer) bool {
        return if (self.cancel) |flag| flag.load(.acquire) else false;
    }
};
fn write(data: [*c]u8, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(userdata.?));
    const length = std.math.mul(usize, size, count) catch return 0;
    var offset: usize = 0;
    while (offset < length and !transfer.cancelled()) {
        const result = posix.write(transfer.fd, data + offset, length - offset);
        if (result < 0 and runtime.errno().* == posix.EINTR) continue;
        if (result <= 0) return 0;
        offset += @intCast(result);
    }
    return offset;
}
fn progress(userdata: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const transfer: *Transfer = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(transfer.cancelled());
}
fn setting(handle: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, option, value) != c.CURLE_OK) return error.NetworkOptionsFailed;
}
pub fn download(url: [:0]const u8, fd: c_int, insecure: bool, cancel: ?*const std.atomic.Value(bool)) anyerror!void {
    var transfer: Transfer = .{ .fd = fd, .cancel = cancel };
    if (transfer.cancelled()) return error.Cancelled;
    try initialize();
    const handle = c.curl_easy_init() orelse return error.NetworkUnavailable;
    defer c.curl_easy_cleanup(handle);
    try setting(handle, c.CURLOPT_URL, url.ptr);
    const bundle = posix.getenv("CURL_CA_BUNDLE");
    const cert_file = posix.getenv("SSL_CERT_FILE");
    const nix_cert_file = posix.getenv("NIX_SSL_CERT_FILE");
    if (bundle != null) {
        try setting(handle, c.CURLOPT_CAINFO, bundle);
    } else if (cert_file != null) {
        try setting(handle, c.CURLOPT_CAINFO, cert_file);
    } else if (nix_cert_file != null) {
        try setting(handle, c.CURLOPT_CAINFO, nix_cert_file);
    } else {
        for ([_][:0]const u8{ "/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt" }) |name| {
            if (posix.access(name.ptr, posix.R_OK) == 0) {
                try setting(handle, c.CURLOPT_CAINFO, name.ptr);
                break;
            }
        }
    }
    try setting(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
    try setting(handle, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
    try setting(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    try setting(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 8));
    try setting(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try setting(handle, c.CURLOPT_FAILONERROR, @as(c_long, 1));
    try setting(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    try setting(handle, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
    try setting(handle, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, 30));
    try setting(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    try setting(handle, c.CURLOPT_WRITEDATA, &transfer);
    try setting(handle, c.CURLOPT_WRITEFUNCTION, @as(c.curl_write_callback, write));
    try setting(handle, c.CURLOPT_XFERINFODATA, &transfer);
    try setting(handle, c.CURLOPT_XFERINFOFUNCTION, @as(c.curl_xferinfo_callback, progress));
    if (insecure) {
        try setting(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0));
        try setting(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0));
    }
    if (c.curl_easy_perform(handle) != c.CURLE_OK) return if (transfer.cancelled()) error.Cancelled else error.DownloadFailed;
}
