# Updating Omagma

The TUI checks for a newer stable release every **24 hours**, in the background
after mail work. It saves the check timing across restarts. A long-running TUI
also checks when the next daily interval becomes due; starting another session
does not reset the interval.

## Upgrade notice

On the main mailbox screen, **Upgrade available** shows the running and newer
versions with **Dismiss** and **How to update** buttons. Tab/Shift+Tab and Enter,
or a click, reach both buttons. The card keeps your selected message in place.
New-mail notices take priority, and the upgrade card stays hidden while you
compose, work in contacts, read in an expanded view or use a dialog. Small
terminals use a compact **Updates** indicator.

Dismiss remembers that release across restarts. A later release can appear
again. Open **Updates** from Ctrl+P's action palette or `:updates` to view the
guide at any time, including after dismissal.

The guide identifies the running installation and offers **Copy commands**,
**Release notes**, **Install guide**, **Check again**, **Automatic/Manual**,
**Copy agent request** and **Back**. Tab/Shift+Tab traverses the controls; Esc/q
returns to mail. **Copy agent request** gives an agent a public repository URL
and installation details so it can help with the upgrade.

Check again requests release metadata explicitly. Automatic/Manual switches
daily checks on or off and remembers the choice. Offline checks keep cached
status; GitHub's retry delay is respected even for manual checks. A source build
ahead of the latest stable version is never offered a downgrade.

## Use the procedure for your installation

Save your work and close Omagma before replacing it, then verify
`omagma --version` and reopen. Configuration, account grants, keyring
credentials, cached mail and local drafts live outside the release directory
and stay in place. Pending sends remain paused after a restart.

| Installation | Upgrade procedure |
| --- | --- |
| **Omarchy plugin from a Git checkout** | `omarchy plugin update io.github.technologylab_ai.omagma` updates the checkout. Rebuild the backend with that checkout's exact Zig pin, verify it, then rescan plugins. The plugin command updates source; it does not build or replace the backend. Preserve local changes. |
| **Omarchy release bundle** | Download a complete matching Linux bundle and its `SHA256SUMS` from the same release. Verify, extract into a fresh versioned directory and probe the included backend. Switch your existing owned plugin symlink, rescan plugins and retain the old bundle for rollback. The Git plugin updater cannot upgrade a release bundle. |
| **Homebrew, on macOS or Linux** | Run `brew update`, then `brew upgrade renerocksai/tap/omagma`. The notice waits until the tap can supply the release and respects pinned installations. |
| **Manual Linux/macOS bundle or binary** | Download the matching host OS/CPU release and `SHA256SUMS`, verify and stage it in a fresh directory, probe its version, then switch your owned executable link. Keep the previous version. |
| **Source checkout or another package manager** | Follow the source build or owning manager's procedure. The guide reports when ownership cannot be established; an agent can inspect the installation first. |

After updating an Omarchy plugin and its matching backend, rescan with:

```sh
omarchy-shell shell rescanPlugins
omagma --version
```

For Homebrew:

```sh
brew update
brew upgrade renerocksai/tap/omagma
omagma --version
```

Use the host running Omagma, including a remote Linux or Mac host. Having
Homebrew or Omarchy installed alone does not establish which owns the running
binary. See [Linux installation](INSTALL.md), [macOS installation](MACOS.md)
or [source builds](DEVELOPMENT.md#build-from-source) for the full procedure.

## CLI and agents

These commands work without account configuration or Google authorization:

```sh
omagma updates status --json
omagma updates check --json
omagma updates guide
omagma updates guide --json
omagma updates dismiss
omagma updates automatic off
omagma updates automatic on
```

`status` reads cached metadata; `check` makes an explicit release request.
`guide --json` includes the running/latest versions, installation method,
commands and instructions. `dismiss` remembers the cached release.

Checks contact the official public GitHub release API and, for a proven
Homebrew installation, the tap's public formula. They send no Google
credentials or account/mail data and need no extra Gmail permission. Private
state is stored in
`${XDG_STATE_HOME:-$HOME/.local/state}/omagma/updates.json`. The feature provides
notifications and instructions; installing the update is an explicit step.
