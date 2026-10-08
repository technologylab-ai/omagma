# Original HTML compatibility fixtures

These are fictional `text/html` messages for formatted replies and forwards. They exercise finding a safe note insertion point while keeping original content, CSS, image URLs, and template/conditional bytes intact. They require no mailbox or network access. The sole MIME resource is a valid 68-byte PNG with canonical unpadded base64url data; all addresses use `example.test`.

`manifest.json` supplies an immutable Original snapshot, its resources, and 39 cases. Thirty-seven cases expect acceptance. Two cases expect `OriginalHtmlUnavailable` because unfinished head content prevents finding a safe insertion point outside head. The accepted script double-escape case covers tracked script tokenizer states and preservation of fake envelope/CID strings as raw text. No case outcomes remain pending.

Once the body insertion point is known, unfinished quote, comment, and raw-style tails expect acceptance with verbatim tail preservation. The original does not need to pass a general HTML validator. The files named `pending-unterminated-quoted-attribute`, `pending-unclosed-style`, and `pending-script-double-escape` retain historical names; their manifest outcomes are now final acceptance, refusal, and acceptance respectively.

Each accepted case has independent expectations:

- `mustRetain` lists exact original source spans. Envelope tokens may be coalesced or repaired; stale encoding metas may be replaced.
- `mustEndWith` requires an unfinished body tail to remain the exact output suffix through EOF. Do not append guessed envelope closers inside that tail.
- `mustNotRetain` names stale encoding labels that must disappear.
- `rootAttributes` and `bodyAttributes` specify recovered attributes. Absent attributes from late roots/bodies merge; existing values win.
- `noteBefore` requires the new note to precede the first original body content, including text that appears before a late literal body opening.
- `realResourceIds` identifies actual referenced MIME resources. `opaqueCidStrings` are CID-like literals in comments or raw text and must not create required resource references.
- `compatMode` and `styleProbeIds` check document-mode preservation and CSS on original elements where supplied.
- `browserEquivalent` requires equivalent recovered original content and its placement after removing the generated note/header and encoding metas. It covers body text, tables, links/images, CSS, and root/body attributes; formatting whitespace is immaterial.
- Rejected cases specify `expectedError`; refusal must leave the immutable original unchanged.

`baselineOutcome` describes `validate`/`prepare` at commit `fb14c82` by source inspection. A baseline acceptance does not prove preservation: the fragment without a doctype is accepted but receives a synthesized doctype, which changes its paragraph/table recovery. Native and browser verification belong to the compatibility test harness.

The case families cover omitted envelope opens/closes, BOM/whitespace, MSO conditionals and Office/VML namespaces, repeated or late envelope tags, footer/pixel tails, recoverable attribute and tag-name parse errors, raw text, templates, and quirks/standards table recovery. Concatenated complete envelopes **within one HTML MIME leaf** expect deterministic browser recovery and acceptance. Separate competing MIME presentation bodies retain their existing backend policy.

The expectations follow the [HTML parsing rules](https://html.spec.whatwg.org/multipage/parsing.html), [WPT tree-construction fixtures](https://github.com/web-platform-tests/wpt/tree/master/html/syntax/parsing/resources), and namespace/conditional patterns in the [MJML email skeleton](https://github.com/mjmlio/mjml/blob/master/packages/mjml-core/src/helpers/skeleton.js). [RFC 2854](https://www.rfc-editor.org/rfc/rfc2854.html) also calls for browser-compatible `text/html` interpretation and recognizes omitted or incorrect doctypes. Fixture content was written for this suite and does not copy real mail or complete third-party templates.
