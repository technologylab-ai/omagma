# Omagma in a browser: WebAssembly experiment

This is an isolated showcase prototype, built from the native TUI source. Zig
owns the screen, layout and mail interaction; xterm.js supplies the browser's
terminal display and input. It starts with fictional mail and can connect
existing grants through the local server or an exported connection file for live
Gmail reading, plain or Markdown composition, replies and forwarding, contacts and recipient
completion, and a bounded browser mail cache. See [live mail](LIVE-MAIL.md) for
credential loading and scope.

The prototype runs client-side with browser HTTP and credential adapters. The
native disk cache, external editor, attachment filesystem and background send
queue remain outside this focused browser mode. Live networking requires a
browser with WebAssembly Promise Integration; fictional mode also works when
that feature is absent.

## Build and try it

Use exactly Zig 0.17.0, as required by the main application. The browser assets
are embedded in the native executable; no application backend is needed. From the
repository root, with that compiler selected on `PATH`:

On a shared host, reserve the [cooperative host lock](../docs/VERIFICATION.md#cooperative-host-measurement-lock)
before builds or the headless browser suite.

```sh
zig version
npm ci --prefix web-demo --ignore-scripts --no-audit --no-fund
zig build -Dbrowser=true -Doptimize=debug -j2 --prefix .development-wasm
.development-wasm/bin/omagma server
```

Open the URL printed by the command. The Zig server binds `127.0.0.1`, starting
at port 8766 and trying the next port when it is occupied. `--port 9000` chooses
a different starting port. The executable contains the page, bundled
JavaScript, styles, WASM and dependency licenses; it can run from any folder
without Node.js or a separate asset directory. Ctrl+C stops the server.

For static hosting, build the standalone module with `zig build browser
-Dbrowser=true` and package it with `npm run build --prefix web-demo -- --wasm
"$PWD/zig-out/web-demo/omagma.wasm"`. Any static HTTP host can serve the generated
`web-demo/dist/` folder. A `file:` URL cannot load the WASM module.

Try `j` / `k`, Enter, `1` / `2` / `3` to switch accounts, `/` for bounded cache
search, `v` for right/below layouts, `z` to expand the reader, `a` for
fictional contacts, and `?` for the native help overlay. Escape backs out;
Reset demo creates fresh fictional state. **Connect Gmail** loads one exported
connection file on a static host, or uses your configured native accounts when
opened through the server's printed link. **Load file** remains available in
server mode. Disconnect returns to fictional mode. In live mode, `c` composes,
`r` replies, `R` replies to all, and `f` forwards. Reply/forward offers the shared
source chooser: Keep formatting preserves original HTML and embedded resources,
Text quote makes an editable copy, and forwarding also offers Attach original
`.eml`, including plain-text sources. Forwarded source files are retained within
the portable inline quotas described in [live mail](LIVE-MAIL.md); they can be
removed in the composer. Compose starts in normal mode: `i` edits, Esc
returns to normal mode, Ctrl+T switches plain/Markdown, and Ctrl+S opens send review.
Tab/Shift+Tab move between fields or review buttons. Explicit Send begins the ten-second local
cancellation window. The shared help and action palette show the current platform capabilities. `T` opens the native theme
picker; browser execution has no access to the desktop's theme files.

In live mode, `a` opens granted Google contacts. Recipient fields offer local
suggestions while typing; Ctrl+Space also searches Google when a name is absent
from the retained page. `/` searches cached mail and `\` searches Gmail;
Account switching displays cached mail without Google requests. Ctrl+R explicitly
refreshes; Enter loads a missing body. First Connect initializes an uncached
account once. The cache keeps up to 300 message records per account, shows
30 matching rows, and enforces 3 MiB per snapshot / 8 MiB total. IndexedDB holds
mail and contacts, while credentials and drafts stay in tab memory. Leaving a composer saves a session
draft; open Drafts to resume it. Reload/disconnect discards session drafts. Disconnect
retains the cache; **Clear cache** removes it. Cached restores require a fresh
account verification and the exact registration/grant. Date filters use UTC.

Request activity appears in a prominent strip above the terminal, with a spinner
and an explanation when keyboard input is paused. Ctrl+C cancels an active read;
sending has its own countdown and confirmation captions. The strip reserves its
space so a pending request does not move or clip the terminal.

Focused synthetic checks:

```sh
npm test --prefix web-demo
node tests/browser_wasm.mjs --work-dir /tmp/omagma-wasm-browser
node tests/browser_wasm_live.mjs --work-dir /tmp/omagma-wasm-live-browser
zig build test-browser-export test-browser-server -Doptimize=debug -j2
```

The browser test starts its own headless Chromium and static test server,
checks real keyboard interaction and network requests, and writes private
screenshots and a receipt under the requested scratch directory. It does not
use an existing browser profile or map desktop windows.
Pass `--origin http://127.0.0.1:PORT` to either browser suite to test the native
server. `tests/browser_server.mjs --binary /absolute/path/to/omagma --site-dir
/absolute/path/to/site` checks embedded asset bytes, HTTP behavior and occupied
port fallback from an empty working directory.

## What is reused

The browser runs the native `App` workflow controller, screen renderer and
bounded state with platform and provider adapters.
Browser glue passes terminal bytes and resize events into WebAssembly, and
passes the resulting terminal frame to xterm.js. It does not recreate the mail
interface in HTML.

`src/browser.zig` exports the browser ABI. The thin `BrowserSession` in
`src/terminal/tui.zig` supplies the terminal surface and delegates input, jobs
and drawing to `App`. `src/browser_provider.zig` implements the existing
`types.Client` command envelopes for browser transport, cache and session drafts.
Native and browser providers share draft builders, validation, MIME and send
outcome rules. [Architecture and extension guidance](../docs/BROWSER-ARCHITECTURE.md). The pinned libvaxis parser, screen, text layout and renderer run in
WASM. The freestanding module imports only `env.http_request` and `env.now_ms`.
The HTTP call is suspended while browser `fetch` runs, then returns status and
bounded response bytes to the same Zig request/decoder code. OAuth credentials
stay in the host transport, outside WASM and diagnostics. The build requires
explicit `-Dbrowser=true`; ordinary native builds keep their existing entry
point and dependency selection. No WASI runtime or remote PTY is involved.

The browser terminal queries the WASM renderer's scalar-width policy through
`codepoint_width`, so xterm and the shared TUI use the same Unicode tables in
the browser's additive `wcwidth` mode. This also covers newer emoji and invisible
characters that differ from older terminal width tables. A small DOM placement
adapter gives xterm's existing styled spans their declared column positions,
including characters whose fonts ignore letter-spacing. It preserves their
text and styles, pins box-drawing glyphs individually without splitting normal
text shaping, and observes row replacements from focus, selection and hover.
The host's inset box
defines the usable grid size; margins are excluded from fitting so the right
and bottom borders remain visible.

The native executable keeps its ordinary platform entry point. A freestanding
WebAssembly module cannot open `/dev/tty`, start native processes, use the
desktop keyring or listen for the current loopback OAuth callback. Those need
browser adapters; selecting a WASM target alone is insufficient.

## Credentials at runtime

Yes. A browser file chooser can read explicitly selected files. JavaScript can
copy those bytes into exported WebAssembly memory, or provide a virtual
filesystem. File input does not give the page general access to the machine's
files, Secret Service or Keychain. A WASM linear-memory buffer is also visible
to its host JavaScript; it is not a separate secret vault.

The prototype's `credentials export --format browser --output /absolute/path`
command combines enabled terminal grants, their OAuth client and refresh
tokens into one private connection file. It reads the existing selected store
and leaves native credentials and configuration unchanged. See
[the export instructions](LIVE-MAIL.md#load-existing-credentials) for the
development build command and output requirements.

The local server uses the same collector to supply those credentials in memory
when Connect is clicked, so it needs no export file. Its random session
capability is carried in the launched URL fragment and a request header, never
in a credential endpoint URL. The endpoint permits only authenticated,
same-origin loopback reads and wipes its bounded response workspace afterward.

The Connect dialog reads that connection file into session memory. Existing
file-backed setups can also use the collapsed separate-file controls. Browser `fetch`
exchanges the refresh token; Zig verifies the Gmail profile before exposing
the account. File selection is sufficient; the files do not need to be
uploaded to a server. Read-only terminal grants permit reading, while replying
requires the declared send capability and a token with the matching scope.
The current importer uses terminal-grant files; a bar-only import path is not
implemented.

A transport-only probe on 2026-10-11 found that Google's token endpoint
accepted a localhost-origin CORS preflight and returned a CORS-readable
`invalid_client` response to a POST with entirely synthetic credentials.
The live adapter is additionally exercised through synthetic browser responses
at the fixed Google URLs. These checks establish transport/integration
behavior, not success with a particular real desktop grant or recipient
delivery. Real verification occurs when the user loads their selected files.

The browser adapter supplies token expiry handling and asynchronous HTTP
completion through Promise Integration. One operation owns the request path;
account views and drafts remain bounded in session memory. Mail/contact
snapshots have bounded IndexedDB persistence, with no tokens or draft state. A generic pending
send receipt survives reload and carries no token or message body. Full draft
recovery and queued-send persistence remain separate native/browser-storage
work.

Replies use the ordinary Gmail API. The existing MIME and reply/thread-header
logic can be reused with explicit send authorization, send review and the
current protection against retrying an uncertain outcome. Google's
[mail sending guide](https://developers.google.com/workspace/gmail/api/guides/sending)
describes the MIME/raw-message and reply requirements.

For a broadly accessible demo, an alternative browser OAuth design is:

1. Register a web OAuth client with the demo's authorized JavaScript origin.
2. Obtain a short-lived access token with the selected Gmail read and send
   scopes through Google's browser consent flow.
3. Keep it in session memory and use browser `fetch` for bounded Gmail API
   requests, returning validated results to the WASM application.
4. Request authorization again through a user gesture when the token expires.

This provides authorization without importing a desktop refresh token. Google
documents both
[web client registration](https://developers.google.com/identity/oauth2/web/guides/get-google-api-clientid)
and its [browser token model, API calls and expiration](https://developers.google.com/identity/oauth2/web/guides/use-token-model).
A public Gmail-connected demo would also need the appropriate consent-screen
and scope setup; this fictional-mail prototype needs none of it.

An alternative is a native local companion that retains credentials and talks
to a browser terminal. That could reuse more native functionality, but would
run the application on the companion rather than entirely in WebAssembly.

## Scope and safety

Default fictional mode uses no real account or credential and makes no Google
requests. Live mode uses only explicitly selected credentials and scopes;
reading does not mark mail read, and sending requires explicit review and
confirmation. Credentials stay in tab memory; bounded mail/contact snapshots
are stored in the browser cache and can be cleared explicitly.
Development checks use fictional grants and intercepted provider responses.
Build output and dependency directories are local artifacts, not a release.
