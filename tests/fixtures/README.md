# Synthetic verification fixtures

`contract.json` records the user-facing limits and configured account/profile pairs. The backend's `--fixtures` provider supplies synthetic mail with conflicting message and thread IDs in the two required accounts. Tests require distinct sender/subject content for those conflicts and both read and unread messages. Optional account is unavailable by default and remains optional.

Use `--fixture-delay-ms` to exercise overlapping requests and cancellation; `--fixture-empty-account` tests a successful empty Inbox; `--fixture-fail-account` tests isolated transport failure; `--fixture-fail-after 1` tests preservation of a previous successful snapshot. These modes never request Gmail or Secret Service credentials. The integration harness invokes `--dry-run-open`, so the browser argv is inspected without opening Chrome.

The provider fixtures and test artifacts contain synthetic data only. Real tokens, mail, consent callbacks, and downloaded OAuth credentials must stay outside this repository.

`all-accounts.json` enables all three accounts for the capacity soak only. `tests/measure.py` passes `--fixtures --fixture-rows 30` and uses this synthetic config by default, so it retains the full 90-row capacity without making Gmail or keyring requests. The normal example configuration keeps Optional account disabled.
