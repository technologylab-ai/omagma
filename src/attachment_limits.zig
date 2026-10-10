//! Incoming file content is streamed separately from ordinary JSON and MIME
//! text. The wire budget includes padded base64 and bounded JSON framing.
pub const incoming_bytes: usize = 50 * 1024 * 1024;
pub const download_json_bytes: usize = ((incoming_bytes + 2) / 3) * 4 + 64 * 1024;
/// One explicit incoming-file job, including any permitted 401 refresh/retry.
pub const download_seconds: i64 = 180;
