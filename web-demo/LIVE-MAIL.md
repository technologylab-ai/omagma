# Live mail in the browser prototype

The browser runs the same `App` workflow controller as the native TUI, with
platform adapters for the terminal, networking and storage. It uses the same Zig
Gmail request builder, message decoder,
recipient validation and MIME encoder as the native application. JavaScript
supplies HTTPS through `fetch` and keeps OAuth credentials in session memory.
WebAssembly Promise Integration suspends the Zig request while the browser
awaits its response. Gmail requests go directly from the browser to Google.
The local Zig server can supply existing native credentials to the launched
session; static hosting instead uses an exported connection file.

This is a browser adapter for a focused set of terminal workflows. Start with
inbox reading, plain/Markdown composition, replies and forwarding, Google contacts
and recipient completion. A bounded IndexedDB cache retains mail/contact
snapshots separately from credentials. Live queries fetch up to 30 messages; refine Gmail search to reach older mail.
Cache search pages through the retained 300-record inventory. The native disk cache,
external editor, local filesystem dialogs and background send queue are not part
of this browser mode. Forwarding retains bounded source files and embedded resources.

## Load existing credentials

When running `omagma server`, open its printed link and choose **Connect Gmail**.
The server reads the enabled accounts, terminal grants and refresh tokens from
the currently selected native store and supplies one bounded connection bundle
in memory. No exported file or storage migration is needed. Loading is explicit;
starting the server alone performs no credential lookup or Google request.

The printed link includes a random capability in its fragment. The page sends
that capability in an authorization header to the fixed local connection
endpoint, which checks its loopback Host and same-origin request metadata.
It does not allow cross-origin credential reads, cache the response or reflect
credential lookup failures. The server wipes its transient bundle and native
workspace after serving it. Credentials then stay in the current browser tab,
using the same scope and identity validation as file import. Keep that launched
link private; a plain link without its capability can still use file import.

Use **Load file** to select an exported connection instead. For a custom native
setup, `server --config FILE --grant-file FILE` selects the existing files.

For static hosting or a separate browser instance, export remains available.
Export one connection file using the prototype's native command:

```sh
zig build -Doptimize=debug -Dtui=false -j2 --prefix .development-export
.development-export/bin/omagma credentials export --format browser \
  --output "$HOME/.config/omagma/browser/connection.json"
```

Then choose **Connect Gmail → Select connection file** and select that file.
The command reads the existing enabled terminal grants and their credentials
from the selected native store, including Secret Service or Keychain. It makes
no Google requests and leaves that store and configuration unchanged. The
export contains refresh tokens; its canonical parent must be private, the
file is created with owner-only permissions, and an existing output is never
overwritten. Output inside a repository is refused. Custom setups can pass
`--config` and `--grant-file`.

The separate `credentials migrate --to file` command copies and verifies
credentials before switching the native store. Exporting for the browser does
not require that migration. The installed release must gain this command
before its ordinary `omagma` executable can be used; the example above builds
and uses a separate development executable.

For an existing file-backed setup, the collapsed **Use separate files**
controls also accept the Google OAuth client JSON, `terminal-grants.json` and
the matching `.token` files or token folder.

The page reads selected files locally. It does not upload them to the static
server or follow paths embedded in those files. The bundle carries the account,
client, grant and capabilities together; separate token files are paired by
their exact native filename namespace. The Google
token endpoint verifies the refresh credentials, and the Zig adapter verifies
the Gmail account profile before exposing that account's messages.

Existing grants are preserved. A read-only grant permits reading; a reply or
new message requires an explicitly declared send capability and a token with
the necessary Gmail scope. The browser does not upgrade permissions or start a
new consent flow. The native Secret Service and Keychain cannot be read by a
webpage; the local server or explicit native export supplies the selected credentials.

Credentials stay in the current browser session. Disconnect clears the active
connection and invalidates pending results. Reloading requires loading the
connection again. Browser JavaScript can access the credentials it reads, so use the
controlled local page or a deployment you trust.

## Read and reply

The browser keeps account views separate and limits each list to 30 messages.
It loads the selected message's body using the native bounded decoder.
Reading a message does not mark it read. Refresh and search use the browser
adapter's bounded request path.

Plain-text compose and reply use the terminal fields and the shared recipient
and reply-header rules. Send review displays the account and exact recipients.
Review starts with Back selected; only explicit Send begins submission.
The normal ten-second cancellation opportunity remains available before the
HTTP request starts.

`r` replies and `R` replies to all, excluding the account's verified aliases.
HTML sources offer **Keep formatting** or **Text quote**. `f` forwards with the
same choices plus **Attach original .eml**, also available for plain-text sources.
Formatted originals preserve their HTML, styling and embedded CID/Content-Location
resources below the editable note. Preview uses the shared passive semantic reader;
it never executes source HTML or retrieves remote resources. Text quotes preserve
safe literal links. Forwards retain source files and leave reply/thread headers empty.
The composer and send review show the outgoing files; `[x]` removes a file.

Source files use bounded inline storage: 2 MiB decoded data per draft, a 3 MiB
JSON envelope and an 8 MiB aggregate session draft quota. MIME/base64 overhead can
lower the effective send limit. An oversized capture or send is refused without
silently omitting files. For over-quota forward sources, **Text quote · omit files**
explicitly creates a quote without files; the omission warning stays in send review.
`.eml` sources retain the shared 2 MiB raw-message limit.
Local MIME preparation finishes before any send request or cancellation window.

Contacts need
the existing contacts capability and matching Google scope; the browser never
upgrades a grant. `a` opens the bounded contacts page, `/` searches contacts,
and Enter selects an address. Recipient completion works while typing;
Ctrl+Space searches Google when local choices do not match.

`/` in the mailbox searches the local cache; `\` searches Gmail and Ctrl+R
refreshes. The cache merges current records across folders and searches, with
up to 300 records per account and 30 visible matches. Body eviction, 3 MiB
snapshot and 8 MiB total quotas bound persistence. Cached HTML is passive source
for the native sanitized reader, never browser DOM. Restoring first verifies
the Gmail profile and exact account/client/grant; contact scope loss hides cached
contacts. Disconnect keeps these snapshots; **Clear cache** removes them.
Drafts, OAuth credentials and uncertain-send state are excluded from this cache.

Drafts stay in the tab. A failed or uncertain submission is not retried
automatically. A small generic operation receipt records that an actual send
started, so reload cannot silently clear an unconfirmed outcome. The receipt
contains no token or message body. Check Sent before explicitly clearing an
uncertain-send notice.

## HTTP boundary

The WASM module imports only the explicit browser transport and clock adapters.
The host permits fixed Google OAuth/Gmail HTTPS destinations, bounds request
and decoded response bytes, rejects redirects and applies finite request/job
deadlines. It serializes operations so suspended WASM calls cannot race over
the shared request buffers. Tokens are sent to Google's fixed endpoints and
are omitted from URLs, diagnostics and browser persistence.

The default fictional mode performs no Google requests. Live mode uses
existing user-authorized grants; synthetic acceptance tests replace Google
responses inside an owned headless browser. Those tests establish integration
behavior, not delivery to a real recipient.

Google documents [browser API calls](https://developers.google.com/identity/oauth2/web/guides/use-token-model),
[refreshing installed-client tokens](https://developers.google.com/identity/protocols/oauth2/native-app#offline)
and [Gmail message sending and replies](https://developers.google.com/workspace/gmail/api/guides/sending).
The browser suspension mechanism is documented by
[WebAssembly.Suspending](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Suspending).

## Verification

Use the repository's cooperative host lock before compilation or browser
suites. Tests use fictional client files, refresh tokens, accounts and mail;
they must never obtain real credentials or send production mail.

The ordinary browser suite covers the fictional UI. The live browser harness
intercepts the real fixed endpoint URLs and supplies independent synthetic
provider responses. It verifies file pairing, account identity, scope
restrictions, body decoding, reply MIME, explicit review/cancellation, exact
send count and uncertain-result protection. Private screenshots and receipts
belong under a scratch directory, outside the tracked source tree.

Session drafts survive leaving the composer and switching accounts within the
tab. Successful sends retire their drafts only after the shared controller
consumes the receipt. Reload and Disconnect discard remaining drafts, with a
warning when drafts exist. Pasted input is limited to 64 KiB per event; oversized
paste is skipped while keeping the session. Paste autosave happens after the
complete paste. Ctrl+C cancels reads and the send countdown; it does not abort
an already submitted send.

Switching connected accounts reads the local snapshot and cached reader only.
It does not refresh OAuth, enumerate Gmail or fetch an uncached body. First
Connect initializes an account without a snapshot; afterward use Ctrl+R to
refresh, Enter to load a missing body, or an explicit Gmail search. Empty, failed
and cleared caches remain local on account selection too.
