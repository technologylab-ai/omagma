#!/usr/bin/env python3
"""Readiness and diagnostic privacy checks for the fixture background gate."""
from copy import deepcopy
import json
import unittest

from background_measure import fixture_ready, fixture_readiness_sample


def published():
    return dict(ok=True, accounts=[
        dict(account=f"private-{slot}@example.test", enabled=True, state="current", checkedAt=100,
             generation=2, error="", messages=[dict(id="private-id", subject="private-content")] * 30)
        for slot in range(3)
    ], metrics=dict(refreshJobs=3, activeJobs=0, pendingJobs=0))


class FixtureReadiness(unittest.TestCase):
    def test_published_cache_survives_continuous_refresh(self):
        self.assertTrue(fixture_ready(published(), (True,) * 3))
        for slot in range(3):
            status = published()
            status["accounts"][slot]["state"] = "loading"
            status["metrics"].update(activeJobs=1, pendingJobs=2)
            self.assertFalse(all(account["state"] == "current" for account in status["accounts"]))
            self.assertTrue(fixture_ready(status, (True,) * 3))

    def test_unpublished_or_incomplete_cache_is_not_ready(self):
        for slot in range(3):
            for key, value in (("checkedAt", 0), ("checkedAt", -1), ("checkedAt", True),
                               ("generation", 0), ("generation", None), ("messages", []),
                               ("messages", [{}] * 29), ("messages", [{}] * 31), ("messages", None)):
                with self.subTest(slot=slot, key=key, value=value):
                    status = published()
                    status["accounts"][slot].update(state="loading", **{key: value})
                    self.assertFalse(fixture_ready(status, (True,) * 3))

    def test_failure_states_and_retained_errors_are_not_ready(self):
        for slot in range(3):
            for state in ("never", "stale", "disconnected", "unavailable"):
                status = published()
                status["accounts"][slot]["state"] = state
                self.assertFalse(fixture_ready(status, (True,) * 3))
            for state in ("current", "loading"):
                for error in ("TransientFailure", None):
                    status = published()
                    status["accounts"][slot].update(state=state, error=error)
                    self.assertFalse(fixture_ready(status, (True,) * 3))

    def test_missing_fields_and_account_slots_are_not_ready(self):
        for key in ("enabled", "state", "error", "checkedAt", "generation", "messages"):
            status = published()
            del status["accounts"][1][key]
            self.assertFalse(fixture_ready(status, (True,) * 3))
        for count in (0, 1, 2, 4):
            status = published()
            status["accounts"] = [deepcopy(status["accounts"][0]) for _ in range(count)]
            self.assertFalse(fixture_ready(status, (True,) * 3))
        status = published()
        status["ok"] = False
        self.assertFalse(fixture_ready(status, (True,) * 3))
        self.assertFalse(fixture_ready(dict(ok=True, accounts=[]), ()))

    def test_disabled_accounts_do_not_fake_an_enabled_publication(self):
        status = published()
        status["accounts"][2].update(enabled=False, state="unavailable", checkedAt=0, generation=0, messages=[])
        self.assertTrue(fixture_ready(status, (True, True, False)))
        self.assertFalse(fixture_ready(status, (True,) * 3))
        self.assertFalse(fixture_ready(status, (False,) * 3))
        for account in status["accounts"]:
            account["enabled"] = False
        self.assertFalse(fixture_ready(status, (False,) * 3))

    def test_diagnostics_contain_only_counts_states_and_error_codes(self):
        status = published()
        sample = fixture_readiness_sample(status)
        encoded = json.dumps(sample)
        self.assertNotIn("private-", encoded)
        self.assertEqual([account["slot"] for account in sample["accounts"]], [0, 1, 2])
        self.assertEqual([account["retainedRows"] for account in sample["accounts"]], [30] * 3)
        for account in sample["accounts"]:
            self.assertEqual(set(account), {"slot", "enabled", "state", "checkedAt", "generation", "retainedRows", "error"})


if __name__ == "__main__":
    unittest.main()
