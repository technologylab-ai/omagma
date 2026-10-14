# Native encrypted vault

The native vault keeps retained mail, drafts, attachment blobs, operation receipts,
account configuration, grants, OAuth clients, refresh tokens and UI preferences
in authenticated encrypted records. One `omagma` process owns the unlocked key.
CLI and TUI clients use its private Unix socket, including from an SSH session
under the same operating-system user.

This optional native workflow requires Omagma 0.2.9 or later. Migration and
activation are explicit choices. Development tests use fictional accounts and
never migrate an existing user's files or activate a live vault.

## Inspect and migrate

Choose a **new** durable directory outside the disposable cache. Inventory and
migration take explicit source paths. `--source-ui` is optional when no UI file
exists. The config's selected `credentialStore` determines which credential
backend migration reads; there is no fallback to another backend.

```console
omagma vault inventory \
  --source-config /private/omagma/config.json \
  --source-grants /private/omagma/terminal-grants.json \
  --source-cache /private/omagma-cache/terminal \
  --source-ui /private/omagma/ui.json

omagma vault migrate --vault-dir /private/omagma-vault \
  --source-config /private/omagma/config.json \
  --source-grants /private/omagma/terminal-grants.json \
  --source-cache /private/omagma-cache/terminal \
  --source-ui /private/omagma/ui.json
```

Inventory reads public config/grant metadata and retained account files. It does
not retrieve refresh tokens or Desktop-client secrets; client files still undergo
private-file and size checks. Missing cache namespaces or configured account
indexes and missing grants are errors. Migration also refuses missing enabled
terminal credentials when it captures the selected credential backend.
For an intentionally empty setup, opt in with `--allow-empty-cache`,
`--allow-missing-grants`, or `--allow-missing-tokens` as applicable. The same
choices must be supplied when resuming. Migration may create the
ordinary source lock/lease files, but it does not change or clean up source mail,
drafts, queues, preferences or credentials. Stop other writers first. Unknown
files and unfinished send/download staging require review before migration.

Before prompting, migration validates the source, checks encrypted index/disk
capacity, captures the explicitly selected credentials, and reports per-account
mail, draft and queued-send counts plus grant/credential totals. It holds source
leases throughout planning, copying and final verification. Destination disk
policy may increase within the hard limit to cover encryption and atomic index
replacement; source policies and files remain untouched. Paths are normalized
before prompting, including relative paths and trailing separators.

Migration reads the new password from `/dev/tty` without echo. It then displays a
recovery key locally and asks you to enter that key before publishing any vault
files. Save it separately: it can unlock every account in this vault. Passwords
and recovery keys are not accepted in arguments, environment variables, standard
input JSON or logs. The vault stores authenticated encrypted key slots with KDF
parameters and random salts, not a separate password hash or verifier.
Password slots use Argon2id to derive the wrapping key. Key slots and stored
records use XChaCha20-Poly1305 authenticated encryption; unlocking authenticates
the encrypted key material before the vault can serve requests.

The bounded encrypted journal records source-state hashes and the destination
handle for each object before copying begins. A restart authenticates and verifies
existing ciphertext before reusing it. To resume an interrupted copy, repeat the
same migration command with `--resume`; enter the existing vault password. Changed
source data stops the resume rather than combining different snapshots. Keep
that incomplete vault for recovery and start a new migration in a new directory. An
incomplete vault cannot serve mail or become active.

Original message/draft IDs, revisions, operation receipts and queue outcomes are
preserved. Imported queued sends gain `resumeRequired: true`; their original
state and clocks remain recorded. They need a fresh explicit review and
`queue.resume` or `queue.send-now`. Unknown and submitting outcomes are never
replayed automatically.

**The plaintext source remains after migration.** Migration neither deletes it
nor claims to erase earlier backups, editor files or credential exports. Review
and retire those separately after checking the vault and your recovery copy.
Explicit attachment saves, mail exports and external-editor files are plaintext
outputs outside the vault; choose their locations and retention deliberately.

## Activate, serve and unlock

Activation independently verifies the complete destination against its encrypted
migration manifest, then compares any available source account indexes while
holding their leases. Changed source state refuses activation. If the source was
intentionally moved or removed, `--allow-unavailable-source` explicitly accepts
that freshness cannot be checked; the result reports this limitation. It never
overrides a changed available source. An existing activation for another vault
is refused.

```console
omagma vault activate --vault-dir /private/omagma-vault
omagma vault start --vault-dir /private/omagma-vault
```

`start` launches the same executable in the background and checks that the
responding daemon owns the requested vault, detecting a child that exits before
binding its socket. Once activated, `start`, `serve` and the control commands
default to the marker’s vault directory and socket. It starts locked; repeated start for
the same running vault is harmless. For a managed terminal or service, use
`serve --vault-dir PATH` to stay in the foreground. In a local terminal:

```console
omagma vault unlock
omagma vault status
omagma accounts list
omagma tui
```

After explicit activation, ordinary native CLI and TUI entry points route through
the same daemon. A plaintext session opened earlier refuses its next command after
activation, so restart that session. A missing or locked daemon fails closed. Explicit conflicting
plaintext config/cache options do not bypass activation. `--backend PATH` is the
explicit transport override used for isolated fixtures and diagnostics.

Activation applies to the native CLI and TUI. The existing read-only bar keeps
its separate configuration and selected keyring or file credentials. If you
continue using the bar, those legacy files and credentials remain in use;
activating the native vault neither migrates the bar nor erases its source files.

The default socket is `/tmp/omagma-UID/daemon.sock` on Linux and
`/private/tmp/omagma-UID/daemon.sock` on macOS, inside a private owner-only
directory. It does not depend on `HOME` or `XDG_RUNTIME_DIR`, so SSH clients find
the same owner. Both ends validate the peer UID. This is a same-user service, not
a boundary between mutually untrusted programs running under that UID.

```console
omagma vault lock
omagma vault stop
```

Lock interrupts a running authorization or network job, waits for its cleanup,
and wipes the unlocked key, identity snapshot and access-token cache. A mutation
interrupted after admission can report `UnknownOutcome`; inspect its saved
operation receipt and do not automatically repeat it. Long OAuth consent has its
own bounded deadline. A stalled client cannot retain a plaintext response
indefinitely. Unlock uses a temporary 64 MiB password-derivation mapping, which is
wiped and released. While unlocked, the owner can reuse a bounded access-token
cache; network requests still use the single bounded worker. Lock, stop and a
process restart require unlocking again.

Opening, replying to or forwarding mail can cancel the TUI's own background
refresh. Closing that refresh connection cancels only that refresh and waits for
its cleanup before the next action. Disconnecting after submitting a draft or
provider mutation does not cancel or replay it; inspect the recorded outcome.

## Password and recovery changes

While unlocked, replace the password or recovery key with:

```console
omagma vault password
omagma vault recovery-key
```

The new password is entered twice. A new recovery key is displayed and confirmed
before its slot changes. To reset a forgotten password, start the daemon locked
and run:

```console
omagma vault recover
```

Enter the recovery key locally, then choose and confirm a new password. The
catalog and identity must authenticate before recovery succeeds. Changing these
slots does not re-encrypt all mail with a new data key. Both managed header copies
retire the previous slot after success; previously copied vault backups retain
their old slots.

Back up the complete locked vault directory, including both header copies,
records and migration journal. Copying only the headers is not a mail backup.

If initialization was interrupted before either header existed, this explicit
command resets only a directory carrying the initialization marker:

```console
omagma vault discard-init --vault-dir /private/omagma-vault
```

It asks for local confirmation and moves unreachable ciphertext into a private
sibling directory, reporting that retained path. It refuses any existing header
or unrecognized layout, and never deletes the retained records.

## Development acceptance

Use Zig 0.17.0 and the cooperative host lock described in `VERIFICATION.md`.
`src/vault_daemon_tests.zig` covers socket ownership, recovery controls and
cancellation allocation ownership. `src/vault_migration_tests.zig` covers the
sealed journal and migration boundaries. `tests/vault_daemon.py` exercises actual
CLI subprocesses and owned PTYs, including recovery confirmation, large encrypted
mail/drafts/preferences, attachment send fixtures, Calendar, lock/restart and TUI
exit while the network lane is occupied. `tests/vault_migration.py` exercises
source inventory, interrupted copying and resume, activation refusal before
verification, detached startup, preserved IDs and explicitly paused imported
sends. All datasets and tokens are synthetic.
`tests/vault_foreground_priority.py` checks refresh cancellation, unrelated-client
isolation, continued admitted mutations and actual encrypted TUI mail actions.
