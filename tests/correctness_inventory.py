#!/usr/bin/env python3
"""Offline inventory oracle for the independently retained correctness roots."""
from collections import Counter
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Independent copy of the pre-aggregation build inventory. Keep every former
# extra root here so an accidentally dropped or repeated import fails cheaply.
EXTRA_ROOTS = (
    "terminal_codec_tests.zig",
    "terminal_provider_tests.zig",
    "terminal_mail_acceptance_tests.zig",
    "terminal_ux_backend_tests.zig",
    "terminal_ux_helper_tests.zig",
    "platform_tests.zig",
    "updates_tests.zig",
    "calendar_tests.zig",
    "calendar_service_tests.zig",
    "calendar_native_tests.zig",
    "calendar_commands_tests.zig",
    "calendar_embedded_tests.zig",
    "calendar_duration_tests.zig",
    "calendar_fixture_tests.zig",
    "calendar_store_tests.zig",
    "calendar_identity_history_tests.zig",
    "calendar_vault_grants_tests.zig",
    "vault_crypto_tests.zig",
    "vault_storage_tests.zig",
    "vault_catalog_tests.zig",
    "vault_store_tests.zig",
    "retained_history_tests.zig",
    "native_capacity_tests.zig",
    "vault_mail_tests.zig",
    "vault_daemon_tests.zig",
    "vault_identity_tests.zig",
    "vault_activation_tests.zig",
    "vault_migration_tests.zig",
    "vault_migration_store_tests.zig",
    "session_cache_integration_tests.zig",
    "draft_continuity_tests.zig",
)

HISTORY_CASES = {
    "calendar": "native history stress: 1001 Calendar imports retain revisions and cancelled fences in both stores",
    "sends-plain": "native history stress: 1001 production sends survive restart and replay in plaintext",
    "sends-vault": "native history stress: 1001 production sends survive restart and replay in encrypted vault",
    "files-plain": "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in plaintext",
    "files-vault": "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in encrypted vault",
}


class CorrectnessInventory(unittest.TestCase):
    def test_all_31_previous_extra_roots_are_imported_once(self):
        aggregate = (ROOT / "src/correctness_tests.zig").read_text()
        imports = re.findall(r'@import\("([^"\n]+)"\)', aggregate)
        self.assertEqual(len(EXTRA_ROOTS), 31)
        self.assertEqual(Counter(imports), Counter(EXTRA_ROOTS))
        for name in imports:
            self.assertTrue((ROOT / "src" / name).is_file(), name)

    def test_default_test_retains_all_three_named_gates(self):
        build = (ROOT / "build.zig").read_text()
        ordinary = build.split('const correctness =', 1)[1].split('const send_stress =', 1)[0]
        for variable, step in (("main_correctness", "test-main"),
                               ("extra_correctness", "test-extra"),
                               ("memory_correctness", "test-native-memory")):
            self.assertEqual(ordinary.count(f'b.step("{step}",'), 1)
            self.assertEqual(ordinary.count(f'correctness.dependOn({variable});'), 1)
        for root in ("src/correctness_tests.zig", "src/native_memory_ux_tests.zig"):
            self.assertEqual(ordinary.count(f'b.path("{root}")'), 1)
        for root in EXTRA_ROOTS:
            self.assertNotIn(f'b.path("src/{root}")', ordinary)
        memory = ordinary.split('const memory_tests =', 1)[1]
        self.assertIn('.use_llvm = true', memory)
        for artifact in ("t", "extra_tests", "memory_tests"):
            self.assertEqual(ordinary.count(f'guardedTestRun(b, {artifact}, test_watchdog)'), 1)

    def test_history_selector_preserves_exactly_five_lifecycles(self):
        build = (ROOT / "build.zig").read_text()
        self.assertRegex(build, r'b\.option\(HistoryCase, "history-case",[^\n]+\) orelse \.all;')
        stress = build.split('const history_stress =', 1)[1].split('const prepare_tests =', 1)[0]
        self.assertIn('.filters = &.{"native history stress:"}', stress)
        self.assertIn('prependRunEnvironment(b, history_run, "OMAGMA_HISTORY_CASE", @tagName(history_case));', stress)
        self.assertNotIn("setEnvironmentVariable(", build)
        self.assertEqual(build.count("history_case"), 2, "Runtime selection must not change compilation inputs")
        wrapper = (ROOT / "src/native_history_stress_tests.zig").read_text()
        tests = re.findall(r'^test "(native history stress:[^"]+)" \{\n    try selected\(\.(?:@"([^"]+)"|(\w+))\);',
                           wrapper, re.MULTILINE)
        self.assertEqual(len(tests), 5)
        self.assertEqual({quoted or plain: name for name, quoted, plain in tests}, HISTORY_CASES)
        self.assertIn('std.testing.environ.getPosix("OMAGMA_HISTORY_CASE") orelse "all"', wrapper)
        self.assertIn('std.meta.stringToEnum(HistoryCase, raw) orelse return error.InvalidHistoryCase', wrapper)

    def test_prepare_compiles_all_11_test_artifacts_without_running_them(self):
        build = (ROOT / "build.zig").read_text()
        prepare = build.split('const prepare_tests =', 1)[1].split('const probes =', 1)[0]
        self.assertIn('b.step("prepare-tests",', prepare)
        inventory = re.search(r'for \(\[_\]\*std\.Build\.Step\.Compile\{([^}]+)\}\)', prepare)[1]
        artifacts = [name.strip() for name in inventory.split(',')]
        expected = ("t", "extra_tests", "memory_tests", "browser_export_tests", "browser_server_tests",
                    "browser_cache_tests", "browser_provider_tests", "contact_isolation_tests", "mailbox_tests",
                    "send_stress", "history_stress")
        self.assertEqual(Counter(artifacts), Counter(expected))
        self.assertEqual(prepare.count("prepare_tests.dependOn(&artifact.step);"), 1)
        for execution in ("guardedTestRun(", "addRunArtifact(", "addSystemCommand("):
            self.assertNotIn(execution, prepare)

    def test_guarded_tests_always_execute_after_restoring_compile_cache(self):
        build = (ROOT / "build.zig").read_text()
        run = build.split("pub fn guardedTestRun(", 1)[1].split("fn embeddedAssetSource(", 1)[0]
        before_watchdog = run.split("if (enabled)", 1)[0]
        self.assertIn("run.has_side_effects = true;", before_watchdog)

    def test_prepare_history_compiles_only_the_shared_history_artifact(self):
        build = (ROOT / "build.zig").read_text()
        prepare = build.split('const prepare_history =', 1)[1].split('const probes =', 1)[0]
        self.assertIn('b.step("prepare-history",', prepare)
        self.assertEqual(re.findall(r'prepare_history\.dependOn\(&([^)]+)\);', prepare),
                         ["history_stress.step"])
        self.assertEqual(prepare.count(".dependOn("), 1)
        for execution in ("guardedTestRun(", "addRunArtifact(", "addSystemCommand("):
            self.assertNotIn(execution, prepare)

    def test_public_selector_prefix_keeps_the_current_worker_environment(self):
        build = (ROOT / "build.zig").read_text()
        prefix = build.split("pub fn prependRunEnvironment(", 1)[1].split("fn embeddedAssetSource(", 1)[0]
        self.assertIn("std.debug.assert(run.environ_map == null);", prefix)
        self.assertIn("run.argv.toOwnedSlice(b.allocator)", prefix)
        self.assertIn('run.addArg("/usr/bin/env");', prefix)
        self.assertIn('run.addArg(b.fmt("{s}={s}", .{ name, value }));', prefix)
        self.assertIn("run.argv.appendSlice(b.allocator, original)", prefix)
        self.assertNotRegex(prefix, r"run\.(?:environ_map|stdio)\s*=(?!=)")
        self.assertNotIn("getEnvMap(", prefix)


if __name__ == "__main__":
    unittest.main()
