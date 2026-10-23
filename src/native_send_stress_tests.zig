//! The complete growing-conversation regression has its own mandatory native
//! target and bounded deadline. Its build filter excludes other imported test
//! declarations; it never depends on another test's process, cache or order.
const scenarios = @import("session_cache_integration_tests.zig");

test "native growing thread stress: twenty further illustrated replies capture review save and upload near the MIME ceiling" {
    try scenarios.growingNativeThreadScenario();
}
