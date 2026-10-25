//! Long retained-history lifecycles have a mandatory native target and a
//! separate bounded per-test deadline. The build filter excludes imported
//! ordinary tests, so each qualification mode runs every lifecycle once.
const mail = @import("session_cache_integration_tests.zig");
const calendar = @import("calendar_identity_history_tests.zig");

test "native history stress: 1001 Calendar imports retain revisions and cancelled fences in both stores" {
    try calendar.thousandCalendarIdentityScenario();
}

test "native history stress: 1001 production sends survive restart and replay in plaintext" {
    try mail.retainedSendLifecycle(false, false);
}

test "native history stress: 1001 production sends survive restart and replay in encrypted vault" {
    try mail.retainedSendLifecycle(true, false);
}

test "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in plaintext" {
    try mail.retainedSendLifecycle(false, true);
}

test "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in encrypted vault" {
    try mail.retainedSendLifecycle(true, true);
}
