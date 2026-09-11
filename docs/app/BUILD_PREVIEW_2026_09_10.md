# Try an accepted Super build

September 10, 2026. Super now offers **Try this build** and **Close preview** on accepted build results.

The original app stays open. The preview uses a temporary world and separate local data, with no carried-over work or provider connections. Closing it returns you to the original app and removes that temporary session. It is a trial, not an installation or data rollback.

## What changed

The native host resolves the current accepted review, verifies the retained executable and the complete captured source manifest, then copies the verified bytes to the preview session. Changed executable or runtime content refuses launch. Extra, uncaptured source files are excluded. The host launches the verified executable directly, rather than trusting an editable launcher script.

Only one preview runs at a time. Close is scoped to its build and world, stops the preview process group and removes its temporary copy. Normal main-window shutdown also closes the preview. New builds recognize the preview environment in their window title; the older real-provider bundle tested here predates that title change.

## Verification

| Check | Result |
| --- | --- |
| Native review and preview unit tests | 21 passed |
| JavaScript UI checks | 20 passed |
| Complete native combined-file workflow | 49 held |
| Existing real-provider build preview | 5 held |
| Main release build | Passed |
| Intent surface | 6 held; 25 mutations covered |
| WebView access | 35 held; 25 commands |
| Whitespace check | Passed |

The native workflow verified preview launch, temporary world configuration, close and cleanup, changed-runtime refusal, unchanged acceptance, plus existing build cancellation and restart recovery. A separate run opened the real Super artifact accepted in the previous cycle using the new button, displayed live Mission Control, and returned to the original accepted review. No new provider request was sent.

Native screenshots of the running preview, refusal and return were inspected. The runtime and offline compiler implementations did not change; their broader suites were not rerun in this increment.

## Remaining MVP work

- Installation and rollback of an installed version, including a policy for saved-data compatibility.
- Clear startup failure reporting and a readiness handshake; current UI reports process status.
- Cleanup of retained builds and stale temporary directories after abnormal termination.
- More ordinary multi-file Super development through the real provider.

This provides the first in-app launch-and-return workflow. Super remains a supervised dogfooding alpha.

Evidence gallery: /home/travis/Documents/Codex/2026-09-10/let-s-continue-super-development-where-2/outputs/Super_Build_Preview_Gallery.html
