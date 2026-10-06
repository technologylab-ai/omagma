# Account setup

[Download and verify the matching plugin bundle](INSTALL.md) first. Run these commands from its extracted `omagma/` directory; the included backend lives at `zig-out/bin/omagma`. Zig is not required for release installation. A source build uses the same relative binary path.

**Recommended: ask an agent to guide you.** Point your coding agent at this
repository and use a [setup prompt](AGENT-SETUP.md). It can walk you through
Google Console one step at a time, use your feedback to identify the current
screen, prepare private files and open each account's consent in the correct
Chrome profile. You complete the Google registration and approval clicks.
Tell it whether you want read-only browsing or full TUI/CLI access. The steps
below also work for manual setup.

Choose the access you want before connecting an account:

| Interface | Google permissions | Google OAuth registration |
| --- | --- | --- |
| Bar dropdown, or TUI/CLI mail reading only | `gmail.readonly` | The bar's Google OAuth registration |
| All currently implemented TUI/CLI mail and contact features | `gmail.modify` and `contacts` | A separate Google OAuth registration in the same Google project |

The full scope URLs and Console steps are in [full TUI/CLI permissions](#full-tuicli-permissions). The bar keeps its read-only grant even after you authorize the terminal. TUI and CLI share the terminal grant; each configured account authorizes separately.

If a private config already exists, edit it instead of copying the example over it. For a new configuration:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/omagma"
chmod 700 "${XDG_CONFIG_HOME:-$HOME/.config}/omagma"
cp examples/config.json "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
```

If `XDG_CONFIG_HOME` is set, the default location is `$XDG_CONFIG_HOME/omagma/config.json` instead. You can always pass `--config` explicitly. Keep private configuration and OAuth downloads outside the repository.

## Read-only Google OAuth registration

Register Omagma in your Google project, then approve access for each mail
account. Google Console lists these registrations under **Clients**.

1. Create a Google Cloud project and enable the Gmail API.
2. Configure the Google Auth consent screen. Use an **External** audience for accounts from different Workspace organizations; an Internal application is limited to its organization. Add intended accounts as test users while in Testing. Workspace administrators can restrict access. [Google’s verification guidance](https://support.google.com/cloud/answer/13464323?hl=en).
3. Under **Data Access**, add `https://www.googleapis.com/auth/gmail.readonly` for the bar. For full terminal access, also add the scopes in [full TUI/CLI permissions](#full-tuicli-permissions); keep the bar's readonly entry.
4. In **Google Auth Platform → Clients → Create client**, select **Application type → Desktop app**, give the registration a name, and click **Create**. Download its JSON to a private local location, with file mode 0600. Omagma uses a browser consent flow, PKCE and a loopback callback. [Google’s installed-app documentation](https://developers.google.com/identity/protocols/oauth2/native-app).
5. Set `oauthClientFile` to the file’s absolute path in your configuration.

The requested `gmail.readonly` scope is a restricted Gmail scope. Although the bar fetches only a bounded Inbox page and metadata, the permission itself allows broader mailbox reading. Terminal read-only commands can use that grant to fetch full bodies, threads and attachments within their separate limits. [Gmail scope definitions](https://developers.google.com/workspace/gmail/api/auth/scopes).

External applications in **Testing** receive refresh tokens that expire after seven days for these Gmail/contact permissions. This applies to both the bar and terminal grants: reconnect an expired bar grant with `auth`, and an expired terminal grant with `terminal-auth authorize` using its terminal registration and complete capability set. Production removes that Testing-specific expiry; tokens can still expire or be revoked for other reasons. Public availability and verification are separate decisions governed by Google’s requirements. [Token expiration](https://developers.google.com/identity/protocols/oauth2#expiration), [distribution](DISTRIBUTION.md).

## Configuration

```json
{
  "oauthClientFile": "/absolute/private/path/google-registration.json",
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

Each account may also set `"senderName": "Alex Example"` and
`"signature": "Alex\nExample team"`. Sender names reject ASCII control
characters. Signatures are plain text; newlines and tabs are allowed, while
other ASCII controls are rejected.

## Connect each enabled account

```sh
zig-out/bin/omagma auth --account personal@example.com --config "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
```

Complete Google consent in the opened Chrome profile within **180 seconds**. omagma checks the returned Gmail identity against the configured address before storing a refresh token in Secret Service. Repeat the command for each other enabled address. The keyring must be available and unlocked.

For the bar, use the live entry in [installation](INSTALL.md) and refresh the account after connecting. If you previously chose its optional demo mode, set `fixtures` to `false`. If consent expires or access is revoked, run `auth` again for that account. There is currently no in-dropdown Connect action. Verify that **Open inbox** and message links reach the intended account in the intended profile.

## Full TUI/CLI permissions

Full current terminal functionality uses these two Google scopes:

| Scope URL | Features |
| --- | --- |
| `https://www.googleapis.com/auth/gmail.modify` | Read/search, send/reply/reply-all/forward with attachments, stars/read state, existing labels, archive/Trash/restore and invitation replies by email |
| `https://www.googleapis.com/auth/contacts` | Read/search, create and edit Google contacts |

`gmail.modify` includes the needed mail-read/send access; `contacts` includes
contact reads and writes. Omagma still checks each local capability separately.
Invitation replies are RSVP emails, so no Calendar API or Calendar scope is
needed. Omagma currently manages local drafts, assigns/removes existing labels,
and creates/edits contacts; it has no permanent mail deletion, contact deletion,
label creation/renaming/deletion or calendar views. [Google's Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes),
[contact write scope](https://developers.google.com/people/api/rest/v1/people/updateContact).

The permission itself also covers creating, editing and deleting Gmail label
definitions. Omagma currently applies/removes existing labels; those label
management operations still need implementation. They do not require an extra
scope. [Create labels](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels/create),
[edit labels](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels/update),
[delete labels](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels/delete).

For an existing working bar installation:

1. Select the same project in Google Cloud Console. In **APIs & services →
   Library**, enable **People API**. After enabling it, the API/service details
   page shows **Status: Enabled** and a **Disable API** action. Gmail API
   should already be enabled.
2. In **Google Auth Platform → Data access → Add or remove scopes**, use
   **Manually add scopes** to paste the two full scope URLs above, one per
   line. Click **Add to table**, then **Update**, and **Save** if shown. Keep
   the existing `gmail.readonly` entry for the bar.
3. In **Audience**, keep your existing audience and publishing choice. If
   using External Testing, ensure this account is a test user. The existing
   project and branding can serve both registrations.
4. In **Clients → Create client**, choose **Application type → Desktop app**, name it
   `Omagma Terminal`, click **Create**, then **Download JSON**. You can dismiss
   the dialog after the file has downloaded. This Console option registers the
   locally installed program. Create a new entry with a different **Client ID**
   from the bar's registration; renaming or copying its JSON does not create
   another registration.
5. Keep the new JSON in a private directory outside the repository, with file
   mode `0600`; a friendly filename such as `terminal-registration.json` is useful.
   Give your agent its local path rather than pasting its contents. Keep both
   registration files. `oauthClientFile` in the account config continues to
   point at the bar's original registration JSON. Pass the terminal file with
   `--client-file` below.
6. Authorize one configured account with all six local capabilities:

```sh
zig-out/bin/omagma terminal-auth authorize --account personal@example.com \
  --config "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json" \
  --client-file /absolute/private/path/terminal-registration.json \
  --capabilities mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp
```

The browser opens in that account's configured Chrome profile. Complete consent
within **three minutes**. Select the exact account and approve **both** Gmail
and contacts access, using **Select all** if offered. Adding Console
scopes alone does not upgrade an existing token. Once the callback page reports
authorization received, you can close that tab; wait for the command to finish
successfully, then inspect the grant:

```sh
zig-out/bin/omagma terminal-auth status --account personal@example.com \
  --config "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
zig-out/bin/omagma tui --account personal@example.com \
  --config "${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json"
```

Restart an already open TUI after its grant changes. The CLI now uses the same
permissions. Repeat authorization for each additional configured account
**one at a time**, using the same terminal registration JSON. Wait for successful CLI
completion before opening the next account's consent; credentials remain
separate per account. An agent can confirm the recorded capabilities and read
mail/contacts to check access; setup does not require sending a test message or
changing your data.
Tokens live in Secret Service. The private grant registry defaults to
`${XDG_CONFIG_HOME:-$HOME/.config}/omagma/terminal-grants.json`; if you choose a
custom `--grant-file`, use it consistently for consent, status, TUI and CLI.

For narrower access, use the [smaller permission sets](#smaller-permission-sets).
When changing capabilities, request the complete desired set in a new consent
flow. Read-only bar credentials remain available for mail reading. See
[terminal workflows](TERMINAL.md) and [the CLI contract](AGENT-CLI.md) for using
the connected account. Console navigation follows Google's
[consent setup](https://developers.google.com/workspace/guides/configure-oauth-consent)
and [Google OAuth registration instructions](https://developers.google.com/workspace/gmail/api/quickstart/python#authorize_credentials_for_a_desktop_application).

### Smaller permission sets

`mail-read` is required for a terminal grant. Choose the other local
capabilities for the features you intend to use:

Any set beyond `mail-read` alone uses the separate terminal Google OAuth registration.
For read-only browsing, the existing bar grant is sufficient; if authorizing
an explicit `mail-read` terminal grant, `--client-file` may be omitted to use
the configured `oauthClientFile`.

| Local capabilities | Google scopes requested |
| --- | --- |
| `mail-read` | `gmail.readonly` |
| `mail-read,mail-send` | `gmail.readonly`, `gmail.send` |
| `mail-read,calendar-rsvp` | `gmail.readonly`, `gmail.send`; the local grant permits RSVP rather than ordinary sending |
| Add `mail-modify` | `gmail.modify` replaces readonly/send; include `mail-send` too if ordinary sending is wanted |
| Add `contacts-read` | Add `contacts.readonly`; requires People API |
| Add `contacts-write` | Add `contacts` instead of contacts.readonly; include `contacts-read` too for browsing contacts |

Scope names above use the prefix `https://www.googleapis.com/auth/`.
Add the full URLs for your chosen smaller set under the project's **Data
access**, including `gmail.send` or `contacts.readonly` when the table requests
them. The full-access setup uses `gmail.modify` and `contacts` instead.
Full Google scope coverage does not automatically enable an omitted local
capability. The complete six-capability set above avoids that mismatch for
full TUI/CLI use. Gmail settings aliases are read through the mail grant;
changing Google settings is not part of the current terminal interface.

### Background cache with a terminal-only installation

The optional [terminal cache timer](TERMINAL-BACKGROUND.md) deliberately uses
the read-only bar grant. To enable that timer, configure the bar's read-only
registration and run `auth` for each requested account even if you never install the
bar widget. The full terminal grant alone does not authorize automatic cache
fetching. Both credentials can coexist in the same private account config and
separate keyring namespaces.

## Reconnect or change permissions

For the bar, repeat its `auth` command. For the terminal, repeat
`terminal-auth authorize` with the terminal registration JSON and the **complete**
capability set you want to retain, then run `terminal-auth status` and restart
an already open TUI. Google consent replaces the requested set rather than
incrementally adding one capability.

If Google reports that an API is disabled, enable Gmail API or People API in
the registration JSON's project as appropriate. `SeparateTerminalClientRequired`
means the same Google OAuth registration was used for the bar and terminal;
create a new registration in the Console rather than copying the file. An External Testing
account must be listed under Audience → Test users. Report any actual Workspace
policy block before changing permissions or project settings.

## Optional Google Cloud CLI

If you already use `gcloud`, it can enable the required APIs in an existing
project. This is optional; the Console Library steps above are sufficient.
Use an account allowed to enable services on that project:

```sh
gcloud auth login admin@example.com --no-activate
gcloud services enable gmail.googleapis.com people.googleapis.com \
  --project=YOUR_PROJECT_ID --account=admin@example.com
```

This authorizes Google Cloud administration, not Omagma's Gmail access.
Configure the Google Auth Platform Data access scopes, test users and separate
Google OAuth registration through the Console, then use Omagma's `terminal-auth authorize`
for per-account mail/contact consent. `gcloud iam oauth-clients` and
`gcloud iap oauth-clients` manage other registration types and are not substitutes for
the Google OAuth registration used here. [Cloud CLI installation](https://docs.cloud.google.com/sdk/docs/install-sdk),
[API enablement command](https://docs.cloud.google.com/sdk/gcloud/reference/services/enable),
[Google OAuth registration setup](https://developers.google.com/workspace/guides/create-credentials#desktop-app).
