const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/follow_up.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_ui.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_notifications.zig"));
    std.testing.refAllDecls(@import("terminal/thread_window.zig"));
    std.testing.refAllDecls(@import("terminal/completion.zig"));
    std.testing.refAllDecls(@import("terminal/cache_query.zig"));
    std.testing.refAllDecls(@import("terminal/reader_find.zig"));
    std.testing.refAllDecls(@import("terminal/edit_history.zig"));
    std.testing.refAllDecls(@import("terminal/composer_hints.zig"));
    std.testing.refAllDecls(@import("terminal/invitation.zig"));
    std.testing.refAllDecls(@import("terminal/invitation_receipt.zig"));
    std.testing.refAllDecls(@import("terminal/cli_files.zig"));
    std.testing.refAllDecls(@import("terminal/delivery_view.zig"));
    std.testing.refAllDecls(@import("terminal/send_drive.zig"));
}
