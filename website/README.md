# Omagma static site

The landing page and HTML documentation are static files. The build reads the
canonical public Markdown and image assets; it needs Node.js 24+ and no Zig
compiler, Google credentials or backend service.

```sh
npm ci --prefix website
npm run build --prefix website
npm run check --prefix website
npm run preview --prefix website
```

Open the printed local preview URL. The preview server binds only to loopback
and is a development tool; published GitHub Pages serves the generated files
directly.

`OMAGMA_SITE_BASE` defaults to `/omagma/` for project Pages. For a root or custom
domain site, build with `OMAGMA_SITE_BASE=/`. `OMAGMA_SITE_URL` optionally sets
the absolute public URL used by canonical links, social metadata and sitemap;
it defaults to `https://technologylab-ai.github.io/omagma/`.

Only `website/dist/` is published. `node_modules`, isolated design sessions,
private notes, local configuration, caches and measurement receipts are not
build inputs or deployment artifacts. The checks validate generated resources,
anchors, deployment prefixes and the output allowlist. Markdown edits belong in
the original documents, not generated HTML.

The design templates and CSS were authored with Claude Opus 5.5 at xhigh effort
from an isolated public-only snapshot, then reviewed and integrated locally.
The approved logo and screenshots remain actual project assets. The guides
describe current project features; historical memory observations
retain their dates and accounting boundaries. The sidebar version follows
`build.zig.zon` automatically when the application version changes.

## Calendar screenshots and social preview

The homepage, project README and social card use reviewed native v0.2.10
screenshots under `docs/images/`. Reproduce the four views with
[`scripts/public-captures/README.md`](../scripts/public-captures/README.md).
All accounts, Contacts, events and invitations are fictional. The meeting review
requests Google Meet generation; a Meet URL is created only after saving.

`templates/social.html` composes the approved logo and actual combined Week
capture at 1200 × 630. To render it, first acquire the cooperative host
reservation described in `docs/VERIFICATION.md` and retain it through browser
cleanup. Then pass its live token to the renderer:

```sh
HOST_TOKEN=YOUR_RESERVATION_TOKEN node website/tools/public-media.mjs social
```

The master is `docs/images/omagma-social-calendar.png`. The older
`omagma-social.png` and `omagma-social-preview.png` names are compatibility
copies of that artwork; the site metadata uses the Calendar-specific URL.
No new runtime dependency is required. The renderer uses installed Chromium,
a disposable headless profile, an explicit public asset map and blocked
external requests.

After building, run responsive and keyboard QA under the same reservation:

```sh
HOST_TOKEN=YOUR_RESERVATION_TOKEN node website/tools/public-media.mjs qa \
  --out-dir .local-notes/fresh-site-qa
```

This checks 320/390/768/1440-pixel layouts, Calendar imagery and metadata,
guide navigation and search, prompt copying and reduced motion. Review the
composed screenshots and social card before publication. QA screenshots and
receipts remain private. `npm run check --prefix website` also guards the
Mail + Calendar entry points and current social-image dimensions.
