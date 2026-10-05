//! Bounded Linux input adapter around the pinned libvaxis parser, queue and
//! capability dispatcher. No dependency/cache source is modified.
//! Lifecycle adapted from libvaxis Loop.zig at
//! 6fd944a27fb3d6f596e981076381a3131f2448b4.
//! Copyright (c) 2023 Tim Culverhouse. MIT license: LICENSES/libvaxis.txt.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const capacity = 1024;

fn completeUtf8Prefix(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var start = bytes.len - 1;
    while (bytes[start] & 0xc0 == 0x80 and bytes.len - start < 4 and start > 0) start -= 1;
    const lead = bytes[start];
    if (lead < 0xc2 or lead > 0xf4) return bytes.len;
    const needed = std.unicode.utf8ByteSequenceLength(lead) catch return bytes.len;
    if (bytes.len - start >= needed) return bytes.len;
    const tail = bytes[start..];
    for (tail[1..]) |byte| if (byte & 0xc0 != 0x80) return bytes.len;
    if (tail.len > 1 and ((lead == 0xe0 and tail[1] < 0xa0) or
        (lead == 0xed and tail[1] >= 0xa0) or
        (lead == 0xf0 and tail[1] < 0x90) or
        (lead == 0xf4 and tail[1] >= 0x90))) return bytes.len;
    return start;
}

fn malformedInput(err: anyerror) bool {
    return switch (err) {
        error.InvalidCharacter, error.InvalidColorSpec, error.InvalidPadding, error.InvalidUTF8, error.Utf8CannotEncodeSurrogateHalf, error.CodepointTooLarge, error.Overflow => true,
        else => false,
    };
}

pub const Decoder = struct {
    bytes: [capacity]u8 = undefined,
    used: usize = 0,
    consumed: usize = 0,
    parser: vaxis.Parser = .{},

    pub fn remaining(self: *const Decoder) []const u8 {
        return self.bytes[self.consumed..self.used];
    }
    pub fn writable(self: *Decoder) ![]u8 {
        if (self.consumed > 0) {
            const left = self.used - self.consumed;
            std.mem.copyForwards(u8, self.bytes[0..left], self.bytes[self.consumed..self.used]);
            self.used = left;
            self.consumed = 0;
        }
        if (self.used == self.bytes.len) return error.InputSequenceTooLong;
        return self.bytes[self.used..];
    }
    pub fn added(self: *Decoder, count: usize) void {
        std.debug.assert(count <= self.bytes.len - self.used);
        self.used += count;
    }
    pub fn next(self: *Decoder) !?vaxis.Event {
        while (self.consumed < self.used) {
            const pending = self.remaining();
            // The parser's grapheme lookahead must never see an incomplete
            // codepoint, even after a complete first character. Retain its
            // at-most-three trailing bytes for the next read.
            const complete = completeUtf8Prefix(pending);
            if (complete == 0 or (complete == 1 and pending[0] == 0x1b and complete < pending.len)) return null;
            const parsed = self.parser.parse(pending[0..complete], null) catch |err| {
                if (!malformedInput(err)) return err;
                // Reject malformed input one byte at a time; valid suffix
                // text is not discarded with an unrelated bad prefix.
                self.consumed += 1;
                continue;
            };
            if (parsed.n == 0) return null;
            if (parsed.n > complete) return error.InvalidParserLength;
            self.consumed += parsed.n;
            if (parsed.event) |event| return event;
        }
        self.used = 0;
        self.consumed = 0;
        return null;
    }
};

pub fn Loop(comptime Event: type) type {
    return struct {
        const Self = @This();
        // Queue entries own text. The upstream 8KiB rotating cache is not a
        // lifetime guarantee for many long graphemes waiting in a full queue.
        const Item = struct { event: Event, text: ?[]const u8 = null };

        io: std.Io,
        allocator: std.mem.Allocator,
        tty: *vaxis.Tty,
        vaxis: *vaxis.Vaxis,
        queue: vaxis.Queue(Item, 512),
        thread: ?std.Io.Future(void) = null,
        cache: vaxis.GraphemeCache = .{},
        consumer_text: ?[]const u8 = null,
        resize_installed: bool = false,

        /// Initialize heap storage in place; never return the fixed queue or
        /// its containing loop by value through the runtime task stack.
        pub fn init(self: *Self, io: std.Io, allocator: std.mem.Allocator, tty: *vaxis.Tty, vx: *vaxis.Vaxis) void {
            self.io = io;
            self.allocator = allocator;
            self.tty = tty;
            self.vaxis = vx;
            self.queue.read_index = 0;
            self.queue.write_index = 0;
            self.queue.closed = null;
            self.queue.io = io;
            self.queue.mutex = .init;
            self.queue.not_full = .init;
            self.queue.not_empty = .init;
            self.thread = null;
            self.cache = .{};
            self.consumer_text = null;
            self.resize_installed = false;
        }
        fn owned(self: *Self, event: Event) !Item {
            var item: Item = .{ .event = event };
            switch (event) {
                .key_press => |key| if (key.text) |bytes| {
                    if (bytes.len > capacity) return error.InputSequenceTooLong;
                    if (bytes.len > 0) item.text = try self.allocator.dupe(u8, bytes);
                    item.event.key_press.text = null;
                },
                else => {},
            }
            return item;
        }
        fn release(self: *Self, item: Item) void {
            if (item.text) |text| self.allocator.free(text);
        }
        pub fn postEvent(self: *Self, event: Event) !void {
            const item = try self.owned(event);
            errdefer self.release(item);
            try self.queue.push(item);
        }
        pub fn tryPostEvent(self: *Self, event: Event) !bool {
            const item = try self.owned(event);
            errdefer self.release(item);
            if (try self.queue.tryPush(item)) return true;
            self.release(item);
            return false;
        }
        pub fn nextEvent(self: *Self) !Event {
            self.releaseConsumer();
            const item = try self.queue.pop();
            var event = item.event;
            if (item.text) |text| {
                self.consumer_text = text;
                event.key_press.text = text;
            }
            return event;
        }
        fn releaseConsumer(self: *Self) void {
            if (self.consumer_text) |text| self.allocator.free(text);
            self.consumer_text = null;
        }
        fn resizeHandler(self: *Self) vaxis.Tty.SignalHandler {
            return .{ .context = self, .callback = Self.winsizeCallback };
        }
        pub fn installResizeHandler(self: *Self) !void {
            if (!builtin.is_test and !self.resize_installed) {
                try vaxis.Tty.notifyWinsize(self.resizeHandler());
                self.resize_installed = true;
            }
        }
        pub fn uninstallResizeHandler(self: *Self) void {
            if (!builtin.is_test and self.resize_installed) {
                vaxis.Tty.removeWinsize(self.resizeHandler());
                self.resize_installed = false;
            }
        }
        pub fn winsizeCallback(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.vaxis.state.in_band_resize) return;
            const size = self.tty.getWinsize() catch return;
            _ = self.tryPostEvent(.{ .winsize = size }) catch {};
        }
        pub fn start(self: *Self) !void {
            if (self.thread != null) return;
            self.queue.reopen();
            errdefer self.queue.close(error.Closed);
            self.thread = try self.io.concurrent(readInput, .{self});
        }
        pub fn stop(self: *Self) void {
            self.queue.close(error.Closed);
            if (self.thread) |*thread| thread.cancel(self.io);
            self.thread = null;
            // Closing rejects every producer before draining. Join the input
            // task first, then discard queued keys so editor return cannot
            // replay input from before terminal takeover.
            self.queue.mutex.lockUncancelable(self.io);
            while (self.queue.drain()) |item| self.release(item);
            self.queue.mutex.unlock(self.io);
            self.releaseConsumer();
        }
        pub fn deinit(self: *Self) void {
            self.stop();
            self.uninstallResizeHandler();
        }
        fn readInput(self: *Self) void {
            self.read() catch |err| self.queue.close(if (err == error.Canceled) error.Closed else err);
        }
        fn read(self: *Self) !void {
            if (builtin.is_test) return;
            try self.postEvent(.{ .winsize = try self.tty.getWinsize() });
            var decoder: Decoder = .{ .parser = .{ .cursor_position_requests = &self.vaxis.cursor_position_requests } };
            var retries: u8 = 0;
            while (true) {
                try self.io.checkCancel();
                const target = try decoder.writable();
                const count = self.tty.read(target) catch |err| {
                    switch (err) {
                        error.WouldBlock, error.InputOutput, error.SystemResources => {},
                        else => return err,
                    }
                    if (retries == 8) return err;
                    const delay = @min(@as(u32, 10) << @intCast(retries), 250);
                    retries += 1;
                    try self.io.sleep(.fromMilliseconds(delay), .awake);
                    continue;
                };
                if (count == 0) return error.EndOfStream;
                retries = 0;
                decoder.added(count);
                while (decoder.remaining().len > 0) {
                    const pending = decoder.remaining();
                    if (pending.len == 1 and pending[0] == 0x1b) {
                        var polls = [1]std.posix.pollfd{.{ .fd = self.tty.fd.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                        _ = std.posix.poll(&polls, 0) catch 0;
                        if (polls[0].revents & std.posix.POLL.IN != 0) break;
                    }
                    const event = try decoder.next() orelse break;
                    try vaxis.loop.handleEventGeneric(self, self.vaxis, &self.cache, Event, event, null);
                }
            }
        }
    };
}

fn collect(decoder: *Decoder, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    while (try decoder.next()) |event| switch (event) {
        .key_press => |key| if (key.text) |text| try output.appendSlice(allocator, text),
        else => {},
    };
}

test "UTF8 decoder retains every split of two three and four byte codepoints" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "é", "界", "👋" }) |text| {
        for (1..text.len) |split| {
            var decoder: Decoder = .{};
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(allocator);
            @memcpy((try decoder.writable())[0..split], text[0..split]);
            decoder.added(split);
            try collect(&decoder, allocator, &output);
            try std.testing.expectEqual(@as(usize, 0), output.items.len);
            const tail = text.len - split;
            @memcpy((try decoder.writable())[0..tail], text[split..]);
            decoder.added(tail);
            try collect(&decoder, allocator, &output);
            try std.testing.expectEqualStrings(text, output.items);
        }
    }
}

test "UTF8 decoder preserves emoji crossing the original1024 byte witness" {
    const allocator = std.testing.allocator;
    var expected: [1027]u8 = undefined;
    @memset(expected[0..1022], 'a');
    @memcpy(expected[1022..1026], "👋");
    expected[1026] = 'z';
    var decoder: Decoder = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    @memcpy(try decoder.writable(), expected[0..1024]);
    decoder.added(1024);
    try collect(&decoder, allocator, &output);
    try std.testing.expectEqual(@as(usize, 1022), output.items.len);
    @memcpy((try decoder.writable())[0..3], expected[1024..]);
    decoder.added(3);
    try collect(&decoder, allocator, &output);
    try std.testing.expectEqualSlices(u8, &expected, output.items);
}

test "grapheme lookahead sees only complete UTF8 with a fragmented suffix" {
    const allocator = std.testing.allocator;
    const prefix = "é界";
    const emoji = "👋";
    for (1..emoji.len) |split| {
        var decoder: Decoder = .{};
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        const target = try decoder.writable();
        @memcpy(target[0..prefix.len], prefix);
        @memcpy(target[prefix.len..][0..split], emoji[0..split]);
        decoder.added(prefix.len + split);
        try collect(&decoder, allocator, &output);
        try std.testing.expectEqualStrings(prefix, output.items);
        const tail = emoji.len - split;
        @memcpy((try decoder.writable())[0..tail], emoji[split..]);
        decoder.added(tail);
        try collect(&decoder, allocator, &output);
        try std.testing.expectEqualStrings(prefix ++ emoji, output.items);
    }
}

test "input queue owns text and releases rejected queued and consumed events" {
    const allocator = std.testing.allocator;
    const TestEvent = union(enum) { key_press: vaxis.Key, winsize: vaxis.Winsize };
    const TestLoop = Loop(TestEvent);
    // A fixed text array per entry made by-value initialization exceed the
    // runtime stack. Queue descriptors remain small; text belongs to the heap.
    try std.testing.expect(@sizeOf(TestLoop) < 128 * 1024);
    var tty: vaxis.Tty = undefined;
    var vx: vaxis.Vaxis = undefined;
    const loop = try allocator.create(TestLoop);
    defer allocator.destroy(loop);
    loop.init(std.testing.io, allocator, &tty, &vx);
    defer loop.deinit();
    var source = "mail".*;
    const event: TestEvent = .{ .key_press = .{ .codepoint = 'm', .text = &source } };
    try loop.postEvent(event);
    source[0] = 'x';
    const consumed = try loop.nextEvent();
    try std.testing.expectEqualStrings("mail", consumed.key_press.text.?);
    for (0..512) |_| try std.testing.expect(try loop.tryPostEvent(event));
    try std.testing.expect(!try loop.tryPostEvent(event));
    try std.testing.expectEqualStrings("mail", consumed.key_press.text.?);
    loop.stop();
    try std.testing.expect(loop.consumer_text == null);
    try std.testing.expectError(error.Closed, loop.nextEvent());
    try std.testing.expectError(error.Closed, loop.postEvent(event));
    try std.testing.expectError(error.Closed, loop.tryPostEvent(event));
    loop.queue.reopen();
    try loop.postEvent(event);
    const restarted = try loop.nextEvent();
    try std.testing.expectEqualStrings("xail", restarted.key_press.text.?);
    try std.testing.expect(try loop.queue.isEmpty());
}

test "mouse reports keep zero based coordinates buttons and release across fragments" {
    var decoder: Decoder = .{};
    const first = "\x1b[<0;30;";
    @memcpy((try decoder.writable())[0..first.len], first);
    decoder.added(first.len);
    try std.testing.expect((try decoder.next()) == null);
    const second = "7M\x1b[<0;30;7m\x1b[<65;90;8M";
    @memcpy((try decoder.writable())[0..second.len], second);
    decoder.added(second.len);
    const press = (try decoder.next()).?.mouse;
    try std.testing.expectEqual(vaxis.Mouse.Type.press, press.type);
    try std.testing.expectEqual(vaxis.Mouse.Button.left, press.button);
    try std.testing.expectEqual(@as(i16, 29), press.col);
    try std.testing.expectEqual(@as(i16, 6), press.row);
    const released = (try decoder.next()).?.mouse;
    try std.testing.expectEqual(vaxis.Mouse.Type.release, released.type);
    const wheel = (try decoder.next()).?.mouse;
    try std.testing.expectEqual(vaxis.Mouse.Button.wheel_down, wheel.button);
    try std.testing.expectEqual(@as(i16, 89), wheel.col);
    try std.testing.expect((try decoder.next()) == null);
}
