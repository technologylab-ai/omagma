const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/platform.zig"));
    std.testing.refAllDecls(@import("terminal/conversation_draft.zig"));
    std.testing.refAllDecls(@import("terminal/draft_codec.zig"));
    std.testing.refAllDecls(@import("terminal/send_outcome.zig"));
    std.testing.refAllDecls(@import("terminal/client_contract.zig"));
}
