# Super: checking accepted source before integration

September 10, 2026

Accepted reviews now offer **Check saved result** and **Open Editor**. Super reads the retained acceptance from the runtime, verifies its recorded passing profile references, and checks every saved reviewed file plus the captured repository snapshot. Later edits to a reviewed file or another captured file refuse the check. The original acceptance, review history and test runs remain unchanged.

The result is explicitly dated: it describes the files at that check, not a live guarantee. It disappears when the view is rebuilt or the app restarts. A fresh check after restart requires choosing the repository again. Native verification checks repository selection and runtime review identity again before returning; the UI discards responses from a changed runtime or review.

## Scope

This is an integration prerequisite, not automated integration or rebuilding. It runs no repository code, moves no source files, creates no commit and produces no build. The control is available on accepted reviews belonging to the current active plan revision. Completed, cancelled or superseded plans remain historical records; checking them is not connected in this increment.

## Verification

- 752 runtime regression tests passed.
- 14 native review tests passed, including accepted-record identity and refusing page-supplied source/outcomes.
- 17 snapshot runner tests passed, including multi-file saved-result matching and isolated JavaScript, Elixir and Rust test execution.
- 17 UI behavior tests passed, including stale reviews, runtime changes during either asynchronous step and mismatched native responses.
- 38 native workflow assertions passed, including matching accepted files, refusing reviewed-file and unrelated-file drift, preserving the complete accepted record, actual process restart and rechecking after repository selection.
- Release build, six human-control checks (25/25 mutations), 35 webview access checks and whitespace checks passed.
- Native screenshots were captured and visually inspected for matching files, later file changes and a fresh check after restart.

The native workflow used a disposable Git repository and saved world with a deterministic local provider fixture. It was not a new real-provider dogfooding cycle.

## Next MVP work

Choose and implement the integration destination and build workflow inside Super, carrying the exact accepted source through to a produced app artifact. Then complete several ordinary Super development tasks through the real provider, followed by installation and recovery checks. The broader MVP remains unfinished.

Native screenshot gallery: current Codex task outputs/Super_Accepted_Result_Gallery.html.
