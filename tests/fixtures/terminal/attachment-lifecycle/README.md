# Attachment lifecycle fixtures

These three fictional accounts deliberately share message IDs and provider
tokens while containing different bytes. Each account has a chronological
four-message received/sent/received/received conversation. The sent PDF appears
on the second card; the third card contains two distinct, equal-sized PDFs
with the same filename. The fourth message contains Unicode, a zero-byte file,
and an HTML-referenced inline image.

`accounts/` contains Gmail-shaped FULL responses and separate attachment
responses. `payloads/` and `expected.json` are the independent content oracle.
The lifecycle test initially withholds attachment responses so message reads
retain unloaded external descriptors, then makes the responses available for
explicit download. This matters because the fixture decoder can otherwise
eagerly preload external data and bypass the Gmail attachment adapter.

The cases in `tests/terminal_attachment_lifecycle.py` cover provider reads
and cached restarts across accounts; retained body token A versus current thread
token B; new, forwarded and reply-all drafts through synthetic send and provider
ID remapping; protected uncertain sends; atomic failures and existing files;
and actual owned-PTY save/open and duplicate-name SaveAll behavior. A separate
`missing_body` case removes or damages only its owned cached body after a thread
publishes token B. The next provider FULL response has token C while B remains
downloadable; saving the already selected B must retain its verified identity.

`conversation_modes` uses `pressure.json` for two representative metadata
populations (414 and 2,000 entries), 8,037-byte plain and 45,794-byte HTML bodies,
and four files/resources sized 14,999, 14,999, 83,694 and 298,881 bytes. Incoming
and self-authored Sent messages cover text/formatted reply and reply-all, plus
text/formatted/attached-original/omit-files forwarding. Provider FULL reads are
gated before external replies become available. Every result is checked against
independent byte hashes, exact recipients/threading, and a reopened local draft;
none of these 32 workflows sends mail. RAW MIME is staged only for the explicit
attached-original choice, matching Gmail's separate FULL and RAW response shapes.

`tui_forward` starts with four chronological thread cards under both metadata
populations. It selects the incoming or normal Sent card, presses `f`, verifies
the format chooser before selecting a mode, and cancels without creating a
draft. A second `f` completes text, formatted or attached-original forwarding in
four representative scenarios. The reopened draft must retain the selected
card's exact files/resources, with no inferred recipients and no send. These
owned PTYs exercise the actual preflight and composer; native transport tests
separately account for the live network workspace absent from FixtureRemote.

The cold provider pass parses actual synthetic sent MIME using Python's
independent email parser, assigns unrelated provider attachment IDs, and uses a
separate empty cache. Imported-file sends intentionally expose no retained MIME
spool, so each of the three imported-file sends has a separate small inline-byte
send with the same reviewed inputs for wire inspection. File expectations remain
the original checked-in or explicitly imported payloads. The cold reader does
not reuse fixture outbox objects or local attachment blobs as a substitute for
provider behavior. Native transport tests separately verify exact
account/message/token URL ownership and retry behavior.

Run under the cooperative host reservation with a development binary:

```sh
python3 tests/terminal_attachment_lifecycle.py --binary /path/to/omagma
```

No real mail, credentials, desktop windows, or external provider writes are used.
