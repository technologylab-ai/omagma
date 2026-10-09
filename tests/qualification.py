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
    artifacts = [{"id": 200 + index, "name": name, "expired": False, "size_in_bytes": 4096,
                  "created_at": "2026-10-09T18:15:00Z", "expires_at": "2026-11-08T18:15:00Z",
                  "workflow_run": {"id": RUN_ID, "repository_id": 99, "head_repository_id": 99,
                                   "head_branch": "main", "head_sha": SHA}}
                 for index, name in enumerate(policy.PLATFORMS.values())]
    return run, workflow, jobs, artifacts


def verify(data):
    return policy.verify(*data, repository=REPOSITORY, expected_sha=SHA, run_id=RUN_ID, now=NOW)


class Qualification(unittest.TestCase):
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

    def test_all_four_current_attempt_native_jobs_must_succeed(self):
        for index in range(4):
            for field, value in (("status", "queued"), ("conclusion", "failure"), ("conclusion", "skipped"),
                                 ("run_attempt", 1), ("run_id", RUN_ID + 1), ("head_sha", "b" * 40)):
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

    def test_rerun_failed_jobs_cannot_mix_prior_attempt_jobs_or_artifacts(self):
        data = fixture()
        data[2][1]["run_attempt"] = 1
        with self.assertRaisesRegex(policy.QualificationError, "current run attempt"):
            verify(data)
        data = fixture()
        data[3][1]["created_at"] = "2026-10-08T18:15:00Z"
        with self.assertRaisesRegex(policy.QualificationError, "successful platform attempt"):
            verify(data)

    def test_verification_receipts_do_not_become_publishable_artifacts(self):
        data = fixture()
        data[3].append({"id": 500, "name": "verification-linux-x86_64", "expired": True})
        self.assertEqual(verify(data)["artifact_ids"], "200,201,202,203")


class ApiPolicy(unittest.TestCase):
    def test_fixed_host_approved_paths_and_no_redirects(self):
        client = policy.Api(REPOSITORY, "private-synthetic-token")
        for endpoint in ("https://foreign.example/path", "../outside", "actions/runs/123/artifacts?token=secret",
                         "actions/runs/123/attempts/2/jobs?per_page=100&page=4"):
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
        self.assertEqual(len(client.collection("actions/runs/123/attempts/2/jobs", "jobs")), 105)
        self.assertEqual(len(calls), 2)
        for data in ({"total_count": 301, "jobs": []}, {"total_count": 5, "jobs": []}):
            client.get = lambda _endpoint, data=data: data
            with self.assertRaises(policy.QualificationError):
                client.collection("actions/runs/123/attempts/2/jobs", "jobs")

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
        self.assertIn("/attempts/2/jobs", api.jobs_endpoint)


class ExistingPublisherGuards(unittest.TestCase):
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
