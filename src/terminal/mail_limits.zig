//! Mail metadata policy shared by receive, compose, retained originals and
//! browser policy export. All sizes count UTF-8 bytes, not characters.
pub const display_name_bytes: usize = 1024;
pub const incoming_address_bytes: usize = 1024;
pub const outgoing_address_bytes: usize = 512;
/// Preserve a full 16 KiB subject when reply/forward prefixes are added.
pub const subject_text_bytes: usize = 16 * 1024;
pub const subject_prefix_bytes: usize = 16;
pub const subject_bytes: usize = subject_text_bytes + subject_prefix_bytes;
pub const filename_bytes: usize = 512;
/// Cosmetic preview only; clipping never discards the full message body.
pub const snippet_bytes: usize = 16 * 1024;
/// Unfolded wire value. Physical folding bytes consume the aggregate budget.
pub const header_value_bytes: usize = 64 * 1024;
pub const headers_bytes: usize = 128 * 1024;
pub const header_count: usize = 256;
pub const reference_count: usize = 256;
pub const references_bytes: usize = 64 * 1024;
/// "In-Reply-To: " plus this many bytes fits the 998-byte physical line limit.
pub const message_id_bytes: usize = 985;
/// Per received address header, independently of the outgoing SMTP quota.
pub const incoming_recipients: usize = 1024;

/// Serializable data, so browser policy can be compared with the native one.
pub const manifest = .{
    .displayNameBytes = display_name_bytes,
    .incomingAddressBytes = incoming_address_bytes,
    .outgoingAddressBytes = outgoing_address_bytes,
    .subjectTextBytes = subject_text_bytes,
    .subjectPrefixBytes = subject_prefix_bytes,
    .subjectBytes = subject_bytes,
    .filenameBytes = filename_bytes,
    .snippetBytes = snippet_bytes,
    .headerValueBytes = header_value_bytes,
    .headersBytes = headers_bytes,
    .headerCount = header_count,
    .referenceCount = reference_count,
    .referencesBytes = references_bytes,
    .messageIdBytes = message_id_bytes,
    .incomingRecipients = incoming_recipients,
};
