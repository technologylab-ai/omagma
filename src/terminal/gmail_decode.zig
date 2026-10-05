const std = @import("std");
const mime = @import("mime.zig");
const types = @import("types.zig");

/// The account-scoped provider supplies external Gmail attachment responses.
/// Every slice in the normalized message belongs to the caller's allocator.
pub fn normalize(value: std.json.Value, allocator: std.mem.Allocator, externalBodies: ?std.json.Value) !types.Message {
    return try mime.normalizeGmail(value, allocator, externalBodies);
}
