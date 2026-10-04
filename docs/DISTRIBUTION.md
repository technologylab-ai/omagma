# Distribution

This repository publishes source code under the MIT license. It does not ship a shared OAuth client or a service that receives Gmail data. Each user currently supplies a Google Desktop OAuth client and authorizes their own accounts locally.

A shared public OAuth registration would require a maintained application identity, support and privacy information, and compliance with Google’s applicable verification rules. `gmail.readonly` is a restricted scope. Publishing source code or selecting Production in the Google console does not itself establish verification. Personal-use and internal-organization exceptions have specific limits. [Google’s verification exceptions](https://support.google.com/cloud/answer/13464323?hl=en), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes).

External Testing is suitable for intended test users but its Gmail refresh grants expire after seven days. A Production registration removes that Testing-specific expiry; other expiration and revocation rules still apply. [Google’s token rules](https://developers.google.com/identity/protocols/oauth2#expiration).

The current release is a downloadable Omarchy plugin with CLI consent. See [setup](SETUP.md), [installation](INSTALL.md) and [privacy](PRIVACY.md). Do not bundle private credentials, configuration, raw live-test receipts or real-mail captures in releases.
