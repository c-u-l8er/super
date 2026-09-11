# Vendored, and this is a dependency decision

Super ships a static frontend from `cockpit/ui`. The code editor is bundled
locally at development time; no package server or CDN is needed at runtime.

They are here rather than on a CDN because they have to be: the cockpit's CSP
is `default-src 'self'`, so a remote script would not load, and loosening the
CSP to fetch a terminal renderer would be a much worse trade than checking the
file in.

## What is here

| file | source | sha256 |
|---|---|---|
| `xterm.js` | `https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js` | `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495` |
| `xterm.css` | `https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css` | `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6` |

Fetched 2026-09-04. `@xterm/xterm` is MIT-licensed (Copyright © 2017–2022 The
xterm.js authors; Copyright © 2014–2016 SourceLair Private Company;
Copyright © 2012–2013 Fabrice Bellard).

To re-derive:

    curl -sSL -o xterm.js  https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js
    curl -sSL -o xterm.css https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css
    sha256sum xterm.js xterm.css

## Why xterm specifically, and what depends on it

`Terminal.write(data, callback)` calls back **after the data has been parsed
and written to the buffer** — not on arrival. That callback is where
`terminal_ack` is sent, which makes the D.1.3c·2c·1b window a measure of the
*renderer* rather than of the transport. A renderer without that callback
would have to ack on receipt, and the credit would then bound the socket
rather than the screen, which is not the property the slice claims.

Scrollback is xterm's own, bounded, and page-local. There is no server-side
scrollback and reopening a presentation begins empty — `Ampd.Terminal.Plane`
says why.

## If this dependency is unwanted

Nothing in the byte plane depends on it. `ui/terminal.js` is the only file
that names `Terminal`; replacing it with any renderer that can tell you when
it has *consumed* bytes preserves every property. Delete this directory, drop
the two `<link>`/`<script>` tags in `terminal.html`, and write to a `<pre>`.
The plane, its ordering, its window and its falsifiers are unaffected.

## Tabbed development surfaces (2026-09-07)

`code-editor.js` bundles CodeMirror 6 and its language packages with esbuild.
Exact versions and integrity hashes are in `tools/editor/package-lock.json`.
Rebuild with `npm ci && npm run build` in `tools/editor`. The entry module
selects JavaScript/TypeScript, Rust, Python, HTML, CSS, JSON and Markdown modes
with the One Dark theme; other files use plain text. Licenses are included
in `CODE_EDITOR_LICENSES.txt`. This is a build-time dependency decision.

`development.js` also uses the existing xterm 5.5.0 renderer for interactive
local PTYs. Those shells have their own bounded output buffers and input path;
the runtime worker observation pane retains its read-only acknowledgement
protocol. Local terminal sizing uses the pinned renderer's measured cell size.
