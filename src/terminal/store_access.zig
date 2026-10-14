//! Storage selection carried into helpers that open their own transactions.
//! A vault session supplies its owner callback; absence selects legacy files.
const std = @import("std");
const storage = @import("store.zig");
const t = @import("types.zig");
pub const Access = struct {
    context: ?*anyopaque = null,
    openFn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, bool) anyerror!storage.Store = null,
    pub fn open(self: Access, io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, readonly: bool) !storage.Store {
        if (self.openFn) |callback| return callback(self.context orelse return error.InvalidStoreOwner, a, account, readonly);
        if (self.context != null) return error.InvalidStoreOwner;
        return if (readonly) storage.Store.openCached(io, a, root, account, options) else storage.Store.open(io, a, root, account, options);
    }
};
