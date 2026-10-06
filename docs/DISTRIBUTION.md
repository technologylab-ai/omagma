# Distribution and OAuth registration

This page explains the distribution model and Google registration policy, not a
developer qualification workflow. [Installation](INSTALL.md) uses matching
Linux x86_64/arm64 binaries or complete bundles; [setup](SETUP.md) is the canonical
account/permission guide. No compiler or test harness is needed for a bundle.

Project source is MIT-licensed, with third-party notices included in releases.
Omagma does not ship a shared OAuth client or a service receiving Gmail data.
Each user supplies a Google Desktop OAuth client and authorizes accounts locally.

A shared public registration would need maintained identity/support/privacy
information and Google's applicable verification. Google classifies
`gmail.readonly` and `gmail.modify` as restricted, and `gmail.send` as sensitive.
[Gmail scope classifications](https://developers.google.com/workspace/gmail/api/auth/scopes).
Contacts creation uses the sensitive `contacts` permission; narrower read access
uses `contacts.readonly`, and Google displays requested scope classifications in
the project's Data access page. [People scopes](https://developers.google.com/identity/protocols/oauth2/scopes#people),
[sensitive-scope guidance](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification).

Publishing source or selecting Production does not establish verification.
Personal-use and internal-organization exceptions have specific limits; internal
registrations serve only their owning Workspace/Cloud Identity organization.
[Google's exceptions](https://support.google.com/cloud/answer/13464323?hl=en).

Refresh tokens issued by External Testing registrations expire after seven days
for Omagma's requested mail scopes, including both bar and terminal grants.
Production removes that Testing-specific expiry; other expiration/revocation
rules remain. This is registration policy, not a requirement to enroll in
Omagma's developer tests. [Google's token rules](https://developers.google.com/identity/protocols/oauth2#expiration).

Published v0.2.3 includes the Omarchy plugin and experimental terminal/agent
clients. Complete bundles contain the static backend and notices; terminal-only
installation can use the matching raw binary with `LICENSES.txt`. Later local
source features are labeled in [the feature catalogue](FEATURES.md), with no
change to published assets. The bar uses read-only consent; broader terminal
access uses a separate client/grant. Keep private credentials/configuration,
raw receipts and real-mail captures out of releases. [Privacy](PRIVACY.md),
[release maintenance](RELEASING.md).
