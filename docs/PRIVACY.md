# Privacy and credentials

omagma reads Gmail through the Gmail API after separate consent for each configured account. Its scope is `gmail.readonly`, a restricted scope that grants broader reading access than the bounded Inbox metadata the implementation actually requests. [Google’s scope definition](https://developers.google.com/workspace/gmail/api/auth/scopes).

The backend requests one Inbox page of at most 30 messages, then selected metadata and snippets. It does not request message bodies or attachments, write labels, mark messages read or send mail. Cache contents live in bounded process memory and disappear when the daemon exits. There is no local mail database, mail history or application mail log.

Refresh tokens are stored through Secret Service under `io.github.technologylab_ai.omagma` and the verified account address. They are passed to `secret-tool` through stdin, never through command-line arguments. Access tokens remain in bounded backend memory. Neither token type crosses the UI protocol. Keep your OAuth client download and account configuration private even though a Desktop OAuth client cannot keep its client secret confidential. [Google’s installed-app model](https://developers.google.com/identity/protocols/oauth2/native-app).

Consent opens Chrome in the configured profile and returns through an ephemeral IPv4 loopback listener. The backend checks PKCE, random state, callback syntax and the returned account identity, with a 180-second deadline. Normal Gmail links are validated HTTPS destinations passed as browser arguments. Credentials and mail are discarded from UI diagnostics.

The protocol’s `disconnect` command removes the local keyring token and clears the account cache. It does not revoke the Google-side grant. Revoke access in your Google Account if you want Google to invalidate the authorization. Removing the bar widget alone does not erase credentials.

Fixture tests do not contact Gmail or the keyring. Public screenshots contain fictional accounts and messages. Reports shared publicly must exclude credentials, OAuth callback URLs, real mail, addresses, identifiers and local installation paths.
