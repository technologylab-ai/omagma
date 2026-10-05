# Omagma agent CLI

**Experimental:** verify account capabilities and operation receipts before live tasks. API behavior and commands may change as the terminal client develops.

Use the verified release binary (`--version`, `build-info`). No compiler is needed for release use. For setup, read [AGENTS.md](../AGENTS.md) and [the setup workflow](../skills/omagma-setup/SKILL.md). For terminal permissions read [TERMINAL.md](TERMINAL.md). Never widen permissions or send mail merely because an agent has read access. Development uses `--fixtures`; initial live write acceptance requires an explicitly provided dedicated test mailbox. Production writes need separate explicit user intent and suitable account authorization.

Fixture accounts expose mock send, mailbox-change, contact and RSVP capabilities without OAuth or Google access. Inspect `accounts.list` when selecting capabilities for an actual account.

## Protocol

`omagma cli` (alias `omagma agent`) reads one JSON object per line and emits one response per line. stdout contains only protocol frames. EOF ends the process; malformed/oversized frames produce errors and the next frame can proceed. Each response echoes id and account:

```json
{"version":1,"id":"list-1","ok":true,"account":"personal@example.com","data":{"messages":[],"nextCursor":null}}
```

Errors use `ok:false,error:{code,message}`. id may be a string, integer or null. Limits are documented in [TERMINAL.md](TERMINAL.md); requests are at most 3 MiB and nesting 64. Optional string fields must be strings or omitted, not JSON null. Tokens never appear in this interface.

Except `accounts.list`, **every command requires an explicit configured account**. Provider message/thread IDs can collide across accounts. Never reuse a cursor, draft ID, contact or operation from another account. `accounts.list` reports enabled accounts and locally configured capabilities; successful provider authorization is checked again before network access. Private config and grant registry are not message data.

```sh
omagma cli --fixtures --cache-dir /absolute/private/mock-cache
```

Send lines such as:

```json
{"id":"accounts","cmd":"accounts.list"}
{"id":"page1","cmd":"mail.list","account":"personal@example.com","label":"INBOX","limit":100}
{"id":"read","cmd":"mail.read","account":"personal@example.com","messageId":"demo-96"}
```

## Commands

| cmd | Additional fields / result |
| --- | --- |
| accounts.list | accounts with address, enabled, capabilities |
| mail.list / search / sync | limit 1..100, query, label, cursor; returns messages and nextCursor; search selects local cache with cacheOnly:true or Gmail with false/default |
| mail.refresh | optional limit/query/label; applies a bounded history update or recent resync to the account cache |
| mail.read | messageId; decoded full text, envelope/threading fields, labels, attachments, invitation |
| mail.thread | threadId; chronological messages |
| mail.attachment | messageId, attachmentId; filename,mimeType,size,data(base64url without padding) |
| mail.open | optional messageId; explicitly opens configured Chrome profile |
| mail.reply | messageId, all:boolean; creates a local reply/reply-all draft |
| mail.send | draft, operationId; durable submission receipt |
| mail.archive / trash / restore | messageId; reversible label mutation |
| mail.mark | messageId, unread/starred booleans, addLabels/removeLabels arrays |
| draft.create / update | draft; update also requires draftId |
| draft.list / read / send / discard | read/send/discard require draftId; send also requires operationId |
| contacts.list / search | list accepts limit 1..100 and cursor; search accepts query (live up to30); contacts with resourceName,etag,name,emails and live nextCursor |
| contacts.upsert | contact; editing requires resourceName and expectedEtag or contact.etag |
| invitation.inspect | messageId; validated uid, organizer, attendee, sequence, summary,start |
| invitation.reply | messageId,status accepted/tentative/declined,operationId |
| operation.list / read | read requires operationId; recorded outcome, recovery draftId and RFC Message-ID |
| cache.stats / clear | limits/residency; clear preserves drafts,contacts,operations |
| auth.status / authorize / revoke | terminal grant; prefer one-shot terminal-auth for consent |

List/sync **one bounded page at a time** and pass nextCursor verbatim with the same account/query/label. Null means complete. Pages replace, not append into the client. Persist only what your task needs; Omagma automatically bounds its own cache. Gmail's query syntax is available live; fixtures implement only simple subject:/from:/is:unread/in:trash and substring searches.

For a local-only lookup, set `cacheOnly:true` on `mail.list`, `mail.read`, `mail.thread` or `cache.stats`. One-shot commands use `--cached`. This path does not contact Gmail and remains available while a separate client refreshes the account. Missing full bodies return `CacheMiss`; cached threads can be partial. Cached list results report cache readiness, age and partial state, and have their own account/query/generation-scoped cursors. The end of cached pagination means the end of that bounded cache view, not proof that Gmail has no more results. Provider and cache cursors are distinct; pass each only to the matching operation. Arbitrary Gmail searches require a recorded provider result rather than an invented local approximation. See [cache-first behavior](TUI-CACHE.md).

`mail.search` with `cacheOnly:true` explicitly evaluates the local cache's metadata search, without a previously recorded Gmail query or server request. Results are a partial cached subset. One-shot search uses `--cached` for local search or `--server` for Gmail. Local search uses ASCII case-insensitive substrings across subject, snippet, sender and labels; `from:`, `subject:`, `is:unread` and single `in:`/`-in:` filters are supported. It does not implement arbitrary Gmail query syntax or search uncached bodies. Local search cursors (`K`) are distinct from cached provider-view cursors (`C`) and Gmail continuations (`L`); never exchange them. A local match does not prove that uncached mailbox content lacks the query.

```json
{"cmd":"mail.list","account":"personal@example.com","label":"INBOX","limit":32,"cacheOnly":true}
{"cmd":"mail.refresh","account":"personal@example.com","label":"INBOX","limit":32}
```

Reads do not mark read. Use mail.mark explicitly if requested. There is no permanent delete. Draft bodies are plaintext UTF-8. To/Cc/Bcc accept RFC address-list strings or arrays of address objects `{address,name}`. Reply planning honors Reply-To, verified self aliases, original recipients and References; it never promotes Bcc into reply-all. Missing/invalid Message-ID returns an explicit error instead of claiming valid threading.

```json
{"cmd":"draft.create","account":"personal@example.com","draft":{"to":[{"address":"alex@example.org"}],"subject":"Demo 🌋","bodyText":"Hello!"}}
{"cmd":"draft.send","account":"personal@example.com","draftId":"USE_RETURNED_ID","operationId":"task-unique-send-1"}
```

Attachments are `{id:"",filename:"safe-basename.txt",mimeType:"text/plain",size:DECODED_BYTES,data:"BASE64URL_NO_PADDING"}` in draft.attachments. Body plus encoded attachments must fit the 3 MiB request. One-shot compose/send accept repeated `--attach-file FILE`, using application/octet-stream. Save files only to an explicitly chosen private path and treat filenames as untrusted; the attachment response itself does not write to disk.

## Side effects and uncertainty

Every send/RSVP needs a stable operationId chosen by the caller. Omagma persists an unknown receipt before dispatch and derives a stable RFC Message-ID from account+operationId. Repeating the **same account, identity and semantic content** returns the recorded receipt without another provider call. A new identity for the same unresolved draft/content also returns the existing unknown receipt, preventing accidental duplicate submission through a reopened draft. Reusing it for different content gives OperationConflict. This is a local duplicate guard, not a server-side idempotency guarantee.

Outcomes: applied=provider accepted, rejected=known failure, unknown=possibly applied. **Do not retry unknown with a new ID.** Inspect operation.read and the provider's Sent folder/search using the rfcMessageId before asking the user how to proceed. Direct sends also preserve a local recovery draft before dispatch. `draft.discard` removes a local draft, but refuses drafts referenced by an unknown operation. Such drafts also reject changed-content updates. Applied/rejected drafts may be explicitly discarded to free the 128-draft quota. Cache clear does not erase the journal. A full journal stops new sends; it never silently discards uncertain receipts. RSVP replay ignores its varying DTSTAMP but compares the semantic response.

Contact updates use CONTACT-source etags and reject conflicts. Live writes invalidate the contacts cache before submission and return the validated provider contact directly; the next contacts read refreshes the cache. Mutating transport interruption or unrecognizable provider acknowledgement is uncertain. Failure to encode a live mutation's final response is also `UnknownOutcome`, even if its error frame cannot be allocated. Refresh authoritative provider state before another mutation. The permission error occurs before provider access if the required capability is absent.

## One-shot interface

```sh
omagma mail list --account personal@example.com --label INBOX --limit 100
omagma mail search --account personal@example.com --query launch --cached
omagma mail search --account personal@example.com --query 'from:alex@example.org' --server
omagma mail read --account personal@example.com --message-id PROVIDER_ID
omagma mail reply --account personal@example.com --message-id PROVIDER_ID --all
omagma draft send --account personal@example.com --draft-id LOCAL_ID --operation-id TASK_ID
omagma mail compose --account personal@example.com --to alex@example.org \
  --subject 'A draft' --body-file /absolute/private/body.txt --attach-file /absolute/private/file.txt
omagma operation read --account personal@example.com --operation-id TASK_ID
```

Use --body-file or --body-stdin to keep content out of argv. --draft-file/--contact-file accept bounded JSON objects; combining --draft-file with compose fields or --attach-file is rejected as conflicting input. One-shot success exits 0; ordinary command errors emit an error response and exit nonzero. JSONL command errors allow the next frame, while response allocation or output failures may end the process. A live mutation's `UnknownOutcome` survives that exit path. `--help` lists flags. Never put tokens in argv, logs, shell history or agent messages.

The [HEY CLI](https://github.com/basecamp/hey-cli) and its [agent workflow guide](https://help.hey.com/article/1189-using-ai-agents-with-hey) informed the command families, full-thread reading and draft-first workflow. Omagma uses its own account-scoped Gmail implementation and capabilities.
