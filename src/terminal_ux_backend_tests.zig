const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/core.zig"));
    std.testing.refAllDecls(@import("terminal/store.zig"));
    std.testing.refAllDecls(@import("terminal/labels.zig"));
    std.testing.refAllDecls(@import("terminal/send_queue.zig"));
    std.testing.refAllDecls(@import("terminal/contact_record.zig"));
    std.testing.refAllDecls(@import("terminal/attachment_blob.zig"));
    std.testing.refAllDecls(@import("terminal/attachment_json.zig"));
    std.testing.refAllDecls(@import("terminal/cli_plan.zig"));
}
