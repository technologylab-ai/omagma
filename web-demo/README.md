# Omagma in a browser: WebAssembly experiment

This is an isolated showcase prototype, built from the native TUI source. Zig
owns the screen, layout and demo interaction; xterm.js supplies the browser's
terminal display and input. The mailbox is fictional and stays in memory.

The prototype proves that the existing interface can run client-side. It is
not the complete native application: the native network worker, OAuth,
credential stores, disk cache, external editor and attachment filesystem are
outside this demo.

## Build and try it

Use exactly Zig 0.17.0, as required by the main application. The browser assets
are served as ordinary static files; no application backend is needed. From the
repository root, with that compiler selected on `PATH`:

On a shared host, reserve the [cooperative host lock](../docs/VERIFICATION.md#cooperative-host-measurement-lock)
before builds or the headless browser suite.

```sh
zig version
zig build browser -Dbrowser=true -Doptimize=debug -j2 --prefix .development-wasm
npm ci --prefix web-demo --ignore-scripts --no-audit --no-fund
npm run build --prefix web-demo -- --wasm "$PWD/.development-wasm/web-demo/omagma.wasm"
python3 -m http.server 8766 --bind 127.0.0.1 --directory web-demo/dist
```

Open `http://127.0.0.1:8766/`. The Python command is an ordinary static-file
preview tool, not an application backend. Any static HTTP host can serve the
generated `web-demo/dist/` folder. Opening `index.html` as a `file:` URL does
not work because the browser needs to fetch the WASM module.

Try `j` / `k`, Enter, `1` / `2` / `3` to switch accounts, `/` for a local
substring search, `v` for right/below layouts, `z` to expand the reader, `a` for
fictional contacts, and `?` for the native help overlay. Escape backs out;
Reset demo creates fresh fictional state. Native help documents the full
application, while this demo implements the subset described here. Actions
outside the demo explain that they are unavailable. `T` opens the native theme
picker; browser execution has no access to the desktop's theme files.

Focused synthetic checks:

```sh
npm test --prefix web-demo
node tests/browser_wasm.mjs --work-dir /tmp/omagma-wasm-browser
```

The browser test starts its own headless Chromium and static test server,
checks real keyboard interaction and network requests, and writes private
screenshots and a receipt under the requested scratch directory. It does not
use an existing browser profile or map desktop windows.

## What is reused

The boundary is the native TUI's screen renderer plus bounded
synthetic state, with a browser-specific entry point and event adapter.
Browser glue passes terminal bytes and resize events into WebAssembly, and
passes the resulting terminal frame to xterm.js. It does not recreate the mail
interface in HTML.

`src/browser.zig` exports the browser ABI; `BrowserDemo` in
`src/terminal/tui.zig` owns the synthetic fixture adapter and calls the shared
`App.draw`. The pinned libvaxis parser, screen, text layout and renderer run in
WASM. The module is freestanding and has no host imports. The build requires
explicit `-Dbrowser=true`; ordinary native builds keep their existing entry
point and dependency selection. No WASI runtime or remote PTY is involved.

The browser uses xterm's pinned Unicode 11 width provider so stars, rockets,
CJK text and combining accents agree with the native renderer's current
`wcwidth` mode in these fixtures. This does not establish complete agreement
with the native library's newer Unicode tables. The terminal host's inset box
defines the usable grid size; margins are excluded from fitting so the right
and bottom borders remain visible.

The native executable keeps its ordinary platform entry point. A freestanding
WebAssembly module cannot open `/dev/tty`, start native processes, use the
desktop keyring or listen for the current loopback OAuth callback. Those need
browser adapters; selecting a WASM target alone is insufficient.

## Could credentials be supplied at runtime?

Yes. A browser file chooser can read explicitly selected files. JavaScript can
copy those bytes into exported WebAssembly memory, or provide a virtual
filesystem. File input does not give the page general access to the machine's
files, Secret Service or Keychain. A WASM linear-memory buffer is also visible
to its host JavaScript; it is not a separate secret vault.

Omagma's desktop OAuth client file, grant metadata and refresh-token files have
different roles. Loading the client file alone does not authorize a mailbox.
Loading the other files would still require replacing the native credential
lookup, HTTP transport and token-refresh paths, and verifying that the chosen
OAuth client/flow works from the browser origin. The native file backend's
ownership, permissions and canonical-path checks have no direct equivalent in
a user-selected browser file.

For a private live showcase, a **Load local credentials** button is a feasible
extension. It would read the selected OAuth client JSON, account/grant
metadata and matching token files into session memory, exchange the refresh
token using browser `fetch`, and verify the returned Gmail profile before
enabling that account. File selection is sufficient; the files do not need
to be uploaded to a server. Importing a read-only bar grant would allow
reading, while replying requires the matching terminal grant's send scope.

A transport-only probe on 2026-10-11 found that Google's token endpoint
accepted a localhost-origin CORS preflight and returned a CORS-readable
`invalid_client` response to a POST with entirely synthetic credentials.
This establishes the transport path, not success with a real desktop client
or refresh token. A real exchange remains a separate, user-authorized check.

The provider port still needs browser HTTP completion events, token expiry
handling and bounded cache/draft storage. The native worker's synchronous I/O
and file-backed executor cannot be enabled just by adding a file chooser.
A cooperative browser adapter can expose pending work to JavaScript and accept
its asynchronous results, while reusing the existing decoding, MIME, draft and
TUI logic. Session-only storage would be sufficient for a first live demo;
recovery and queued-send state need an explicit browser persistence design.

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

No real account, OAuth token, grant or local mail cache is used. No mail is sent
and no contact or mailbox is changed. Refresh restores fictional state. The
prototype does not request credentials or persist mail in browser storage.
Build output and dependency directories are local artifacts, not a release.
