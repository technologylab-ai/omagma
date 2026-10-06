# Bar JSON-lines protocol, version 1

Developer reference for `omagma daemon` and its Quickshell client. This protocol
uses integer request IDs and `re` replies; it is distinct from the terminal
agent API's `account`/`cmd` request and `data`/structured-error response described
in [the agent CLI guide](AGENT-CLI.md). Both use version 1 in their own envelope;
their frames are not interchangeable. Start with [development](DEVELOPMENT.md)
for implementation checks, or [setup](SETUP.md) for normal use.

One Zig child reads requests from stdin and writes replies/events to stdout. Each frame is one JSON value followed by a newline. Credentials never cross this interface.

```json
{"id":1,"cmd":"hello"}
{"re":1,"ok":true}
{"re":2,"ok":false,"error":"stable_error_code"}
```

Request IDs are integers from `0` to `9007199254740991`. Replies identify their request through `re`. Successful `hello` and `status` replies also contain `version: 1`, `selected`, full `accounts` snapshots and diagnostic metrics.

| Command | Additional fields | Behavior |
| --- | --- | --- |
| `hello` | None | Establish version and configured accounts |
| `status` | None | Inspect current state, including while closed |
| `visibility` | `open`: boolean, `account`: address | Set popup visibility and selection |
| `select` | `account` | Select a configured account; schedule never/aged data while visible |
| `refresh` | `account` | Request refresh while visible |
| `open` | `account`, `kind`: `inbox` or `message`; `message` for message kind | Open the validated destination in the account’s profile |
| `disconnect` | `account` | Remove local credentials and clear that account’s cache |

The active handshake supplies one to three unique configured addresses. Account snapshots contain `account`, `enabled`, `required`, `generation`, `state`, `checkedAt`, `unread`, `partial`, `error`, `retryAt` and `messages`. Snapshot events additionally contain `ev: "snapshot"`.

States are `never`, `loading`, `current`, `stale`, `disconnected` and `unavailable`. `checkedAt` and `retryAt` are Unix seconds, or zero. `unread` is a nonnegative integer or `null` when unavailable; `partial` is boolean. Each message contains opaque `id` and `threadId`, plain strings `sender`, `subject` and `snippet`, `receivedAt` in Unix milliseconds and boolean `unread`.

At most 30 messages are retained per account. Generations increase independently for each account, including state changes. Clients reject unknown account addresses and generations less than or equal to their cached generation. A valid snapshot replaces that account’s array. A fresh handshake replaces the whole account list; a backend restart has no valid mail cache. There is no unified unread total.

Snapshot events are emitted only while visible. Background results replace the bounded internal cache and are delivered on reopening; `status` remains available while closed. With the default `refreshIntervalSeconds: 0`, closing clears pending work and cancels active work, restoring the prior state without a cancellation error. With a positive interval, background jobs continue while closed. Owner EOF cancels and joins work in both modes. See [background scheduling](BACKGROUND-REFRESH.md).

Input frames are capped at 16 KiB and output frames at 512 KiB. Oversized or invalid frames fail without growing storage. Backpressure coalesces pending snapshots per account and retains at most 64 replies while control input continues to be read. Saturation drops the oldest replies and emits one coalesced event:

```json
{"ev":"error","error":"ReplyWindowExceeded"}
```

Discard pending request metadata and resynchronize with `hello` on this event. The UI itself limits outstanding requests to 64 and holds no view callbacks.

## Developer test modes

`omagma daemon [--config FILE] [--fixtures] [--dry-run-open]` starts the child. `--fixtures` uses synthetic mail without Gmail/keyring access. `--dry-run-open` returns browser argv in the reply without launching Chrome.

Fixture-only options are `--fixture-delay-ms`, `--fixture-fail-account`, `--fixture-empty-account`, `--fixture-fail-after`, `--fixture-rows` (0..30, default 8) and `--fixture-auto-refresh-ms` (1..60000). They support timing, failure and accelerated background tests without real accounts. Fixtures are a test-harness choice, not an installation or live authorization step.
