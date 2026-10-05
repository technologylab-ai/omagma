# Synthetic terminal fixtures

These files contain fictional mail, contacts and meeting invitations. They require no credentials, Secret Service, browser or network. Addresses use reserved example domains. Message IDs, contact IDs and calendar UIDs intentionally collide across accounts.

Run `python3 tests/fixtures/terminal/generate.py` to regenerate the corpus deterministically. Python is a development fixture generator, not a runtime helper.

Each `accounts/*.json` contains 96 Gmail `FULL` message resources, eight expected 12-message list responses, and external attachment-body responses. List responses carry IDs only; full resources have nested MIME payloads and base64url body data. Threads contain three messages, including messages sent by the account itself. Ordering uses `internalDate`; the displayed RFC date is deliberately identical across messages.

`mime/*.eml` contains independent RFC 5322/MIME decoding oracles for the selected cases. `calendar/*.ics` supplies invitations and semantic reply examples. Reply timestamps are fixture constants; runtime replies may use their actual creation time. `contacts/*.json` uses People API contact sources and etags. `manifest.json` supplies expected decoded text, attachment digest and reply-all recipients. `failure-contract.json` describes provider faults and expected outcomes; it is a test contract, not evidence that those tests passed.

| Message suffix | Case |
| --- | --- |
| 001 | UTF-8 quoted-printable text |
| 002 | UTF-8 base64 text |
| 003 | Multipart alternative, HTML and an attachment with a traversal filename |
| 004 | HTML-only mail with inert script, style, remote image and unsafe link inputs |
| 005 | Reply-To, duplicate recipients, account in Cc and a Bcc recipient |
| 006 | Missing Message-ID; cannot claim a valid reply thread |
| 007 | Terminal escape sequences, carriage return and NUL carried as encoded mail data |
| 008 | iCalendar REQUEST |
| 009 | REQUEST for a recurring instance |
| 010 | Plain text fetched through `body.attachmentId` |
| 011 | ISO-8859-1 quoted-printable text |
| 012 | RFC 2047 display names containing an encoded comma; decoded after recipient parsing |
| 013–015 | Bodies over 64 KiB that force eviction under a 128 KiB test cache quota |

Mail-derived control sequences must stay inert. Do not print decoded message 007 directly to a terminal. Attachment filenames must not determine arbitrary output paths. Tests use an isolated output directory and verify the resulting basename and digest.
