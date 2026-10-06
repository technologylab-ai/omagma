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
The approved logo and screenshots remain actual project assets. New terminal
features are identified as source-only; historical memory observations retain
their dates and accounting boundaries.
