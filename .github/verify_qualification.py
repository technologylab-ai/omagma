#!/usr/bin/env python3
"""Verify a completed native qualification before manually promoting its assets.

Only GitHub API metadata is read. Binary download and publication belong to the
manual promotion workflow after this verifier has produced fixed artifact IDs.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

WORKFLOW_PATH = ".github/workflows/release.yml"
WORKFLOW_NAME = "Release"
PLATFORMS = {
    "Linux x86_64 qualification": "release-linux-x86_64",
    "Linux arm64 qualification": "release-linux-arm64",
    "macOS arm64 qualification": "release-macos-arm64",
    "macOS x86_64 qualification": "release-macos-x86_64",
}
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_PAGES = 3
PAGE_SIZE = 100


class QualificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise QualificationError(message)


def positive(value, description):
    require(type(value) is int and 0 < value < 10**20, f"Invalid {description}")
    return value


def timestamp(value, description):
    require(isinstance(value, str) and len(value) <= 40, f"Invalid {description}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise QualificationError(f"Invalid {description}") from None
    require(parsed.tzinfo is not None, f"Timezone missing from {description}")
    return parsed.astimezone(timezone.utc)


def verify_run(run, workflow, repository, expected_sha, run_id):
    require(isinstance(run, dict) and isinstance(workflow, dict), "Invalid workflow metadata")
    require(run.get("id") == run_id, "Qualification run ID does not match the requested run")
    require(workflow.get("path") == WORKFLOW_PATH and workflow.get("name") == WORKFLOW_NAME,
            "The trusted Release workflow could not be established")
    workflow_id = positive(workflow.get("id"), "workflow ID")
    require(run.get("workflow_id") == workflow_id and run.get("path") == WORKFLOW_PATH
            and run.get("name") == WORKFLOW_NAME, "Run does not belong to the trusted Release workflow")
    source_repo, head_repo = run.get("repository", {}), run.get("head_repository", {})
    require(isinstance(source_repo, dict) and isinstance(head_repo, dict), "Invalid run repository metadata")
    require(source_repo.get("full_name") == repository and head_repo.get("full_name") == repository,
            "Qualification must come from this repository, not a fork")
    repository_id = positive(source_repo.get("id"), "repository ID")
    require(head_repo.get("id") == repository_id, "Qualification head repository does not match")
    require(run.get("head_branch") == "main" and run.get("event") in {"push", "workflow_dispatch"},
            "Qualification must run the trusted main branch")
    require(run.get("head_sha") == expected_sha, "Qualification source differs from this dispatch commit")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "The complete qualification run must have succeeded")
    timestamp(run.get("updated_at"), "qualification update time")
    return repository_id, positive(run.get("run_attempt"), "run attempt")


def verify(run, workflow, jobs, artifacts, *, repository, expected_sha, run_id, now=None):
    """Fail closed over captured API metadata; used by the offline tests too."""
    require(isinstance(repository, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is not None,
            "Invalid repository name")
    require(isinstance(expected_sha, str) and re.fullmatch(r"[0-9a-f]{40}", expected_sha) is not None, "Invalid dispatch commit")
    positive(run_id, "run ID")
    repository_id, attempt = verify_run(run, workflow, repository, expected_sha, run_id)
    require(isinstance(jobs, list) and len(jobs) <= PAGE_SIZE * MAX_PAGES, "Invalid qualification jobs")
    require(isinstance(artifacts, list) and len(artifacts) <= PAGE_SIZE * MAX_PAGES,
            "Invalid qualification artifacts")
    now = now or datetime.now(timezone.utc)
    require(now.tzinfo is not None, "Qualification time must include a timezone")
    selected_jobs = {}
    job_ids = set()
    for job in jobs:
        require(isinstance(job, dict), "Invalid qualification job")
        job_id = positive(job.get("id"), "job ID")
        require(job_id not in job_ids, "Duplicate qualification job metadata")
        job_ids.add(job_id)
        require(job.get("run_id") == run_id and job.get("run_attempt") == attempt
                and job.get("head_sha") == expected_sha, "Job provenance differs from the current run attempt")
        name = job.get("name")
        require(isinstance(name, str) and len(name) <= 256, "Invalid qualification job name")
        if name in PLATFORMS:
            require(name not in selected_jobs, "Duplicate native platform qualification job")
            require(job.get("status") == "completed" and job.get("conclusion") == "success",
                    f"Native qualification did not succeed: {name}")
            started = timestamp(job.get("started_at"), "job start time")
            completed = timestamp(job.get("completed_at"), "job completion time")
            require(started <= completed <= now, "Invalid qualification job time range")
            selected_jobs[name] = (started, completed)
    require(set(selected_jobs) == set(PLATFORMS), "All four native platform qualifications are required")
    by_name = {}
    artifact_ids = set()
    for artifact in artifacts:
        require(isinstance(artifact, dict), "Invalid artifact metadata")
        artifact_id = positive(artifact.get("id"), "artifact ID")
        require(artifact_id not in artifact_ids, "Duplicate artifact metadata")
        artifact_ids.add(artifact_id)
        name = artifact.get("name")
        require(isinstance(name, str) and len(name) <= 256, "Invalid artifact name")
        if name not in PLATFORMS.values():
            require(not isinstance(name, str) or not name.startswith("release-"), "Unexpected release artifact")
            continue
        require(name not in by_name, "Duplicate release artifact name")
        require(artifact.get("expired") is False and timestamp(artifact.get("expires_at"), "artifact expiry") > now,
                "A release artifact has expired")
        positive(artifact.get("size_in_bytes"), "artifact size")
        origin = artifact.get("workflow_run", {})
        require(isinstance(origin, dict) and origin.get("id") == run_id
                and origin.get("repository_id") == repository_id
                and origin.get("head_repository_id") == repository_id
                and origin.get("head_branch") == "main" and origin.get("head_sha") == expected_sha,
                "Release artifact provenance differs from the verified run")
        platform = next(platform for platform, expected in PLATFORMS.items() if expected == name)
        started, completed = selected_jobs[platform]
        require(started <= timestamp(artifact.get("created_at"), "artifact creation") <= completed,
                "Release artifact was not created during this successful platform attempt")
        by_name[name] = artifact_id
    require(set(by_name) == set(PLATFORMS.values()), "All four unexpired release artifacts are required")
    return {"run_id": run_id, "head_sha": expected_sha, "run_attempt": attempt,
            "workflow_id": workflow["id"],
            "artifact_ids": ",".join(str(by_name[name]) for name in PLATFORMS.values())}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise QualificationError("GitHub API redirects are refused")


class Api:
    def __init__(self, repository, token):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is not None,
                "Invalid repository name")
        require(isinstance(token, str) and 0 < len(token) <= 4096 and "\n" not in token and "\r" not in token,
                "GitHub API token is required")
        self.base = f"https://api.github.com/repos/{repository}/"
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def get(self, endpoint):
        require(re.fullmatch(r"actions/(?:workflows/release\.yml|runs/[0-9]+(?:/attempts/[0-9]+/jobs|/artifacts)?)(?:\?per_page=100&page=[123])?", endpoint) is not None,
                "Unapproved GitHub API endpoint")
        request = urllib.request.Request(self.base + endpoint, headers={
            "Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
            "Accept-Encoding": "identity", "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "omagma-qualification-verifier"})
        try:
            with self.opener.open(request, timeout=15) as response:
                require(response.geturl() == request.full_url, "GitHub API destination changed")
                require(response.headers.get("Content-Encoding", "identity") == "identity",
                        "Compressed qualification metadata is refused")
                raw = response.read(MAX_METADATA_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise QualificationError(f"GitHub API request failed (HTTP {error.code})") from None
        except urllib.error.URLError:
            raise QualificationError("GitHub API metadata is unavailable") from None
        require(len(raw) <= MAX_METADATA_BYTES, "GitHub qualification metadata exceeds its bound")
        try:
            return json.loads(raw)
        except (ValueError, UnicodeError, RecursionError):
            raise QualificationError("Invalid GitHub qualification metadata") from None

    def collection(self, endpoint, key):
        values, total = [], None
        for page in range(1, MAX_PAGES + 1):
            data = self.get(f"{endpoint}?per_page={PAGE_SIZE}&page={page}")
            require(isinstance(data, dict), "Invalid GitHub collection metadata")
            count, items = data.get("total_count"), data.get(key)
            require(type(count) is int and 0 <= count <= PAGE_SIZE * MAX_PAGES
                    and isinstance(items, list) and len(items) <= PAGE_SIZE, "Unbounded GitHub collection")
            require(total is None or total == count, "GitHub collection changed during verification")
            total = count
            values.extend(items)
            require(len(values) <= total, "GitHub collection contains duplicate or excess entries")
            if len(values) == total:
                return values
            require(len(items) == PAGE_SIZE, "GitHub collection is incomplete")
        raise QualificationError("GitHub collection pagination exceeds its bound")


def fetch(api, run_id, *, repository, expected_sha, now=None):
    run = api.get(f"actions/runs/{run_id}")
    workflow = api.get("actions/workflows/release.yml")
    _, attempt = verify_run(run, workflow, repository, expected_sha, run_id)
    jobs = api.collection(f"actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
    artifacts = api.collection(f"actions/runs/{run_id}/artifacts", "artifacts")
    result = verify(run, workflow, jobs, artifacts, repository=repository, expected_sha=expected_sha, run_id=run_id, now=now)
    # A rerun/cancellation must not combine jobs from one attempt with another
    # attempt's whole-run conclusion while API calls are in flight.
    final = api.get(f"actions/runs/{run_id}")
    _, final_attempt = verify_run(final, workflow, repository, expected_sha, run_id)
    require(final_attempt == attempt and final.get("updated_at") == run.get("updated_at"),
            "Qualification run changed during verification")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--expected-sha", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--expected-attempt", type=int)
    parser.add_argument("--expected-artifact-ids")
    args = parser.parse_args()
    require(re.fullmatch(r"[1-9][0-9]{0,19}", args.run_id) is not None, "Invalid qualification run ID")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    require(isinstance(args.expected_sha, str) and re.fullmatch(r"[0-9a-f]{40}", args.expected_sha) is not None,
            "An exact dispatch source commit is required")
    run_id = positive(int(args.run_id), "run ID")
    result = fetch(Api(repository, os.environ.get("GH_TOKEN", "")), run_id,
                   repository=repository, expected_sha=args.expected_sha)
    if args.expected_attempt is not None:
        require(result["run_attempt"] == args.expected_attempt, "Qualification attempt changed before publication")
    if args.expected_artifact_ids is not None:
        require(result["artifact_ids"] == args.expected_artifact_ids, "Qualified artifacts changed before publication")
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except QualificationError as error:
        print(f"Qualification refused: {error}", file=sys.stderr)
        raise SystemExit(1)
