//! The host exchanges terminal bytes and injects an explicit session HTTP
//! transport. OAuth tokens stay in the host, outside WASM and diagnostics.
const std = @import("std");
const tui = @import("terminal/tui.zig");
const draft_storage = @import("browser_drafts.zig");
extern "env" fn drafts_store(session: u32, pointer: usize, length: usize) u32;
pub const panic = std.debug.FullPanic(trap);
fn trap(_: []const u8, _: ?usize) noreturn {
    @trap();
}
pub const std_options: std.Options = .{ .log_level = .err, .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}
const BrowserHeap = @import("browser_heap.zig").Heap;
const policy_json = blk: {
    @setEvalBranchQuota(100_000);
    break :blk std.fmt.comptimePrint("{f}", .{std.json.fmt(@import("terminal/mail_limits.zig").manifest, .{})});
};
var heap_buffer: [@import("browser_provider.zig").heap_bytes]u8 align(16) = undefined;
var heap: BrowserHeap = undefined;
var heap_initialized = false;
var demo: tui.BrowserSession = undefined;
var initialized = false;
var busy = false;
var edit_input_context = false;
var input_buffer: [1024]u8 = undefined;
var connect_buffer: [16 * 1024]u8 = undefined;
var cache_buffer: [3 * 1024 * 1024]u8 = undefined;
var cache_length: usize = 0;
var staged_cache_length: usize = 0;
// Transfer bytes share the fixed application heap, never enlarge linear memory.
var staged_drafts: ?[]u8 = null;
var output_buffer: [1024 * 1024]u8 = undefined;
var output_length: usize = 0;
var writer: std.Io.Writer = undefined;
var decoder: @import("terminal/input.zig").Decoder = .{};

// A synchronous, allocation-free query for the terminal host. It is safe
// before init and while another operation is suspended; it touches no session.
export fn codepoint_width(codepoint: u32) u32 {
    return tui.browserCodepointWidth(codepoint);
}

// Static trusted configuration; no upload, provider response or credential
// controls cache admission policy. Reading it needs no session allocation.
export fn policy_ptr() usize {
    return @intFromPtr(policy_json);
}
export fn policy_len() usize {
    return policy_json.len;
}

export fn init(cols: u32, rows: u32) u32 {
    if (busy) return 4;
    if (initialized) return resize(cols, rows);
    if (!heap_initialized) {
        heap = .init(&heap_buffer);
        heap_initialized = true;
    }
    writer = .fixed(&output_buffer);
    demo.init(heap.allocator(), &writer, dimension(cols, 240), dimension(rows, 80)) catch return 1;
    demo.provider.draft_store = .{ .saveFn = persistDraftSnapshot };
    initialized = true;
    return redraw();
}
fn persistDraftSnapshot(_: ?*anyopaque, session: u32, bytes: []const u8) !void {
    return switch (drafts_store(session, @intFromPtr(bytes.ptr), bytes.len)) {
        0 => {},
        2 => error.BrowserDraftQuota,
        3 => error.BrowserDraftStorageConflict,
        4 => error.BrowserDraftOperationQuota,
        else => error.BrowserDraftStorageUnavailable,
    };
}
fn dimension(value: u32, maximum: u16) u16 {
    return @intCast(@min(@max(value, 1), maximum));
}
export fn resize(cols: u32, rows: u32) u32 {
    if (busy) return 4;
    if (!initialized) return 2;
    writer = .fixed(&output_buffer);
    demo.resize(dimension(cols, 240), dimension(rows, 80)) catch return 1;
    return redraw();
}
export fn input_ptr() usize {
    return @intFromPtr(&input_buffer);
}
export fn input_capacity() usize {
    return input_buffer.len;
}
export fn output_ptr() usize {
    return @intFromPtr(&output_buffer);
}
export fn output_len() usize {
    return output_length;
}
export fn input(length: usize) u32 {
    if (busy) return 4;
    if (!initialized or length > input_buffer.len) return 2;
    busy = true;
    defer busy = false;
    edit_input_context = true;
    defer edit_input_context = false;
    var offset: usize = 0;
    while (offset < length) {
        // A UTF-8 or ANSI prefix may remain from the preceding host chunk.
        // Fill only the decoder's remaining room, consume complete events,
        // then append the rest without dropping that bounded prefix.
        const writable = decoder.writable() catch return 3;
        const count = @min(length - offset, writable.len);
        @memcpy(writable[0..count], input_buffer[offset..][0..count]);
        decoder.added(count);
        offset += count;
        while (decoder.next() catch return 3) |event| {
            switch (event) {
                .key_press => |key| demo.key(key) catch |err| demo.failure(err),
                .mouse => |mouse| demo.mouse(mouse) catch |err| demo.failure(err),
                .paste_start => demo.pasteStart(),
                .paste_end => demo.pasteEnd(),
                else => {},
            }
        }
    }
    return redraw();
}
export fn connect_ptr() usize {
    return @intFromPtr(&connect_buffer);
}
export fn connect_capacity() usize {
    return connect_buffer.len;
}
export fn connect(length: usize) u32 {
    if (busy) return 4;
    if (!initialized or length > connect_buffer.len) return 2;
    busy = true;
    defer busy = false;
    demo.stageCache(cache_buffer[0..staged_cache_length]);
    demo.stageDrafts(staged_drafts orelse "");
    defer {
        staged_cache_length = 0;
        std.crypto.secureZero(u8, &cache_buffer);
        if (staged_drafts) |bytes| {
            std.crypto.secureZero(u8, bytes);
            heap.allocator().free(bytes);
            staged_drafts = null;
        }
    }
    demo.connect(connect_buffer[0..length]) catch |err| {
        demo.failure(err);
        _ = redraw();
        return 1;
    };
    return redraw();
}
export fn live_accounts() u32 {
    return if (initialized) @intCast(demo.accountCount()) else 0;
}
export fn draft_count() u32 {
    return if (initialized) @intCast(demo.draftCount()) else 0;
}
export fn draft_dirty() u32 {
    return @intFromBool(initialized and demo.draftDirty());
}
export fn autosave_pending() u32 {
    return @intFromBool(initialized and demo.autosavePending());
}
export fn autosave_accepts_input() u32 {
    return @intFromBool(initialized and edit_input_context and demo.autosaveAcceptsInput());
}
export fn autosave_delay() u32 {
    return if (initialized) demo.autosaveDelay() else 0;
}
export fn idle() u32 {
    if (busy or !initialized) return 4;
    busy = true;
    defer busy = false;
    edit_input_context = true;
    defer edit_input_context = false;
    demo.idle() catch |err| demo.failure(err);
    return redraw();
}
export fn drafts_stage(length: usize) u32 {
    if (busy or !initialized or length > draft_storage.snapshot_bytes) return 2;
    if (staged_drafts) |bytes| {
        std.crypto.secureZero(u8, bytes);
        heap.allocator().free(bytes);
        staged_drafts = null;
    }
    if (length > 0) staged_drafts = heap.allocator().alloc(u8, length) catch return 1;
    return 0;
}
export fn drafts_restored(index: usize) u32 {
    return @intFromBool(initialized and demo.draftsRestored(index));
}
export fn drafts_input_ptr() usize {
    return if (staged_drafts) |bytes| @intFromPtr(bytes.ptr) else 0;
}
export fn drafts_input_capacity() usize {
    return draft_storage.snapshot_bytes;
}
export fn can_send() u32 {
    return @intFromBool(initialized and demo.canSend());
}
export fn can_contacts(index: usize) u32 {
    return @intFromBool(initialized and index < demo.accountCount() and demo.canContacts(index));
}
export fn send_status() u32 {
    return if (initialized) demo.sendStatus() else 0;
}
export fn cache_input_ptr() usize {
    return @intFromPtr(&cache_buffer);
}
export fn cache_input_capacity() usize {
    return cache_buffer.len;
}
export fn cache_stage(length: usize) u32 {
    if (busy or !initialized or length > cache_buffer.len) return 2;
    staged_cache_length = length;
    return 0;
}
export fn cache_export(index: usize) u32 {
    if (busy or !initialized) return 4;
    cache_length = 0;
    const bytes = demo.cacheSnapshot(index, &cache_buffer) catch return 3;
    cache_length = bytes.len;
    return 0;
}
export fn cache_ptr() usize {
    return @intFromPtr(&cache_buffer);
}
export fn cache_len() usize {
    return cache_length;
}
export fn cache_revision(index: usize) u32 {
    return if (initialized) demo.cacheRevision(index) else 0;
}
export fn cache_clear(index: usize) u32 {
    if (busy or !initialized) return 4;
    if (index == 0xffffffff) {
        for (0..demo.accountCount()) |actor| demo.cacheClear(actor) catch |err| demo.failure(err);
        return redraw();
    }
    demo.cacheClear(index) catch |err| {
        demo.failure(err);
        return redraw();
    };
    return redraw();
}
export fn unknown_target_index() u32 {
    if (!initialized) return 0xffffffff;
    return if (demo.unknownTarget()) |target| @intCast(target.account_index) else 0xffffffff;
}
export fn unknown_account_ptr() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| @intFromPtr(target.account.ptr) else 0) else 0;
}
export fn unknown_account_len() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| target.account.len else 0) else 0;
}
export fn unknown_draft_ptr() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| @intFromPtr(target.draft_id.ptr) else 0) else 0;
}
export fn unknown_draft_len() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| target.draft_id.len else 0) else 0;
}
export fn unknown_operation_ptr() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| @intFromPtr(target.operation_id.ptr) else 0) else 0;
}
export fn unknown_operation_len() usize {
    return if (initialized) (if (demo.unknownTarget()) |target| target.operation_id.len else 0) else 0;
}
export fn acknowledge_unknown(expected_index: u32, pointer: usize, length: usize) u32 {
    if (busy or !initialized) return 4;
    const expected_draft: []const u8 = if (demo.unknownTarget()) |target| blk: {
        if (expected_index != target.account_index or pointer != @intFromPtr(target.draft_id.ptr) or length != target.draft_id.len) return 2;
        break :blk target.draft_id;
    } else blk: {
        if (expected_index != 0xffffffff or pointer != 0 or length != 0) return 2;
        break :blk "";
    };
    busy = true;
    defer busy = false;
    demo.acknowledgeUnknown(expected_index, expected_draft) catch |err| {
        demo.failure(err);
        _ = redraw();
        return 1;
    };
    return redraw();
}
export fn contacts_permission(index: usize, allowed: u32) u32 {
    if (busy or !initialized) return 4;
    busy = true;
    defer busy = false;
    demo.restrictContacts(index, allowed != 0) catch |err| demo.failure(err);
    return redraw();
}
fn redraw() u32 {
    writer = .fixed(&output_buffer);
    demo.draw() catch {
        output_length = 0;
        return 1;
    };
    output_length = writer.end;
    return 0;
}
