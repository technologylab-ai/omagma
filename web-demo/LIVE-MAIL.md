# Live mail in the browser prototype

The browser mode uses the same Zig Gmail request builder, message decoder,
recipient validation and MIME encoder as the native application. JavaScript
supplies HTTPS through `fetch` and keeps OAuth credentials in session memory.
WebAssembly Promise Integration suspends the Zig request while the browser
awaits its response. A local static file server is sufficient; there is no
mail proxy or application server.

This is a browser adapter for a focused set of terminal workflows. Start with
inbox reading, plain-text composition and replies. The native disk cache,
external editor, attachment files and background send queue are not part of
this first live mode.

## Load existing credentials

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
webpage; the explicit native export supplies the selected credentials.

Credentials stay in the current browser session. Disconnect clears the active
connection and invalidates pending results. Reloading requires loading the
connection file again. Browser JavaScript can access the credentials it reads, so use the
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
