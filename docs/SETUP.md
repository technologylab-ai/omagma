# Account setup

[Download and verify the matching plugin bundle](INSTALL.md) first. Run these commands from its extracted `omagma/` directory; the included backend lives at `zig-out/bin/omagma`. Zig is not required for release installation. A source build uses the same relative binary path.

If a private config already exists, edit it instead of copying the example over it. For a new configuration:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/omagma"
chmod 700 "${XDG_CONFIG_HOME:-$HOME/.config}/omagma"
cp examples/config.json "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
```

If `XDG_CONFIG_HOME` is set, the default location is `$XDG_CONFIG_HOME/omagma/config.json` instead. You can always pass `--config` explicitly. Keep private configuration and OAuth downloads outside the repository.

## Google OAuth client

1. Create a Google Cloud project and enable the Gmail API.
2. Configure the Google Auth consent screen. Use an **External** audience for accounts from different Workspace organizations; an Internal application is limited to its organization. Add intended accounts as test users while in Testing. Workspace administrators can restrict access. [Google’s verification guidance](https://support.google.com/cloud/answer/13464323?hl=en).
3. Under **Data Access**, add only `https://www.googleapis.com/auth/gmail.readonly`.
4. Create an OAuth client of type **Desktop app** and download its JSON file to a private local location, with file mode 0600. omagma uses a browser consent flow, PKCE and a loopback callback. [Google’s installed-app documentation](https://developers.google.com/identity/protocols/oauth2/native-app).
5. Set `oauthClientFile` to the file’s absolute path in your configuration.

The requested `gmail.readonly` scope is a restricted Gmail scope. Although omagma fetches only a bounded Inbox page and metadata, the permission itself allows broader mailbox reading. [Gmail scope definitions](https://developers.google.com/workspace/gmail/api/auth/scopes).

External applications in **Testing** receive refresh tokens that expire after seven days for this scope. Production removes that Testing-specific expiry; tokens can still expire or be revoked for other reasons. Public availability and verification are separate decisions governed by Google’s requirements. [Token expiration](https://developers.google.com/identity/protocols/oauth2#expiration), [distribution](DISTRIBUTION.md).

## Configuration

```json
{
  "oauthClientFile": "/absolute/private/path/oauth-client.json",
  "chrome": "/usr/bin/google-chrome-stable",
  "chromeUserData": "",
  "refreshIntervalSeconds": 0,
  "accounts": [
    {"address": "personal@example.com", "profile": "Profile 1", "enabled": true, "required": true},
    {"address": "work@example.com", "profile": "Profile 2", "enabled": true, "required": true},
    {"address": "optional@example.com", "profile": "Profile 3", "enabled": false, "required": false}
  ]
}
```

Replace the fictional addresses and profile directories. One to three accounts are supported; addresses and profiles must be distinct. For a first-account setup, configure only that one account or disable the other slots. `required` controls the initial selection among enabled accounts. Disabled accounts remain visible as unavailable if included in the configuration.

Open `chrome://version` in each intended Chrome profile and use the final directory name from **Profile Path**, such as `Profile 1`. This is the directory name, not Chrome’s displayed profile label. The `Default` profile is rejected to avoid ambiguous routing. `chromeUserData` may be an absolute existing Chrome data directory; an empty value uses the standard Google Chrome directory. omagma validates this directory and never launches a second data directory with `--user-data-dir`.

JSON paths must be absolute, expanded paths; `~` and `$HOME` are not expanded inside JSON. `refreshIntervalSeconds` must be a JSON integer: `0` disables background refresh, and `60..86400` enables it. Use `300` for five minutes. [Refresh behavior](BACKGROUND-REFRESH.md).

## Connect each enabled account

```sh
zig-out/bin/omagma auth --account personal@example.com --config "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
```

Complete Google consent in the opened Chrome profile within **180 seconds**. omagma checks the returned Gmail identity against the configured address before storing a refresh token in Secret Service. Repeat the command for each other enabled address. The keyring must be available and unlocked.

After connecting, turn off the [bar widget’s](INSTALL.md) synthetic fixture setting. If consent expires or access is revoked, run `auth` again using the included binary for that account. There is currently no in-dropdown Connect action. Verify that **Open inbox** and message links reach the intended account in the intended profile before relying on browser routing.
