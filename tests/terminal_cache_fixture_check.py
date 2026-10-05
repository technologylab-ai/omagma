#!/usr/bin/env python3
"""Independent fixture checks for terminal cache/history acceptance."""
import base64
import hashlib
import unittest

from probes.cache_refresh_fixture import ACCOUNTS, corpus, newest_ids


class RefreshFixtureCheck(unittest.TestCase):
    def test_exact_newest_count_and_tail(self):
        for account in ACCOUNTS:
            data = corpus(account)
            self.assertEqual(data["expected"]["baselineIds"], [f"shared-msg-{i:03}" for i in range(96, 56, -1)])
            expected = [f"shared-msg-{i:03}" for i in range(98, 57, -1) if i != 95]
            self.assertEqual(data["expected"]["deltaIds"], expected)
            self.assertEqual(len(expected), 40)
            self.assertEqual(data["expected"]["tailEvictedIds"], ["shared-msg-057"])
            self.assertEqual(data["expected"]["deletedIds"], ["shared-msg-095"])
            # TUI starts in INBOX: delete95/archive94 cancel the row movement
            # for93, so96 is the selected-ID oracle that actually shifts rows.
            before = newest_ids(data["baseline"]["messages"], label="INBOX")
            after = newest_ids(data["delta"]["messages"], label="INBOX")
            self.assertEqual(before.index(data["expected"]["selectedMessageId"]), 0)
            self.assertEqual(after.index(data["expected"]["selectedMessageId"]), 2)

    def test_history_dedup_and_events_match_snapshot(self):
        for account in ACCOUNTS:
            data = corpus(account)
            events = [event for page in data["historyPages"] for event in page["history"]]
            added = [item["message"]["id"] for event in events for item in event.get("messagesAdded", [])]
            self.assertEqual(added.count("shared-msg-098"), 2)
            self.assertEqual(set(added), {"shared-msg-097", "shared-msg-098"})
            current = {m["id"]: m for m in data["delta"]["messages"]}
            self.assertNotIn("shared-msg-095", current)
            self.assertEqual(current["shared-msg-093"]["labelIds"], ["INBOX", "STARRED"])
            self.assertNotIn("INBOX", current["shared-msg-094"]["labelIds"])
            self.assertEqual(data["noChangeHistory"], {"historyId": "1000", "history": []})

    def test_label_only_changes_preserve_body_bytes(self):
        for account in ACCOUNTS:
            data = corpus(account)
            before = {m["id"]: m for m in data["baseline"]["messages"]}
            after = {m["id"]: m for m in data["delta"]["messages"]}
            for message_id in ("shared-msg-093", "shared-msg-094", "shared-msg-092"):
                self.assertEqual(before[message_id]["payload"], after[message_id]["payload"])

    def test_account_isolation_with_colliding_ids(self):
        digests = set()
        for account in ACCOUNTS:
            data = corpus(account)
            message = next(m for m in data["delta"]["messages"] if m["id"] == "shared-msg-098")
            self.assertEqual(message["threadId"], "shared-thread-new-098")
            payload = message["payload"]["body"]["data"]
            body = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
            self.assertIn(account.encode(), body)
            self.assertEqual(sum(other.encode() in body for other in ACCOUNTS), 1)
            digests.add(hashlib.sha256(body).hexdigest())
        self.assertEqual(len(digests), 3)

    def test_expired_checkpoint_resync_remains_bounded(self):
        for account in ACCOUNTS:
            data = corpus(account)
            ids = newest_ids(data["expired"]["messages"])
            self.assertEqual(len(ids), 40)
            self.assertEqual(ids[:8], [f"shared-msg-{i:03}" for i in range(106, 98, -1)])
            self.assertEqual(ids, data["expected"]["resyncIds"])
            self.assertLess(len(ids), len(data["expired"]["messages"]))


if __name__ == "__main__":
    unittest.main()
