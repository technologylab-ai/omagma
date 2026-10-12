# Omagma v0.2.8 · What's new

This is the new native-first film source. Earlier v0.2.6/v0.2.7 pictures and evidence remain unchanged. The final picture is 1920×1080 at 30 fps for 2,527 frames (84.23333333333333 seconds).

The film leads with Mac/agent setup, offline CLI help, received-mail excerpts, $EDITOR snapshots and Send now. The late browser chapter shows the same Zig/libvaxis UI through WebAssembly, explicitly labelled as an experimental showcase that is not intended for everyday use. [The storyboard](STORYBOARD.md) gives the workflow; [feature coverage](FEATURE-COVERAGE.md) records the important limits.

`film.html` and `timeline.json` form the deterministic picture compositor. Serve the repository root and open `video/short028/film.html?timeline=timeline.json`. The pipeline awaits `window.READY`, seeks with `window.render(seconds)`, awaits `window.prepareFrame()` and captures the 1920×1080 surface. `window.FILM` exposes the exact clock; `window.qa(seconds)` reports the current phase, assets, camera and disclosures.

A phase can include `sequence: [{"offset": 0, "asset": "browser.frame.000"}, ...]`, with strictly increasing seconds relative to that phase. Each state is another genuine capture key, rendered in the same shell/camera; no UI cells are generated and no per-frame dramatic crossfade is added. The continuous browser action must include the actual account switches and typing before the recovered-draft result.

The root production pipeline supplies `video/cache/short028/assets-manifest.json` and its actual capture images. Each keyed asset declares its file, SHA-256, actual width/height, platform/provenance and normalized focus ROIs. UI pixels must come from genuine synthetic native, editor, offline-help and browser captures. Missing assets, decode/dimension failures and clock gaps fail the render instead of substituting invented UI. All public footage uses fictional accounts/messages; raw capture/provenance receipts remain in the ignored cache.

Reuse the approved encoded audio packets from `video/out/omagma-v0.2.7-flow.mp4`, unchanged. Do not recreate or retime the soundtrack, add a splice, adjust speed/pitch/gain or fade its natural ending. The final website hold ends at the exact approved 2,527-frame boundary.

Before delivery, the root pipeline must verify real screenshots, normal-speed chapter continuity, complete readable holds, constant-background transitions, all active UI/caption edges, exact audio packet equality, duration and privacy. Delivery belongs under `~/Videos/Omagma/`, never Pictures. Publication remains held; the film says “What's new in v0.2.8” and does not claim an approved release is already out.

[Production notes](PRODUCTION-NOTES.md) distinguish actual Opus co-design, genuine captures, observations and final verification. A browser RAM badge, if included, must identify the user's personal observation of different workloads rather than imply a controlled benchmark. Earlier native memory numbers must not be carried into this revision.

The production helpers are `capture_native.py`, optional `capture_mac.py`, `capture_browser.mjs`, `capture-images.mjs`, `assemble_assets.py`, `render.mjs`, `encode.py`, `review.mjs` and `deliver.py`. Every heavy step uses the existing live cooperative host lease through `HOST_TOKEN`; the helpers do not acquire or release another owner's lease. Native/browser sources are frozen and recorded in the ignored cache before captures. Mac SSH uses only a disposable fictional fixture, and never reads or changes the user's account setup. CLI/editor rasters include an editorial matte to protect their first glyphs from rounded corners.

The accepted browser edit preserves actual event order while omitting the intermediate draft-list detour: three account views, the received message, a readable formatting chooser, literal typing with preview updates, and a separately verified draft recovery after actual reload. The retained protected HTML table remains visible. `$EDITOR` uses an actual Neovim subprocess; selection copying verifies the exact literal paragraph in an owned PTY, and Send now requires exactly one fictional-provider submission.

Final checks compare every approved audio packet and timestamp, inspect consecutive encoded phase handoffs, and play the encoded movie at normal speed in an isolated headless browser. Muted playback verifies the picture clock and decoded frames; it is not an aural listening claim. Delivery includes the MP4, poster, decoded contact sheet, review player and a generic report under `~/Videos/Omagma/`.
