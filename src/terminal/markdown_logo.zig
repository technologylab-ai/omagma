//! Exact approved public assets/omagma-logo.png, copied beside the renderer so
//! main and standalone Zig test module roots can embed the same trusted bytes.
//! SHA-256: e2e844a35476454f11b513404041135327fec6354f7b6e7e0269a32fdf56d3c4
//! This fixed branding part is not a user attachment or remote tracking image.
pub const png = @embedFile("omagma-logo.png");
pub const content_id = "omagma-logo@omagma.invalid";
pub const max_bytes = 16 * 1024;
comptime {
    if (png.len > max_bytes) @compileError("Approved inline logo exceeds its fixed allowance");
}
