const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/calendar_ui.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_notifications.zig"));
    std.testing.refAllDecls(@import("terminal/batch.zig"));
    std.testing.refAllDecls(@import("terminal/draft_measure_commands.zig"));
    std.testing.refAllDecls(@import("terminal/gmail.zig"));
}
