//! Extra correctness suites share one compilation and one instance of each
//! imported module's tests. Application/TUI tests and the LLVM worker-stack
//! regression remain separate roots; long native stress suites stay opt-in.
test {
    _ = @import("terminal_codec_tests.zig");
    _ = @import("terminal_provider_tests.zig");
    _ = @import("terminal_mail_acceptance_tests.zig");
    _ = @import("terminal_ux_backend_tests.zig");
    _ = @import("terminal_ux_helper_tests.zig");
    _ = @import("platform_tests.zig");
    _ = @import("updates_tests.zig");
    _ = @import("calendar_tests.zig");
    _ = @import("calendar_service_tests.zig");
    _ = @import("calendar_native_tests.zig");
    _ = @import("calendar_commands_tests.zig");
    _ = @import("calendar_embedded_tests.zig");
    _ = @import("calendar_duration_tests.zig");
    _ = @import("calendar_fixture_tests.zig");
    _ = @import("calendar_store_tests.zig");
    _ = @import("calendar_identity_history_tests.zig");
    _ = @import("calendar_vault_grants_tests.zig");
    _ = @import("vault_crypto_tests.zig");
    _ = @import("vault_storage_tests.zig");
    _ = @import("vault_catalog_tests.zig");
    _ = @import("vault_store_tests.zig");
    _ = @import("retained_history_tests.zig");
    _ = @import("native_capacity_tests.zig");
    _ = @import("vault_mail_tests.zig");
    _ = @import("vault_daemon_tests.zig");
    _ = @import("vault_identity_tests.zig");
    _ = @import("vault_activation_tests.zig");
    _ = @import("vault_migration_tests.zig");
    _ = @import("vault_migration_store_tests.zig");
    _ = @import("session_cache_integration_tests.zig");
    _ = @import("draft_continuity_tests.zig");
}
