# Cache-first terminal startup

The TUI and CLI share a bounded private mail cache. [Installation](INSTALL.md), [terminal guide](TERMINAL.md).

## Startup and refresh

Available cached mail appears immediately while Omagma checks Gmail in the background. A cold account shows **Fetching mail**; a warm account keeps usable rows and downloaded bodies visible during refresh. Fetch state has its own colored line, separate from action messages. `NO_COLOR` keeps explicit text states.

Once a fetch knows its actual bounded batch, `metadata 1/32` or `bodies 1/32` shows completed work. This is not the Inbox size or unread count. Already cached bodies do not count as downloads. Before the batch is known, the line simply says fetching. The fixed **Synced** time uses the computer's local timezone and the date's DST offset. An explicit `TZ` setting overrides the system timezone, including `TZ=UTC0` for UTC. Unsupported settings visibly show `UTC (TZ unavailable)`. Stored mail and synchronization timestamps remain UTC.

Loading placeholders become real, interactive rows after a window commits. A missing/unsupported body is identified clearly, partial cached threads are marked, and a snippet is not presented as a full message. New results preserve selection where possible; an open composer keeps its original context.

Refresh requests changes since the last completed update. Unchanged mail does not need another body download. If that history is no longer available, Omagma rebuilds a bounded recent snapshot. Interrupted or failed refreshes leave previously cached mail and drafts usable.

## Retention and body downloads

Defaults keep at most **2,000 messages and 256 MiB per account**, ordered by received time. The oldest tail and its body files are evicted under count or byte pressure. Drafts, contacts and operation receipts are preserved separately.

For example, keep a smaller recent cache and fill up to 32 bodies:

```sh
omagma tui --metadata-limit 1000 --disk-limit-bytes 268435456
```

Add `--prefetch-bodies N` for 0–64. The normal head is the smaller of the requested page and 32; a larger value fills more retained bodies without changing the displayed window, while zero disables automatic body filling. Selecting a missing body in ordinary mailbox/Gmail results can still fetch it read-only; local cache search does not.

Use the same cache and policy choices for the CLI or [background timer](TERMINAL-BACKGROUND.md). The cache is shared across callers, so an explicitly changed policy affects what stays available to other views.

## Windows and search

The TUI displays at most 32 rows, and scrolling past an edge moves to adjacent cached mail. Moving older can request one Gmail page after the cache tail; moving newer uses cached metadata, including after a middle-position restart. It does not download the whole mailbox. `[`/`]` also provides explicit page controls. A selected full body can still need a read-only fetch if absent.

`/` searches retained metadata and downloaded plaintext without fetching missing bodies or uncached older results. It supports quoted phrases, compound/negative terms and the field filters listed in the [terminal guide](TERMINAL.md#search). `\` explicitly searches Gmail. CLI callers choose `--cached` / `--server`; JSONL uses `cacheOnly:true` / `false`.

Local search is a subset, not proof that the rest of Gmail lacks a match. For CLI pagination, keep the returned cursor with its account/query/label. Restart after `InvalidCursor`, for example when newly downloaded bodies change body-search results. [CLI contract](AGENT-CLI.md).

## Private storage and permissions

To clear one account's retained mail explicitly:

```sh
omagma cache clear --account personal@example.com
```

This removes local mail metadata and bodies, preserving local drafts, contacts,
operation receipts, undo receipts, downloaded
label and sender-identity lists; the fixture provider keeps its synthetic sent
outbox. It does not delete anything from Gmail. The next
refresh fills a bounded recent cache again. Use the same `--cache-dir` option
if you configured a nondefault cache location.

The terminal stores plaintext mail and drafts under `$XDG_CACHE_HOME/omagma/terminal`, or `$HOME/.cache/omagma/terminal`, with owner-only directories and files. Account directories are separated. Keep the cache outside Git; filesystem permissions do not encrypt it at rest.

The bar's small memory-only snapshot is separate. Terminal refresh uses existing read-only Gmail access and does not mark mail read, send messages, change labels or edit contacts. Full write features have their own [terminal grant setup](SETUP.md#full-tuicli-permissions). Developer synchronization, parser and resource contracts are in [developer references](DEVELOPMENT.md).
