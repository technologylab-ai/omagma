//! Focused file-browser tests without the terminal renderer or live accounts.
const std = @import("std");

test {
    std.testing.refAllDecls(@import("terminal/file_dialog.zig"));
}
