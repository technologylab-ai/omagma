# Bounded backend transport

Developer reference for transport/storage ownership. Start with [development](DEVELOPMENT.md);
installation and account permission choices belong in [setup](SETUP.md).
The HTTP/TLS paths use exact Zig 0.17.0 std with certificate and hostname
validation and no external HTTP library. The combined executable's terminal UI
has pinned libvaxis dependencies described in [UI design](TERMINAL-UI-DESIGN.md).
The bounds below describe the bar; terminal policy is separate. One bar worker
handles one active account job and at most one pending flag per account.
Release/memory checks use `-Doptimize=safe`; correctness also uses `debug`.

| Storage or deadline | Bound |
| --- | --- |
| Application-owned reservation | 16 MiB |
| HTTP/TLS allocator slab | 8 MiB |
| JSON workspace | 2 MiB |
| HTTP response body | 512 KiB |
| Token response body | 16 KiB |
| Response headers | 32 KiB |
| IPC input / output frames | 16 KiB / 512 KiB |
| Accounts / retained rows per account | 3 / 30 |
| Sender and subject / snippet | 512 / 1,024 UTF-8 bytes |
| Account address / opaque ID | 254 / 128 bytes |
| JSON nesting / tokens | 64 / 32,768 |
| Network request / complete refresh | 10 / 30 seconds |
| Consent / keyring operation | 180 / 10 seconds |

The HTTP client is destroyed before its slab is reset. Exhaustion fails within the bound; it does not fall back to an unrestricted allocator. Redirects and nonidentity compressed response encodings are rejected. A refresh token retry is bounded to one retry after an unauthorized response.

Each refresh lists one Inbox page without pagination, fetches metadata sequentially, and replaces the account snapshot only after validation. The retained page is sorted by received time. This sorts the fetched page; it does not prove a universal guarantee about which messages the provider places on that first page. A failed job preserves the previous successful rows. Allowed list/get races can produce a partial page when a message disappears between calls.

The 16 MiB reservation covers application-owned storage, not the entire process. Zig I/O runtime structures, thread stacks, TLS call stacks, kernel memory and external browser/keyring processes are separate. Requested runtime/worker stacks are bounded, and the whole process is measured independently. See [verification gates](VERIFICATION.md). Historical [evidence](../EVIDENCE.md) keeps the compiler version actually measured; a compiler migration requires separate correctness and memory qualification.

## Terminal transport

The terminal interface retains the authorization-header workaround, strict
Google-host allowlist, rejected redirects/compression, certificate validation and
finite cancellation/join behavior. Its separate JSON transport permits only
Gmail, OAuth and People endpoints, with 3 MiB Google request/response storage,
10-second HTTP request deadlines and a 30-second whole refresh deadline. Decoded
MIME text/HTML leaves are at most 2 MiB, aggregate decoded MIME at most 3 MiB;
normalized CLI/TUI DTOs can exceed wire size and stay under the separate 64 MiB
terminal heap cap. The TUI response limit is 32 MiB, not the bar's 512 KiB frame.
Wider methods are exposed only through capability-checked operations; read-only
bar policy remains unchanged. Automatic cache refresh specifically uses bar
read-only grants and never selects a wider terminal token.

Larger ordinary terminal attachments use immutable account handles, private MIME
spooling and bounded streaming rather than expanding the JSON buffer. Outgoing
MIME is capped at 35 MiB, the outer HTTP stream at 36 MiB, and decoded saved
files at 25 MiB, within account disk quotas. Saves create private atomic files
without overwriting existing destinations. Streaming retains the same host,
credential, deadline and cancellation policy.

`ProgressSink` reports actual batch units and borrowed rows synchronously to the
owned worker's observer. The TUI copies bounded previews; those callbacks do not
change allowed hosts, deadlines, cancellation ownership or CLI JSON-lines frames.
[Provider implementation](TERMINAL-PROVIDER-DESIGN.md) and
[terminal verification](TERMINAL-VERIFICATION.md) qualify this path separately.
