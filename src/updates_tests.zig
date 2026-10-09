//! Update discovery and persistence run independently of libvaxis and Gmail.
const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/updates.zig"));
    std.testing.refAllDecls(@import("http_client.zig"));
}
