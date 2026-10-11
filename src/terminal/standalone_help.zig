//! Offline standalone argv help. Rendering reads no config, environment,
//! credentials or provider state; only the supplied stdout I/O is used.
const std = @import("std");

const Spec = struct { mode: []const u8, text: []const u8 };

const credentials_family =
    \\Credential storage
    \\
    \\Usage: omagma credentials OPERATION [OPTIONS]
    \\  status   Report the selected local credential store; no token lookup.
    \\  migrate  Copy existing grants to file/keyring storage, then switch config.
    \\  export   Write one private browser connection file from the current store.
    \\Without an operation, credentials defaults to status.
    \\
    \\Shared options:
    \\  --config FILE      Private config; default $XDG_CONFIG_HOME/omagma/config.json
    \\                     or $HOME/.config/omagma/config.json.
    \\  --grant-file FILE  Terminal registry override for migration/export; default
    \\                     $XDG_CONFIG_HOME/omagma/terminal-grants.json or
    \\                     $HOME/.config/omagma/terminal-grants.json.
    \\  --json             JSON output instead of human-readable status.
    \\
    \\Default store: keyring (Linux Secret Service, macOS native Keychain).
    \\Explicit file storage uses owner-only, unencrypted refresh-token files.
    \\The same TUI/CLI binary uses either store. File storage avoids Keychain
    \\audit-session restrictions but does not grant agent file/network permissions.
    \\
    \\Choose scoped help before changing storage:
    \\  omagma credentials status --help
    \\  omagma credentials migrate --help
    \\  omagma credentials export --help
    \\
    \\Example (private path; no mailbox operation):
    \\  omagma credentials status --config /absolute/private/config.json --json
    \\
;

const credentials_status =
    \\Credential storage status
    \\
    \\Usage: omagma credentials status [--config FILE] [--grant-file FILE] [--json]
    \\  --config FILE      Private config; default $XDG_CONFIG_HOME/omagma/config.json
    \\                     or $HOME/.config/omagma/config.json.
    \\  --json             JSON instead of the default human-readable report.
    \\  --grant-file FILE  Accepted by the shared parser; status does not read it.
    \\
    \\Reads the private configuration and reports credentialStore and
    \\credentialDirectory. It does not look up tokens, contact Google, create
    \\credential directories or establish that credentials work in this context.
    \\Use terminal-auth status and actual authorized mail/contact reads to verify
    \\the intended terminal/agent execution context. --to and --directory are invalid.
    \\
    \\JSON fields: ok, credentialStore, credentialDirectory, copiedCredentials,
    \\sourceCopiesRetained, restartRequired. Status copies nothing and requires
    \\no restart. The default store is keyring; file tokens are unencrypted.
    \\
    \\Example:
    \\  omagma credentials status --config /absolute/private/config.json --json
    \\
;

const credentials_migrate =
    \\Migrate existing credential storage
    \\
    \\Usage: omagma credentials migrate --to file|keyring [OPTIONS]
    \\  --to STORE         Required: file or keyring.
    \\  --directory ABS    File target only; default is credentials/ under the
    \\                     canonical config parent. Must be an absolute private path.
    \\  --config FILE      Default $XDG_CONFIG_HOME/omagma/config.json or
    \\                     $HOME/.config/omagma/config.json.
    \\  --grant-file FILE  Default $XDG_CONFIG_HOME/omagma/terminal-grants.json or
    \\                     $HOME/.config/omagma/terminal-grants.json. Reuse any override.
    \\  --json             JSON instead of the default human-readable report.
    \\
    \\Copies existing read-only/bar and terminal credentials for configured accounts
    \\using their existing registration/grant identities, without Google consent or
    \\mail/contact requests. Run where the source is accessible; on Mac, normally
    \\an unlocked local terminal. An agent session may not have Keychain access.
    \\
    \\Verifies destination values and known absences before atomically switching the
    \\private config. Source copies remain. Later migrations use the current store
    \\and registry so retained copies cannot restore locally revoked credentials.
    \\A failure can leave private destination copies without switching the config.
    \\Selecting the same store/directory is a no-op. Restart running sessions after
    \\a real switch; inspect restartRequired in JSON output.
    \\
    \\File directories use 0700 and token files 0600, with no application encryption.
    \\Only safe ancestors permit creation of the leaf/account directories; unsafe
    \\existing owners, modes, ACLs or symlinks are refused rather than repaired.
    \\Keep credentials outside Git/shared folders. Migrating back to keyring does
    \\not encrypt or remove retained file copies. Sandbox permissions remain separate.
    \\
    \\JSON fields: ok, credentialStore, credentialDirectory, copiedCredentials,
    \\sourceCopiesRetained, restartRequired. No token contents are printed.
    \\
    \\Examples (reuse your private config and grant registry):
    \\  omagma credentials migrate --to file --config /absolute/private/config.json
    \\  omagma credentials migrate --to file --directory /absolute/private/credentials --config /absolute/private/config.json --grant-file /absolute/private/grants.json --json
    \\  omagma credentials migrate --to keyring --config /absolute/private/config.json
    \\
;

const credentials_export =
    \\Export a browser connection file
    \\
    \\Usage: omagma credentials export --format browser --output ABS [OPTIONS]
    \\  --format browser   Required export format.
    \\  --output ABS       New JSON file in a canonical, owner-only 0700 directory.
    \\                     Existing files and symlinks are never replaced.
    \\  --config FILE      Reuse your private account config; default is unchanged.
    \\  --grant-file FILE  Reuse your terminal grant registry; default is unchanged.
    \\  --json             Print a summary only, never the exported credentials.
    \\
    \\Exports enabled, configured terminal grants and matching OAuth clients from
    \\the current keyring/file credential store. The output is one unencrypted
    \\owner-only 0600 file containing connection credentials. Keep it outside Git
    \\and shared folders; select it in the browser's Connect Gmail screen.
    \\
    \\No Google requests, consent, mail operations, migration or config changes.
    \\The selected store remains unchanged. On Mac with native Keychain storage,
    \\run in an unlocked local terminal. Existing explicit file storage also works.
    \\Use credentials migrate --to file only when you want to change native storage.
    \\
    \\Example:
    \\  omagma credentials export --format browser --output /absolute/private/browser/connection.json
    \\
;

const bar_fixture_options =
    \\
    \\Expanded shared bar parser options:
    \\  --fixtures                    Built-in fictional provider/config defaults.
    \\  --dry-run-open                Daemon browser actions return argv; no launch.
    \\  --fixture-delay-ms MS         Fixture job delay, 0..4294967295; default 0.
    \\  --fixture-fail-account ADDRESS Fixture jobs fail for this address; default none.
    \\  --fixture-empty-account ADDRESS Empty fixture page for this address; default none.
    \\  --fixture-rows N              0..30 fixture rows; default 8.
    \\  --fixture-fail-after N        Fail after N jobs per account; default no limit.
    \\                                N is an unsigned 64-bit integer; 0 fails all jobs.
    \\  --fixture-auto-refresh-ms MS  1..60000; requires --fixtures; overrides the
    \\                                configured refresh interval. Default: no override.
    \\Fixture timing/failure/row options affect the daemon fixture provider only.
    \\Fixture mail avoids Gmail/keyring requests; browser opening still needs
    \\--dry-run-open to suppress launches. These flags do not simulate or suppress
    \\auth consent. --dry-run-open is not an auth dry run.
    \\
;

const specs = [_]Spec{
    .{ .mode = "server", .text =
    \\Serve the bundled browser mail client
    \\
    \\Usage: omagma server [--port PORT] [--config FILE] [--grant-file FILE]
    \\  --port PORT   First port to try, 1..65535; default 8766.
    \\  --config FILE      Existing private Omagma config; uses the usual default.
    \\  --grant-file FILE  Existing terminal registry; uses the usual default.
    \\
    \\Starts a Zig HTTP server on 127.0.0.1 and prints its local URL.
    \\If the port is occupied, tries successive ports until one is available.
    \\The page, JavaScript, styles and WebAssembly are embedded in the executable.
    \\No separate static server or runtime asset folder is needed. Ctrl+C stops it.
    \\Starts with sample mail; Connect Gmail loads your configured Omagma accounts
    \\directly from the selected native credential store. No export is required.
    \\The printed link contains a random session capability for this connection.
    \\Credentials travel only to that browser session and Google, stay in tab
    \\memory, and are cleared on disconnect. Native storage/config remain intact.
    \\Load file remains available for an exported browser connection file.
    \\
    \\Requires a browser-enabled build. Help reads no credentials and starts no server.
    \\
    \\Examples:
    \\  omagma server
    \\  omagma server --port 9000
    \\
    },
    .{ .mode = "daemon", .text =
    \\Read-only Gmail bar backend (Linux)
    \\
    \\Usage: omagma daemon [--config FILE] [--fixtures] [--dry-run-open]
    \\  --config FILE    Private account config; default $XDG_CONFIG_HOME/omagma/config.json
    \\                   or $HOME/.config/omagma/config.json when present.
    \\  --fixtures       Use built-in fictional mail instead of Gmail/keyring.
    \\  --dry-run-open   Report a browser target rather than launching Chrome.
    \\  --account ADDRESS Accepted by the shared parser; does not select/filter accounts.
    \\                   Configure enabled/required accounts in the config instead.
    \\
    \\Long-running bar protocol: JSON requests on stdin, replies/events on stdout.
    \\This differs from omagma cli's terminal JSONL API. Uses one bounded worker,
    \\up to three separate accounts and 30 Inbox metadata/snippet rows per account.
    \\No full bodies/attachments, read-state/label changes or mail sends. Mail is
    \\retained only in process memory. Explicit open actions use the account's Chrome
    \\profile; disconnect removes its local read-only token, not Google's grant.
    \\
    \\Live fetching uses the configured read-only registration/selected credential
    \\store. config.refreshIntervalSeconds defaults to 0 (no automatic refresh);
    \\60..86400 enables periodic refresh even while the popup is closed. Other
    \\interactive refreshes follow popup/account requests. Closing stdin ends the
    \\protocol after bounded pending work/receipts are handled.
    \\Without an existing default config, fictional config defaults can be shown;
    \\they do not establish a connected live account. Daemon runtime is Linux-only.
    \\
    \\Examples:
    \\  omagma daemon --config /absolute/private/config.json
    \\  printf '%s\n' '{"id":1,"cmd":"status"}' | omagma daemon --fixtures --dry-run-open
    \\
    },
    .{ .mode = "auth", .text =
    \\Authorize one read-only Gmail bar account
    \\
    \\Usage: omagma auth --account ADDRESS [--config FILE]
    \\  --account ADDRESS Required configured, enabled account; authorize one at a time.
    \\  --config FILE     Private config; if omitted, an existing default config is
    \\                    required at $XDG_CONFIG_HOME/omagma/config.json or
    \\                    $HOME/.config/omagma/config.json.
    \\
    \\Uses config.oauthClientFile (Desktop registration), the existing named Chrome
    \\profile and gmail.readonly scope. Opens Google consent/loopback callback with
    \\PKCE/state checks and verifies the returned Gmail identity. Complete consent
    \\within 180 seconds; wait for the command to finish successfully after callback.
    \\Stores a refresh token in the selected keyring/file backend. File tokens are
    \\owner-only and unencrypted. Reconnecting requires the user's Google approval.
    \\
    \\This read-only grant can browse mail; it does not grant terminal send/modify,
    \\contacts or RSVP capabilities. Run: omagma terminal-auth authorize --help
    \\Authorization changes local credentials but sends no mail and changes
    \\no contacts. The shared bar fixture flags below are not an auth preview mode.
    \\
    \\Example (replace the fictional address with your configured account):
    \\  omagma auth --account personal@example.com --config /absolute/private/config.json
    \\
    },
    .{ .mode = "status", .text =
    \\Read-only bar configuration snapshot
    \\
    \\Usage: omagma status [--config FILE] [--fixtures]
    \\  --config FILE     Private config; default $XDG_CONFIG_HOME/omagma/config.json
    \\                    or $HOME/.config/omagma/config.json when present.
    \\  --fixtures        Skip automatic default-file loading; explicit --config still loads.
    \\  --account ADDRESS Accepted but does not filter the account array.
    \\
    \\Returns one JSON document with version:1 and accounts[]. It loads configuration
    \\into a fresh process snapshot; it does not query a running daemon, look up
    \\credentials or contact Gmail. State/unread/checkedAt/messages are not a live
    \\connectivity report. Without an existing config it uses fictional defaults.
    \\To inspect a running bar, use its daemon protocol status request. To inspect
    \\terminal grants use omagma terminal-auth status --help; to inspect selected
    \\storage use omagma credentials status --help.
    \\
    \\Examples:
    \\  omagma status --config /absolute/private/config.json
    \\  omagma status --fixtures
    \\
    },
    .{ .mode = "cache-refresh", .text =
    \\One-pass read-only terminal cache refresh
    \\
    \\Usage: omagma cache-refresh [OPTIONS]
    \\  --config FILE       Default $XDG_CONFIG_HOME/omagma/config.json or
    \\                      $HOME/.config/omagma/config.json; required for live use.
    \\  --cache-dir DIR     Default $XDG_CACHE_HOME/omagma/terminal or
    \\                      $HOME/.cache/omagma/terminal; private local cache.
    \\  --interval SECONDS  60..86400; default 300. Freshness/coalescing policy,
    \\                      not a repeat timer: this command runs one pass and exits.
    \\  --force             Bypass age-based skipping, but respect another refresh lease.
    \\  --quiet             Suppress the default JSON result on stdout.
    \\  --prefetch-bodies N  0..64; default 32. Zero refreshes metadata only.
    \\  --metadata-limit N  1..10000; initial default 2000 retained metadata rows.
    \\  --disk-limit-bytes N 65536..1073741824; initial default 268435456 (256 MiB).
    \\
    \\Visits configured enabled accounts sequentially, with an Inbox metadata page
    \\of 32 and the selected bounded body head. Always uses the read-only/bar grant,
    \\even with --force: a broader terminal grant alone is insufficient. It never
    \\opens consent, sends mail, marks read or changes mailbox/contact data.
    \\Updates private metadata/body/history state; old-tail eviction respects quotas
    \\and preserves drafts/contacts/submission receipts. Saved account quotas take
    \\precedence during automatic refresh; --force permits explicitly supplied quota
    \\options to be applied. Omitted options preserve the saved quota policy.
    \\
    \\Automatic runs can skip a sufficiently fresh complete cache within roughly
    \\half the interval, or coalesce with another account refresh. --force does not
    \\start a duplicate job while that lease is held. Signal interruption stops the
    \\owned work; there is no automatic send processing or background-service install.
    \\
    \\Default output: version, ok, interrupted, slots[{slot,outcome}]. Slots are
    \\1-based config positions. Outcomes: refreshed, fresh, in_progress, auth_needed,
    \\offline, local_failure. No account identifiers or mail contents are printed.
    \\ok:true/exit success may include offline/auth_needed slots; inspect each outcome.
    \\A local_failure makes the command fail. Diagnostics/errors can still use stderr
    \\with --quiet. --account and --grant-file are not accepted by this command.
    \\
    \\Expanded disconnected fixture options:
    \\  --fixtures          Synthetic provider; no Google/keyring calls.
    \\  --fixture-root DIR  Optional synthetic corpus root; requires --fixtures.
    \\  --fixture-scenario NAME  Synthetic scenario, default normal. Non-normal
    \\                           scenarios require --fixtures; '/' is rejected.
    \\Use a private separate --cache-dir; live and fixture storage are distinct.
    \\
    \\Examples:
    \\  omagma cache-refresh --config /absolute/private/config.json --interval 300 --quiet
    \\  omagma cache-refresh --config /absolute/private/config.json --force --prefetch-bodies 0
    \\  omagma cache-refresh --fixtures --cache-dir /absolute/private/mock-cache --force --prefetch-bodies 0
    \\
    },
    .{ .mode = "version", .text = version_help },
    .{ .mode = "--version", .text = version_help },
    .{ .mode = "build-info", .text =
    \\Executable build identity
    \\
    \\Usage: omagma build-info
    \\No command-specific options or account setup are needed.
    \\Returns JSON fields version, zigVersion and optimizeMode from this executable.
    \\This identifies the actual binary; it does not attest that checks passed or
    \\describe live account/credential status. Reads no config or network.
    \\
    \\Example:
    \\  omagma build-info
    \\
    },
    .{ .mode = "budget", .text =
    \\Compiled fixed backend reservation
    \\
    \\Usage: omagma budget
    \\No command-specific options or account setup are needed.
    \\Returns JSON: reservationBytes, assignedBytes, unassignedBytes, httpBytes,
    \\daemonBytes, gmailBytes, oauthBytes and platformBytes.
    \\The fixed application reservation is 16 MiB. These are compiled storage
    \\allocations, not measured process RSS/PSS, total terminal heap or cache size.
    \\No mail/config/credential reads or network requests occur.
    \\
    \\Example:
    \\  omagma budget
    \\
    },
    .{ .mode = "probe-http", .text =
    \\Developer loopback HTTP probe
    \\Usage: omagma probe-http http://127.0.0.1:PORT/PATH
    \\One unauthenticated loopback GET to a separately owned synthetic server.
    \\Returns bounded transport status/body-byte/error/timing metrics as JSON.
    \\No account configuration or OAuth credentials are used; the probe makes a request.
    \\Example: omagma probe-http http://127.0.0.1:8080/probe
    \\
    },
    .{ .mode = "probe-http-bearer", .text =
    \\Developer synthetic-bearer HTTP probe
    \\Usage: omagma probe-http-bearer http://127.0.0.1:PORT/PATH
    \\Loopback-only request with a fixed synthetic bearer, not a real OAuth token.
    \\Returns bounded transport metrics as JSON. Requires a separately owned test server.
    \\Example: omagma probe-http-bearer http://127.0.0.1:8080/probe
    \\
    },
    .{ .mode = "probe-https", .text =
    \\Developer unauthenticated HTTPS probe
    \\Usage: omagma probe-https
    \\Requests Google's fixed Gmail profile endpoint with no account token;
    \\an unauthorized response is expected. No positional URL or account setup is needed.
    \\Returns transport metrics, not mail. This probe does contact Google.
    \\Example: omagma probe-https
    \\
    },
    .{ .mode = "probe-terminal-http", .text =
    \\Developer bounded terminal-upload probe
    \\Usage: omagma probe-terminal-http http://127.0.0.1:PORT/PATH
    \\POSTs a fixed 128 KiB synthetic body to an owned loopback server with a fixed
    \\synthetic bearer and bounded 3 MiB response buffer. No real account token/mail.
    \\Returns transport metrics as JSON; this is a request, not offline status.
    \\Example: omagma probe-terminal-http http://127.0.0.1:8080/probe
    \\
    },
    .{ .mode = "probe-terminal-http-oversize", .text =
    \\Developer terminal-upload limit probe
    \\Usage: omagma probe-terminal-http-oversize http://127.0.0.1:PORT/PATH
    \\Exercises rejection of a synthetic 3 MiB + 1 byte JSON upload using an owned
    \\loopback target. No account token, mail or normal user setup is involved.
    \\Returns transport error/size/timing metrics as JSON.
    \\Example: omagma probe-terminal-http-oversize http://127.0.0.1:8080/probe
    \\
    },
    .{ .mode = "probe-label-http", .text =
    \\Developer label-response boundary probe
    \\Usage: omagma probe-label-http METHOD http://127.0.0.1:PORT/PATH
    \\METHOD must be POST, PATCH or DELETE (uppercase).
    \\Uses fixed synthetic probe credentials/body and an owned loopback test server;
    \\no Gmail mailbox or real account token. Returns ok/status/bodyBytes/errorCode JSON.
    \\Requires exactly the method and URL positional arguments.
    \\Example: omagma probe-label-http DELETE http://127.0.0.1:8080/probe
    \\
    },
    .{ .mode = "probe-callback", .text =
    \\Developer synthetic OAuth callback probe
    \\Usage: omagma probe-callback
    \\Exercises an owned local callback listener with synthetic inputs, without Google
    \\consent or real account credentials. Returns bounded probe success/resource JSON.
    \\Example: omagma probe-callback
    \\
    },
    .{ .mode = "probe-keyring", .text =
    \\Developer synthetic credential-store probe
    \\Usage: omagma probe-keyring
    \\Creates, reads and clears synthetic test credentials and exercises refusal paths.
    \\Run only in a separate test keyring/session context; it is not a live account check.
    \\Returns probe success and childPeakRssBytes JSON; no real token contents.
    \\Example (already isolated test credential context): omagma probe-keyring
    \\
    },
    .{ .mode = "probe-keyring-upgrade", .text =
    \\Developer native Mac Keychain upgrade probe
    \\Usage: omagma probe-keyring-upgrade PHASE DIRECTORY
    \\PHASE: create, check, verify, clear, absent, write or delete.
    \\Uses synthetic probe items and a private owned test directory to exercise
    \\cross-build Keychain operations. macOS-only; not normal account onboarding.
    \\Requires exactly two positional arguments and an isolated qualification context.
    \\Example: omagma probe-keyring-upgrade check /absolute/private/synthetic-probe
    \\
    },
};

const version_help =
    \\Installed application version
    \\
    \\Usage: omagma version | omagma --version
    \\No command-specific options or account setup are needed.
    \\Prints omagma followed by the version compiled into this executable.
    \\Reads no config, credentials or network. Use build-info for compiler/build mode.
    \\
    \\Examples:
    \\  omagma --version
    \\  omagma version
    \\
;

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

pub fn known(mode: []const u8) bool {
    if (eq(mode, "credentials")) return true;
    for (specs) |spec| if (eq(mode, spec.mode)) return true;
    return false;
}

fn content(mode: []const u8, verb: ?[]const u8) ![]const u8 {
    if (!known(mode)) return error.UnknownMode;
    if (eq(mode, "credentials")) {
        const operation = verb orelse return credentials_family;
        if (eq(operation, "status")) return credentials_status;
        if (eq(operation, "migrate")) return credentials_migrate;
        if (eq(operation, "export")) return credentials_export;
        return error.UnknownCommand;
    }
    if (verb != null) return error.UnknownCommand;
    for (specs) |spec| if (eq(mode, spec.mode)) return spec.text;
    unreachable;
}

pub fn render(io: std.Io, mode: []const u8, verb: ?[]const u8) !void {
    // Resolve the complete supported target before any stdout write.
    const text = try content(mode, verb);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    if (eq(mode, "daemon") or eq(mode, "auth") or eq(mode, "status")) try writer.interface.writeAll(bar_fixture_options);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
