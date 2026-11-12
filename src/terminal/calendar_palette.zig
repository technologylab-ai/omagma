//! Calendar-only presentation. Source identities and saved color roles remain
//! untouched, and Classic delegates to the previous color calculations.
const std = @import("std");
const theme = @import("theme.zig");
const sources = @import("calendar_sources.zig");
const grid = @import("calendar_grid.zig");
pub const Rgb = theme.Color;

pub const Mode = enum { orange_blue, classic_pastel };
pub fn name(mode: Mode) []const u8 {
    return switch (mode) {
        .orange_blue => "Orange & Blue",
        .classic_pastel => "Classic",
    };
}
pub const Context = struct {
    look: Mode = .orange_blue,
    theme_mode: theme.Mode = .omagma,
    monochrome: bool = false,

    pub fn enabled(self: Context) bool {
        return self.look == .orange_blue and self.theme_mode == .omagma and !self.monochrome;
    }
};
pub const selection: Rgb = .{ 32, 70, 128 };
pub const event_fill: Rgb = .{ 34, 46, 68 };
pub const quiet_fill: Rgb = .{ 26, 34, 50 };
pub const today_ground: Rgb = .{ 21, 28, 42 };
pub const weekend_ground: Rgb = .{ 14, 18, 27 };

fn sourcePalette(base: theme.Palette) theme.Palette {
    var result = base;
    result.green = .{ 64, 196, 184 };
    result.magenta = .{ 168, 140, 255 };
    result.blue = .{ 82, 120, 255 };
    return result;
}
/// Use only while drawing Calendar; never replace the saved/global mail theme.
pub fn palette(base: theme.Palette, context: Context) theme.Palette {
    if (!context.enabled()) return base;
    var result = sourcePalette(base);
    result.selection = selection;
    // Keep the existing text floor rather than weakening the derived muted
    // selection role to the new surface's lower unadjusted contrast.
    result.selected_muted = grid.inkOn(base.muted, selection, base.foreground, theme.text_floor);
    return result;
}
pub fn sourceRgb(role: sources.Color, base: theme.Palette, context: Context) Rgb {
    return sources.readableRgb(role, if (context.enabled()) sourcePalette(base) else base);
}
pub const Badge = struct { ink: Rgb, fill: Rgb };
/// A selected Agenda source letter becomes a solid source-color chip.
pub fn selectedBadge(source: Rgb, base: theme.Palette) Badge {
    const solid = grid.selectedColors(source, base.background, base.foreground);
    return .{ .ink = solid.ink, .fill = solid.fill };
}

pub fn dayGround(base: theme.Palette, context: Context, today: bool, weekend: bool) Rgb {
    if (context.enabled()) return if (today) today_ground else if (weekend) weekend_ground else base.background;
    return if (today) grid.mix(base.background, base.accent, 6) else if (weekend) grid.mix(base.background, base.foreground, 4) else base.background;
}
pub const State = struct {
    selected: bool = false,
    placeholder: bool = false,
    declined: bool = false,
    pending: bool = false,
    tentative: bool = false,
    past: bool = false,
    stale: bool = false,
};
pub const Block = struct { ink: Rgb, fill: Rgb, bar: Rgb };
/// Returns colors only. Existing response glyphs, italic/strike cues, hatch,
/// source letters, hit targets and red now-line overlay stay with the TUI.
pub fn block(source: Rgb, base: theme.Palette, ground: Rgb, state: State, context: Context) Block {
    if (state.selected) {
        const solid = grid.selectedColors(source, base.background, base.foreground);
        return .{ .ink = solid.ink, .fill = solid.fill, .bar = solid.ink };
    }
    const quiet = state.declined or state.placeholder or state.past or state.stale;
    if (!context.enabled()) {
        const unfilled = state.declined or state.pending;
        const percent: u8 = if (unfilled) 0 else if (state.placeholder) 12 else if (state.tentative) 16 else if (state.past) 18 else 32;
        const fill = if (unfilled) ground else grid.readableFill(source, base.background, base.foreground, percent, grid.text_floor);
        const ink = if (quiet) grid.inkOn(base.muted, fill, base.foreground, grid.quiet_floor) else if (state.pending) grid.inkOn(source, fill, base.foreground, grid.quiet_floor) else base.foreground;
        return .{ .ink = ink, .fill = fill, .bar = if (state.declined) base.muted else source };
    }
    // Neutral blue surfaces avoid the brown produced by orange/yellow tints.
    // Selected blocks retain their source identity as an actual solid color.
    const fill = if (state.placeholder or state.declined or state.pending) ground else if (state.tentative or state.past or state.stale) quiet_fill else event_fill;
    const ink = if (quiet) grid.inkOn(base.muted, fill, base.foreground, grid.quiet_floor) else base.foreground;
    const edge = if (state.declined) base.muted else if (state.placeholder) base.orange else source;
    return .{ .ink = ink, .fill = fill, .bar = grid.inkOn(edge, fill, base.foreground, grid.quiet_floor) };
}

test "calendar palette: Classic and other themes preserve source colors and event calculations" {
    const base: theme.Palette = .{};
    const contexts = [_]Context{
        .{ .look = .classic_pastel },
        .{ .theme_mode = .follow_omarchy },
        .{ .monochrome = true },
    };
    for (contexts) |context| {
        try std.testing.expect(!context.enabled());
        try std.testing.expectEqualDeep(base, palette(base, context));
        for (std.enums.values(sources.Color)) |role| {
            const source = sources.readableRgb(role, base);
            try std.testing.expectEqual(source, sourceRgb(role, base, context));
            const ground = grid.mix(base.background, base.accent, 6);
            try std.testing.expectEqual(ground, dayGround(base, context, true, true));
            for ([_]State{ .{}, .{ .tentative = true }, .{ .past = true }, .{ .placeholder = true }, .{ .declined = true }, .{ .pending = true }, .{ .stale = true } }) |state| {
                const percent: u8 = if (state.declined or state.pending) 0 else if (state.placeholder) 12 else if (state.tentative) 16 else if (state.past) 18 else 32;
                const expected_fill = if (state.declined or state.pending) ground else grid.readableFill(source, base.background, base.foreground, percent, grid.text_floor);
                const result = block(source, base, ground, state, context);
                try std.testing.expectEqual(expected_fill, result.fill);
                const quiet = state.declined or state.placeholder or state.past or state.stale;
                const expected_ink = if (quiet) grid.inkOn(base.muted, expected_fill, base.foreground, grid.quiet_floor) else if (state.pending) grid.inkOn(source, expected_fill, base.foreground, grid.quiet_floor) else base.foreground;
                try std.testing.expectEqual(expected_ink, result.ink);
            }
        }
    }
}

test "calendar palette: Orange and Blue surfaces preserve contrast and the red now line" {
    const base: theme.Palette = .{};
    const context: Context = .{};
    const colors = palette(base, context);
    try std.testing.expectEqual(base.red, colors.red);
    try std.testing.expectEqual(base.background, colors.background);
    try std.testing.expect(grid.contrast(colors.selected_muted, colors.selection) >= theme.text_floor);
    for ([_]Rgb{ event_fill, quiet_fill, selection }) |fill| {
        try std.testing.expect(fill[2] > fill[0] and fill[2] > fill[1]);
        try std.testing.expect(grid.contrast(base.foreground, fill) >= grid.text_floor);
    }
    for (std.enums.values(sources.Color)) |role| {
        const source = sourceRgb(role, base, context);
        try std.testing.expect(grid.contrast(source, base.background) >= grid.quiet_floor);
        for ([_]State{ .{}, .{ .tentative = true }, .{ .past = true }, .{ .placeholder = true }, .{ .declined = true }, .{ .pending = true }, .{ .stale = true }, .{ .selected = true } }) |state| {
            const ground = dayGround(base, context, true, true);
            const result = block(source, base, ground, state, context);
            const floor: f64 = if (state.selected or (!state.past and !state.placeholder and !state.declined and !state.stale)) grid.text_floor else grid.quiet_floor;
            try std.testing.expect(grid.contrast(result.ink, result.fill) >= floor);
            try std.testing.expect(grid.contrast(result.bar, result.fill) >= grid.quiet_floor);
            if (state.declined or state.pending or state.placeholder) try std.testing.expectEqual(ground, result.fill);
        }
        const badge = selectedBadge(source, base);
        try std.testing.expect(grid.contrast(badge.ink, badge.fill) >= grid.text_floor);
    }
}
