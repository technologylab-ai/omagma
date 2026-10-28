#!/usr/bin/env python3
"""Offline promotion policy oracles; no GitHub calls or publishing."""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_qualification", ROOT / ".github/verify_qualification.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
REPOSITORY = "example/omagma"
SHA = "a" * 40
RUN_ID = 12345
NOW = datetime(2026, 10, 9, 19, 0, tzinfo=timezone.utc)


def fixture():
    workflow = {"id": 321, "name": "Release", "path": ".github/workflows/release.yml"}
    run = {"id": RUN_ID, "workflow_id": workflow["id"], "name": "Release", "path": workflow["path"],
           "head_branch": "main", "head_sha": SHA, "event": "push", "run_attempt": 2,
           "status": "completed", "conclusion": "success", "updated_at": "2026-10-09T18:30:00Z",
           "repository": {"id": 99, "full_name": REPOSITORY},
           "head_repository": {"id": 99, "full_name": REPOSITORY}}
    jobs = [{"id": 100 + index, "name": name, "run_id": RUN_ID, "run_attempt": 2, "head_sha": SHA,
             "status": "completed", "conclusion": "success", "started_at": "2026-10-09T18:00:00Z",
             "completed_at": "2026-10-09T18:20:00Z"} for index, name in enumerate(policy.PLATFORMS)]
    jobs += [{"id": 500 + index, "name": name, "run_id": RUN_ID, "run_attempt": 2, "head_sha": SHA,
              "status": "completed", "conclusion": "success", "started_at": "2026-10-09T18:20:00Z",
              "completed_at": "2026-10-09T18:25:00Z"} for index, name in enumerate(policy.COMPILE_JOBS)]
    jobs += [{"id": 1000 + index, "name": name, "run_id": RUN_ID, "run_attempt": 2, "head_sha": SHA,
              "status": "completed", "conclusion": "success", "started_at": "2026-10-09T18:25:00Z",
              "completed_at": "2026-10-09T18:29:00Z"} for index, name in enumerate(policy.GATE_JOBS)]
    artifacts = [{"id": 200 + index, "name": name, "expired": False, "size_in_bytes": 4096,
                  "created_at": "2026-10-09T18:15:00Z", "expires_at": "2026-11-08T18:15:00Z",
                  "workflow_run": {"id": RUN_ID, "repository_id": 99, "head_repository_id": 99,
                                   "head_branch": "main", "head_sha": SHA}}
                 for index, name in enumerate(policy.PLATFORMS.values())]
    return run, workflow, jobs, artifacts


def verify(data):
    return policy.verify(*data, repository=REPOSITORY, expected_sha=SHA, run_id=RUN_ID, now=NOW)


class Qualification(unittest.TestCase):
    def test_superseded_qualification_cancels_but_publication_is_protected(self):
        qualification = (ROOT / ".github/workflows/release.yml").read_text()
        promotion = (ROOT / ".github/workflows/publish-qualified.yml").read_text()
        self.assertIn("  cancel-in-progress: true", qualification.split("\njobs:", 1)[0])
        self.assertIn("  cancel-in-progress: false", promotion.split("\njobs:", 1)[0])

    def test_check_only_workflow_cannot_publish_and_promotion_is_manual(self):
        qualification = (ROOT / ".github/workflows/release.yml").read_text()
        for line in qualification.splitlines():
            if "scripts/publish_release.py" in line:
                self.assertIn("--check", line, "Qualification must never invoke the publisher")
        self.assertNotIn("contents: write", qualification)
        self.assertNotIn("uses: ./.github/workflows/homebrew.yml", qualification)
        promotion = (ROOT / ".github/workflows/publish-qualified.yml").read_text()
        triggers = promotion.split("\non:\n", 1)[1].split("\npermissions:\n", 1)[0]
        self.assertIn("workflow_dispatch:", triggers)
        for automatic in ("push:", "workflow_run:", "schedule:", "release:"):
            self.assertNotIn(automatic, triggers)
        self.assertIn("artifact-ids: ${{ needs.verify.outputs.artifact_ids }}", promotion)
        self.assertIn("run-id: ${{ needs.verify.outputs.run_id }}", promotion)
        self.assertIn("github-token: ${{ github.token }}", promotion)
        self.assertNotIn("pattern: release-*", promotion)

    def test_native_draft_acceptance_is_required_for_every_shipped_safe_binary(self):
        suites = ("compose_actions", "draft_conflict", "draft_paging", "quote_policy",
                  "reply_boundaries", "settled_recovery")
        release = (ROOT / ".github/workflows/release.yml").read_text().split("\n  compile:", 1)[0]
        for os_name, matrix in zip(("linux", "macos"), release.split("  macos-build:", 1)):
            binary = f"dist/omagma-{os_name}-${{{{ matrix.arch }}}}"
            steps = [step for step in matrix.split("      - name:")
                     if f"python3 tests/terminal_compose_actions.py --binary {binary}" in step]
            self.assertEqual(len(steps), 1)
            self.assertNotIn("if:", steps[0])
            self.assertNotIn("continue-on-error", steps[0])
            for suite in suites:
                self.assertIn(f"python3 tests/terminal_{suite}.py --binary {binary}", steps[0])
        native = (ROOT / ".github/workflows/macos-native.yml").read_text()
        for job in native.split("  native:", 1):
            for suite in suites:
                self.assertEqual(job.count(f"python3 tests/terminal_{suite}.py --binary "), 1)

    def test_complete_short_native_preflight_precedes_all_slow_qualification(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        preflight, heavy = release.split("\n  compile:", 1)
        prepared, heavy = heavy.split("\n  gates:", 1)
        gates, final = heavy.split("\n  qualified:", 1)
        self.assertIn("needs: [version, build, macos-build]", prepared)
        self.assertIn("name: Compile ${{ matrix.platform }}", prepared)
        self.assertIn("gate: compile", prepared)
        self.assertIn("platform: [linux-x86_64, linux-arm64, macos-arm64, macos-x86_64]", prepared)
        self.assertIn("uses: ./.github/workflows/native-gate.yml", prepared)
        self.assertNotIn("continue-on-error", prepared)
        self.assertIn("needs: [version, build, macos-build, compile]", gates)
        self.assertIn("needs: [version, build, macos-build, compile, gates]", final)
        self.assertIn("fail-fast: false", gates)
        self.assertIn("uses: ./.github/workflows/native-gate.yml", gates)
        self.assertIn("name: Gate ${{ matrix.platform }} ${{ matrix.gate }}", gates)
        self.assertNotIn("continue-on-error", gates)
        self.assertIn("platform: [linux-x86_64, linux-arm64, macos-arm64, macos-x86_64]", gates)
        matrix_gates = [line.strip().removeprefix("gate: [").removesuffix("]").split(", ")
                        for line in gates.splitlines() if line.strip().startswith("gate: [")]
        self.assertEqual(len(matrix_gates), 1)
        self.assertCountEqual(matrix_gates[0], policy.GATES)
        source_checks = preflight.split("\n  build:", 1)[0]
        # These platform-independent checks formerly lived inside Debug steps.
        for script in ("terminal_compose_screen", "terminal_fixture_check", "terminal_cache_fixture_check",
                       "terminal_screen", "terminal_ux_focus", "terminal_status_screen", "terminal_theme_screen",
                       "terminal_reader", "terminal_html_screen", "terminal_html_fixture_check",
                       "terminal_repaint_screen", "terminal_mouse_screen", "publication_gif", "homebrew_formula"):
            self.assertIn(f"python3 tests/{script}.py", source_checks)
        for matrix in preflight.split("  macos-build:", 1):
            self.assertIn("needs: version", matrix)
            commands = [line.strip().removeprefix("run: ") for line in matrix.splitlines()]
            slow = [command for command in commands if command.startswith((
                "zig build prepare-tests ", "zig build prepare-history ", "zig build test ",
                "zig build test-", "python3 tests/terminal_measure",
                "python3 tests/terminal_markdown_lifecycle.py", "python3 tests/measure.py ",
                "python3 tests/background_measure.py "))]
            self.assertEqual(slow, [], "All expensive qualification must depend on complete short preflight")
            self.assertNotIn("--resource-cycles 1000", matrix)
            prepared = [command for command in commands
                        if command.startswith(("zig build probes ", "zig build install probes "))]
            self.assertEqual(len(prepared), 1)
            self.assertIn("-Dtest-watchdog=true", prepared[0])
            self.assertIn("-Doptimize=safe", prepared[0])
            for script in ("terminal_compose_actions.py", "terminal_draft_conflict.py",
                           "terminal_draft_paging.py", "terminal_quote_policy.py",
                           "terminal_reply_boundaries.py", "terminal_settled_recovery.py",
                           "terminal_workflow_regressions.py"):
                self.assertEqual(matrix.count(f"python3 tests/{script} --binary "), 1, script)
        self.assertIn("node tests/ui_model.mjs", preflight)
        self.assertIn("python3 tests/terminal_mouse.py --binary dist/omagma-linux-", preflight)

    def test_ci_never_builds_debug_and_keeps_every_gate_mandatory(self):
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            text = workflow.read_text()
            self.assertNotIn("-Doptimize=debug", text, str(workflow))
            self.assertNotIn("--build-mode debug", text, str(workflow))
            self.assertNotIn("for mode in debug", text, str(workflow))
            self.assertNotIn(".verification-debug/", text, str(workflow))
            self.assertNotIn(".verification-macos-debug/", text, str(workflow))
            for line in text.splitlines():
                if "zig build " not in line:
                    continue
                if '-Doptimize="$mode"' in line:
                    self.assertIn("for mode in safe; do", text, str(workflow))
                else:
                    self.assertIn("-Doptimize=safe", line,
                                  f"CI build must select Safe explicitly: {workflow}")
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        self.assertIn("name: Check", gate)
        self.assertNotIn("continue-on-error", gate)
        self.assertNotIn("-Dtest-filter=", gate)

    def test_history_and_resource_shards_never_write_compilation_caches(self):
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        steps = gate.split("      - name:")
        writers = "(inputs.gate == 'compile' || startsWith(inputs.gate, 'unit-') || inputs.gate == 'adapters' || inputs.gate == 'send')"
        self.assertIn("CACHE_ROLE: ${{ (inputs.gate == 'compile' || startsWith(inputs.gate, 'history-')) && 'history' || inputs.gate }}", gate)
        local_restores = [step for step in steps if "actions/cache/restore@" in step
                          and "path: .zig-cache" in step]
        self.assertEqual(len(local_restores), 1)
        self.assertIn("${{ env.CACHE_ROLE }}-${{ github.sha }}-complete", local_restores[0])
        self.assertIn("${{ env.CACHE_ROLE }}-${{ github.sha }}-progress-", local_restores[0])
        self.assertIn("-history-${{ github.sha }}-complete", local_restores[0])
        self.assertNotIn("${{ inputs.gate }}", local_restores[0])
        local_saves = [step for step in steps if "actions/cache/save@" in step
                       and "path: .zig-cache" in step]
        self.assertEqual(len(local_saves), 2)
        for step in local_saves:
            self.assertIn(writers, step)
            self.assertIn("${{ env.CACHE_ROLE }}-${{ github.sha }}", step)
            self.assertNotIn("${{ inputs.gate }}", step)
        shared_saves = [step for step in steps if "actions/cache/save@" in step
                        and "path: .ci-zig/global" in step]
        self.assertEqual(len(shared_saves), 1)
        self.assertIn("if: success() && inputs.gate == 'compile'", shared_saves[0])
        complete = next(step for step in local_saves if "-complete" in step)
        partial = next(step for step in local_saves if "-progress-" in step)
        self.assertIn("if: success()", complete)
        self.assertIn("if: (failure() || cancelled())", partial)
        self.assertIn("${{ github.sha }}-progress-${{ github.run_id }}-${{ github.run_attempt }}", partial)
        cleanup = next(step for step in steps if "ci_cache_prepare.py --clean" in step)
        self.assertIn("if: always() && " + writers, cleanup)
        self.assertLess(gate.index(cleanup), gate.index(complete))
        self.assertLess(gate.index(cleanup), gate.index(partial))
        for workflow in ("macos-native.yml",):
            text = (ROOT / ".github/workflows" / workflow).read_text()
            self.assertNotIn("path: .zig-cache", text, workflow)
            self.assertNotIn("            .zig-cache\n", text, workflow)

    def test_preflight_build_cache_survives_harness_fixes_and_is_saved_before_tests(self):
        release = (ROOT / ".github/workflows/release.yml").read_text().split("\n  compile:", 1)[0]
        for job in release.split("  macos-build:", 1):
            steps = job.split("      - name:")
            restore = next(step for step in steps if "id: preflight-build-cache" in step)
            save = next(step for step in steps if "Save completed app and probe compilation" in step)
            self.assertIn("path: .zig-cache", restore)
            self.assertIn("${{ steps.cache-inputs.outputs.app_key }}", restore)
            self.assertNotIn("${{ github.sha }}", restore)
            self.assertNotIn("restore-keys:", restore)
            self.assertIn("steps.preflight-build-cache.outputs.cache-primary-key", save)
            self.assertLess(job.index("python3 tests/release_check.py"), job.index(save))
            self.assertLess(job.index(save), job.index("python3 tests/terminal_workflow_regressions.py"))
            self.assertLess(job.index("python3 .github/ci_cache_prepare.py --clean"), job.index(save))

    def test_restored_caches_have_required_empty_directories_before_zig_build(self):
        release = (ROOT / ".github/workflows/release.yml").read_text().split("\n  compile:", 1)[0]
        for job in release.split("  macos-build:", 1):
            repair = job.index("run: python3 .github/ci_cache_prepare.py\n")
            self.assertLess(job.index("id: preflight-build-cache"), repair)
            self.assertLess(repair, job.index("zig build "))
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        repair = gate.index("run: python3 .github/ci_cache_prepare.py\n")
        self.assertLess(gate.index("id: local-cache"), repair)
        self.assertLess(repair, gate.index("zig build prepare-history"))

    def test_resource_shards_reuse_the_bundle_and_preserve_every_existing_measurement(self):
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        self.assertIn("name: release-${{ inputs.platform }}", gate)
        self.assertIn("BINARY: dist/omagma-${{ inputs.platform }}", gate)
        self.assertNotIn("python3 scripts/release.py", gate, "A resource shard must not rebuild its candidate")
        check = gate.index('python3 tests/release_check.py --os "$RELEASE_OS" --arch "$RELEASE_ARCH"')
        self.assertLess(check, gate.index("python3 tests/terminal_html.py"))
        self.assertLess(check, gate.index("python3 tests/terminal_measure_macos.py"))
        resources = [step for step in gate.split("      - name:")
                     if "python3 tests/terminal_markdown_lifecycle.py" in step]
        self.assertEqual(len(resources), 2)
        for step, os_name in zip(resources, ("linux", "macos")):
            self.assertIn(f"if: inputs.gate == 'resources' && inputs.os == '{os_name}'", step)
            markdown = [line for line in step.splitlines() if "python3 tests/terminal_markdown_lifecycle.py" in line]
            self.assertEqual(len(markdown), 2)
            for kind, command in zip(("cli", "tui"), markdown):
                self.assertIn(f"--kind {kind}", command)
                self.assertIn("--cycles 1000 --warmup 100 --idle-seconds 60", command)
                self.assertIn('--binary "$BINARY"', command)
        linux, macos = resources
        self.assertEqual(linux.count("python3 tests/terminal_measure.py "), 2)
        self.assertIn("--resource-cycles 1000 --idle-seconds 60", linux)
        self.assertIn('python3 tests/measure.py --binary "$BINARY"', linux)
        self.assertIn("python3 tests/background_measure_check.py", linux)
        self.assertIn('python3 tests/background_measure.py --fixtures --config tests/fixtures/all-accounts.json --binary "$BINARY"', linux)
        native = [line for line in macos.splitlines() if "python3 tests/terminal_measure_macos.py" in line]
        self.assertEqual(len(native), 2)
        for kind, command in zip(("cli", "tui"), native):
            self.assertIn(f"--kind {kind}", command)
            self.assertIn("--cycles 1000 --warmup 100 --idle-seconds 60", command)

    def test_new_pty_suites_use_the_owned_darwin_guardian_factory(self):
        # Import all factories as Darwin without opening any PTY or desktop.
        # This catches accidentally binding the raw Linux-only factory again.
        import subprocess
        code = """import importlib, sys
sys.path.insert(0, 'tests')
sys.platform = 'darwin'
from terminal_macos import DarwinTerminal
for name in ('compose_actions', 'draft_conflict', 'draft_paging', 'quote_policy', 'settled_recovery'):
    module = importlib.import_module('terminal_' + name)
    assert issubclass(module.MouseTerminal, DarwinTerminal), name
"""
        subprocess.run([sys.executable, "-B", "-c", code], cwd=ROOT, check=True, timeout=10)

    def test_exact_candidate_produces_only_fixed_provenance_outputs(self):
        result = verify(fixture())
        self.assertEqual(result, {"run_id": RUN_ID, "head_sha": SHA, "run_attempt": 2,
                                 "workflow_id": 321, "artifact_ids": "200,201,202,203"})

    def test_whole_run_and_trusted_same_repository_main_source_required(self):
        mutations = (
            ("id", RUN_ID + 1), ("workflow_id", 322), ("name", "Untrusted workflow"),
            ("path", ".github/workflows/untrusted.yml"), ("head_branch", "feature"),
            ("head_sha", "b" * 40), ("event", "pull_request"), ("status", "in_progress"),
            ("conclusion", "failure"), ("conclusion", "cancelled"), ("conclusion", "neutral"),
            ("run_attempt", 0), ("run_attempt", True),
            ("repository", {"id": 99, "full_name": "foreign/project"}),
            ("head_repository", {"id": 98, "full_name": "fork/project"}),
            ("head_repository", {"id": 98, "full_name": REPOSITORY}),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                data = fixture()
                data[0][field] = value
                with self.assertRaises(policy.QualificationError):
                    verify(data)
        for field, value in (("path", ".github/workflows/untrusted.yml"), ("name", "Fake Release")):
            data = fixture()
            data[1][field] = value
            with self.assertRaises(policy.QualificationError):
                verify(data)

    def test_all_native_preflights_compile_jobs_and_gates_must_succeed(self):
        for index in range(len(fixture()[2])):
            for field, value in (("status", "queued"), ("conclusion", "failure"), ("conclusion", "skipped"),
                                 ("run_attempt", 3), ("run_attempt", 0), ("run_attempt", True),
                                 ("run_id", RUN_ID + 1), ("head_sha", "b" * 40),
                                 ("started_at", "2026-10-09T19:00:01Z"),
                                 ("completed_at", "2026-10-09T19:00:01Z")):
                with self.subTest(platform=index, field=field):
                    data = fixture()
                    data[2][index][field] = value
                    with self.assertRaises(policy.QualificationError):
                        verify(data)
            data = fixture()
            data[2].pop(index)
            with self.assertRaises(policy.QualificationError):
                verify(data)
        data = fixture()
        duplicate = deepcopy(data[2][0])
        duplicate["id"] += 1000
        data[2].append(duplicate)
        with self.assertRaises(policy.QualificationError):
            verify(data)

    def test_artifacts_must_be_unique_live_and_bound_to_successful_attempt(self):
        for index in range(4):
            for field, value in (("expired", True), ("expired", "false"), ("size_in_bytes", 0),
                                 ("expires_at", "2026-10-09T18:59:59Z"),
                                 ("created_at", "2026-10-09T17:59:59Z"),
                                 ("created_at", "2026-10-09T18:20:01Z")):
                with self.subTest(platform=index, field=field):
                    data = fixture()
                    data[3][index][field] = value
                    with self.assertRaises(policy.QualificationError):
                        verify(data)
            for field, value in (("id", RUN_ID + 1), ("repository_id", 98), ("head_repository_id", 98),
                                 ("head_branch", "feature"), ("head_sha", "b" * 40)):
                with self.subTest(platform=index, origin=field):
                    data = fixture()
                    data[3][index]["workflow_run"][field] = value
                    with self.assertRaises(policy.QualificationError):
                        verify(data)
            data = fixture()
            data[3].pop(index)
            with self.assertRaises(policy.QualificationError):
                verify(data)
        data = fixture()
        duplicate = deepcopy(data[3][0])
        duplicate["id"] += 1000
        data[3].append(duplicate)
        with self.assertRaises(policy.QualificationError):
            verify(data)
        data = fixture()
        extra = deepcopy(data[3][0])
        extra.update(id=500, name="release-unknown-platform")
        data[3].append(extra)
        with self.assertRaises(policy.QualificationError):
            verify(data)

    def test_failed_final_gate_rejects_artifacts_already_uploaded(self):
        data = fixture()
        data[0]["conclusion"] = "failure"
        # All four archives and even all four success jobs are insufficient.
        with self.assertRaisesRegex(policy.QualificationError, "complete qualification run"):
            verify(data)

    def test_malformed_provenance_fails_without_raw_metadata_diagnostics(self):
        for target, field, value in ((0, "updated_at", "private-token-not-a-time"),
                                     (2, "name", ["invalid"]), (3, "name", None)):
            data = fixture()
            entry = data[target] if target == 0 else data[target][0]
            entry[field] = value
            with self.assertRaises(policy.QualificationError) as caught:
                verify(data)
            self.assertNotIn("private-token-not-a-time", str(caught.exception))

    def test_failed_only_rerun_reuses_successes_and_exact_artifacts_from_same_run(self):
        data = fixture()
        for job in data[2]:
            job["run_attempt"] = 1
        # One resource gate failed in the original attempt; all other work,
        # including the four exact package artifacts, remains valid.
        previous = deepcopy(data[2][-1])
        previous["id"] += 10000
        previous["conclusion"] = "failure"
        data[2][-1]["run_attempt"] = 2
        data[2].append(previous)
        self.assertEqual(verify(data)["artifact_ids"], "200,201,202,203")
        # GitHub's list order is not a provenance ordering contract.
        data[2].reverse()
        self.assertEqual(verify(data)["artifact_ids"], "200,201,202,203")

    def test_latest_failed_execution_cannot_fall_back_to_an_old_success(self):
        for index in (0, 4, len(fixture()[2]) - 1):
            for conclusion in ("failure", "cancelled", "skipped", "neutral"):
                with self.subTest(index=index, conclusion=conclusion):
                    data = fixture()
                    previous = deepcopy(data[2][index])
                    previous.update(id=previous["id"] + 10000, run_attempt=1)
                    data[2][index]["conclusion"] = conclusion
                    data[2].append(previous)
                    with self.assertRaisesRegex(policy.QualificationError, "did not succeed"):
                        verify(data)

    def test_preflight_rerun_invalidates_older_package_and_gate_evidence(self):
        data = fixture()
        data[3][1]["created_at"] = "2026-10-08T18:15:00Z"
        with self.assertRaisesRegex(policy.QualificationError, "successful platform attempt"):
            verify(data)
        data = fixture()
        previous = deepcopy(data[2][0])
        previous.update(id=9999, run_attempt=1)
        data[2].append(previous)
        data[2][0]["started_at"] = "2026-10-09T18:16:00Z"
        with self.assertRaisesRegex(policy.QualificationError, "latest successful platform attempt"):
            verify(data)
        # Even with a fresh package, a successful gate from before the rebuild
        # cannot qualify the rebuilt candidate.
        for field, value in (("run_attempt", 1), ("started_at", "2026-10-09T18:19:59Z")):
            data = fixture()
            data[2][4][field] = value
            with self.assertRaisesRegex(policy.QualificationError, "predates"):
                verify(data)

    def test_compile_rerun_invalidates_older_gates_without_invalidating_frozen_bundles(self):
        compile_name, platform = next(iter(policy.COMPILE_JOBS.items()))
        gate_name = next(name for name, owner in policy.GATE_JOBS.items() if owner == platform)
        for field, value in (("run_attempt", 1), ("started_at", "2026-10-09T18:24:59Z")):
            data = fixture()
            gate = next(job for job in data[2] if job["name"] == gate_name)
            gate[field] = value
            with self.assertRaisesRegex(policy.QualificationError, "predates"):
                verify(data)
        # A compile retry and its fresh gates can keep the same already-tested
        # package; only rerunning the package preflight requires a new artifact.
        data = fixture()
        for job in data[2][:4]:
            job["run_attempt"] = 1
        old_compile = deepcopy(next(job for job in data[2] if job["name"] == compile_name))
        old_compile.update(id=9999, run_attempt=1, conclusion="failure")
        data[2].append(old_compile)
        self.assertEqual(verify(data)["artifact_ids"], "200,201,202,203")

    def test_historical_job_cannot_introduce_a_foreign_source_or_duplicate_metadata(self):
        for field, value in (("head_sha", "b" * 40), ("run_id", RUN_ID + 1), ("id", 100)):
            data = fixture()
            old = deepcopy(data[2][4])
            old.update(id=9999, run_attempt=1)
            old[field] = value
            data[2].append(old)
            with self.assertRaises(policy.QualificationError):
                verify(data)

    def test_verification_receipts_do_not_become_publishable_artifacts(self):
        data = fixture()
        data[3].append({"id": 500, "name": "verification-linux-x86_64", "expired": True})
        self.assertEqual(verify(data)["artifact_ids"], "200,201,202,203")


class ApiPolicy(unittest.TestCase):
    def test_fixed_host_approved_paths_and_no_redirects(self):
        client = policy.Api(REPOSITORY, "private-synthetic-token")
        for endpoint in ("https://foreign.example/path", "../outside", "actions/runs/123/artifacts?token=secret",
                         "actions/runs/123/attempts/2/jobs?per_page=100&page=1",
                         "actions/runs/123/jobs?filter=latest&per_page=100&page=1",
                         "actions/runs/123/jobs?filter=all&per_page=100&page=31",
                         "actions/runs/123/artifacts?per_page=100&page=31"):
            with self.assertRaises(policy.QualificationError) as caught:
                client.get(endpoint)
            self.assertNotIn("private-synthetic-token", str(caught.exception))
        with self.assertRaises(policy.QualificationError):
            policy.NoRedirect().redirect_request(None, None, None, None, None, "https://foreign.example")

    def test_response_size_and_errors_never_include_token_or_body(self):
        class Response(io.BytesIO):
            headers = {}
            def geturl(self):
                return f"https://api.github.com/repos/{REPOSITORY}/actions/runs/{RUN_ID}"
        class Opener:
            def __init__(self, raw):
                self.raw = raw
            def open(self, request, timeout):
                self.request = request
                return Response(self.raw)
        client = policy.Api(REPOSITORY, "private-synthetic-token")
        for raw in (b"private-synthetic-token bad JSON", b"x" * (policy.MAX_METADATA_BYTES + 1)):
            client.opener = Opener(raw)
            with self.assertRaises(policy.QualificationError) as caught:
                client.get(f"actions/runs/{RUN_ID}")
            self.assertNotIn("private-synthetic-token", str(caught.exception))

    def test_collection_pagination_is_bounded_and_complete(self):
        client = policy.Api(REPOSITORY, "private-synthetic-token")
        calls = []
        def get(endpoint):
            calls.append(endpoint)
            page = int(endpoint[-1])
            return {"total_count": 105, "jobs": list(range(100)) if page == 1 else list(range(100, 105))}
        client.get = get
        self.assertEqual(len(client.collection("actions/runs/123/jobs?filter=all", "jobs")), 105)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], "actions/runs/123/jobs?filter=all&per_page=100&page=1")
        for data in ({"total_count": policy.MAX_PAGES * policy.PAGE_SIZE + 1, "jobs": []},
                     {"total_count": 5, "jobs": []}):
            client.get = lambda _endpoint, data=data: data
            with self.assertRaises(policy.QualificationError):
                client.collection("actions/runs/123/jobs?filter=all", "jobs")

    def test_run_attempt_change_while_fetching_is_rejected(self):
        run, workflow, jobs, artifacts = fixture()
        class CapturedApi:
            def __init__(self, changed):
                self.changed = changed
                self.run_reads = 0
            def get(self, endpoint):
                if endpoint == "actions/workflows/release.yml":
                    return workflow
                self.run_reads += 1
                return run if self.run_reads == 1 else self.changed
            def collection(self, endpoint, key):
                self.jobs_endpoint = endpoint if key == "jobs" else getattr(self, "jobs_endpoint", "")
                return jobs if key == "jobs" else artifacts
        changed = deepcopy(run)
        changed["run_attempt"] = 3
        api = CapturedApi(changed)
        with self.assertRaisesRegex(policy.QualificationError, "changed during"):
            policy.fetch(api, RUN_ID, repository=REPOSITORY, expected_sha=SHA, now=NOW)
        self.assertEqual(api.jobs_endpoint, f"actions/runs/{RUN_ID}/jobs?filter=all")


class ExistingPublisherGuards(unittest.TestCase):
    def test_existing_version_qualification_is_read_only_and_opt_in(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import publish_release
        for extra, needed in (([], False), (["--qualify-existing-version"], True)):
            with self.subTest(extra=extra), \
                    patch.object(sys, "argv", ["publish_release.py", "--check", *extra]), \
                    patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": SHA,
                                            "GITHUB_OUTPUT": ""}), \
                    patch.object(publish_release, "package_versions", return_value=("8.7.6", "0.17.0")), \
                    patch.object(publish_release, "find_release", return_value={"draft": False}), \
                    patch.object(publish_release, "api") as api, \
                    patch.object(publish_release.subprocess, "run") as publish, \
                    patch.object(sys, "stdout", new_callable=io.StringIO) as output:
                publish_release.main()
                self.assertIn(f'"needed": {str(needed).lower()}', output.getvalue())
                api.assert_not_called()
                publish.assert_not_called()

    def test_existing_version_flag_cannot_enable_publication_or_skip_draft_review(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import publish_release
        with patch.object(sys, "argv", ["publish_release.py", "--qualify-existing-version"]), \
                patch.object(sys, "stderr", new_callable=io.StringIO), \
                patch.object(publish_release, "find_release") as find, \
                patch.object(publish_release.subprocess, "run") as publish:
            with self.assertRaises(SystemExit) as caught:
                publish_release.main()
            self.assertEqual(caught.exception.code, 2)
            find.assert_not_called()
            publish.assert_not_called()
        with patch.object(sys, "argv", ["publish_release.py", "--check", "--qualify-existing-version"]), \
                patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": SHA}), \
                patch.object(publish_release, "package_versions", return_value=("8.7.6", "0.17.0")), \
                patch.object(publish_release, "find_release", return_value={"draft": True}), \
                patch.object(publish_release.subprocess, "run") as publish:
            with self.assertRaisesRegex(ValueError, "unpublished draft"):
                publish_release.main()
            publish.assert_not_called()

    def test_promotion_refuses_an_existing_release_draft_or_tag(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import publish_release
        for existing, reference in (({"draft": False}, None), ({"draft": True}, None),
                                    (None, {"ref": "refs/tags/v8.7.6"})):
            with self.subTest(existing=existing, reference=reference), \
                    patch.object(sys, "argv", ["publish_release.py"]), \
                    patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": SHA}), \
                    patch.object(publish_release, "package_versions", return_value=("8.7.6", "0.17.0")), \
                    patch.object(publish_release, "find_release", return_value=existing), \
                    patch.object(publish_release, "api", return_value=reference), \
                    patch.object(publish_release.subprocess, "run") as publish:
                with self.assertRaisesRegex(ValueError, "refusing"):
                    publish_release.main()
                publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
