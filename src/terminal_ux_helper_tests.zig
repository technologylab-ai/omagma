const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/completion.zig"));
    std.testing.refAllDecls(@import("terminal/cache_query.zig"));
    std.testing.refAllDecls(@import("terminal/reader_find.zig"));
    std.testing.refAllDecls(@import("terminal/edit_history.zig"));
    std.testing.refAllDecls(@import("terminal/composer_hints.zig"));
    std.testing.refAllDecls(@import("terminal/invitation.zig"));
}
