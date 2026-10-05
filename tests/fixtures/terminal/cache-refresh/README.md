# Cache-first and history refresh test contract

These tests use fictional accounts and temporary copies of the existing 96-message corpus. The released corpus and historical receipts remain unchanged. `tests/probes/cache_refresh_fixture.py` prepares independent Gmail-shaped history pages and complete snapshots; it never reads credentials or contacts a server. The retained newest-message count is 40, so it exceeds the bar's 30-row limit and exercises old-tail eviction.

The provider test controls must make remote entry and completion independently observable. A held provider call records its account and operation kind before waiting for an explicit release marker; exit/cancellation must interrupt that wait within a finite deadline. A fixed sleep alone cannot prove that navigation completed while the remote was still pending. Counters distinguish history, list, metadata and full-body calls. Fixture control, logs and state contain synthetic data only.

| Gate | Independent observable result |
| --- | --- |
| Repeat startup | Seed and close a cache; hold remote refresh on restart; a known cached row is rendered before release, with no empty-list reset |
| Cached navigation/read | Navigate and read a previously cached full message/thread while remote is held; the known body matches exactly and remote has not completed |
| Status | Current rendered fetching status has a distinct foreground color; no-change success and offline/error have their own clear text; `NO_COLOR` retains text without status colors |
| Selection | Select an existing message, then release a newer-message delta; its identity remains selected even when the row index moves |
| Failure | A failed remote refresh retains rows, full bodies and selection; subsequent startup still loads them |
| No-change history | A valid unchanged history response makes zero list, metadata or full-body refetches and leaves body file digests unchanged |
| Delta merge | Two paginated history responses contain duplicate new IDs, deletion and label changes; each new ID appears once, deleted mail disappears, and cached body bytes remain unchanged after label-only updates |
| Expired history | A 404 checkpoint triggers one bounded newest-message resync, retaining cached display until completion; metadata and complete offline body requests remain bounded by the configured newest count |
| Count eviction | Arrival evicts the oldest retained tail, independent of read/access recency; both metadata and resident body files for the evicted message disappear |
| Secondary byte quota | Large bodies trigger the byte guard without violating the logical-byte quota or destroying another account's retained metadata |
| Isolation | Shared message IDs and history values never cross accounts; account/query/folder cursor identity stays explicit, and a narrow folder/search result cannot replace the global newest-mail cache, including expired or missing history checkpoints |
| Lifecycle | Quit/cancel during a held refresh reaps workers and restores terminal settings; reopening finds a complete private cache, not a partial refresh |

The baseline history is 1000. History 1001 adds messages 097 and 098, deletes 095, marks 093 read/starred and removes 094 from INBOX. Duplicate 098 references exercise deduplication. An expired checkpoint resync uses history 1100 and eight additional newer messages. The Python oracle orders literal timestamps and computes retained IDs independently of the application. Every account uses the same IDs with different account-specific content.

The existing isolation gate also requests the one-message STARRED/subject view after an expired checkpoint, then after removing history fields from a closed private synthetic cache. Both must retain the authoritative global newest 40 IDs instead of replacing them with that one scoped result. Global plus scoped metadata fetches are bounded by twice the configured count; full-body fetches are bounded by the retained count. Unchanged retained body digests, local unsent drafts and other accounts survive both paths.

The executable entry point is `tests/terminal_cache.py --binary PATH --build-mode debug|safe --output NEW.json`, optionally selecting one gate with `--case`. It refuses receipt overwrites and stops at the first failure. Local requests use `cacheOnly: true`; remote work uses `mail.refresh`. Account fixture `sync` contains `historyId`, Gmail-shaped `historyPages`, optional `expired: true`, and optional `fixtureHold`/`fixtureEntered` leaf filenames under the fixture root. The provider creates the entered marker before waiting while the hold marker exists; the harness removes the hold marker to release it. Complete offline bodies are prefetched for the retained newest head, so unchanged history must refetch zero bodies and the two new delta IDs must each fetch exactly one body.

These are proposed acceptance gates, not completed results. Heavy builds, backend/PTY suites and measurements require the cooperative host reservation. All PTYs belong to the harness; no desktop input, installed configuration, real account, grant, browser or mailbox write is involved.
