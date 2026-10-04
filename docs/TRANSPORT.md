# Bounded backend transport

The backend targets exact Zig 0.17.0 standard-library HTTP/TLS with certificate and hostname validation. There are no external Zig dependencies. One worker performs network work, with one active account job and at most one pending job flag per account. Release/memory checks use `-Doptimize=safe`; correctness also runs with `-Doptimize=debug`.

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
