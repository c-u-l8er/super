# Preview startup feedback

September 10, 2026. Super now distinguishes an opening preview, a first rendered frame, unconfirmed startup, normal close, and unexpected failure.

A running process alone no longer implies that its window works. New Super builds report their first painted runtime frame. After 15 seconds without that signal, the original app says startup is unconfirmed and asks you to check the window. Older retained builds remain usable with that explicit limitation.

Unexpected exits show the exit code or termination message and offer **Try this build** again. Optional diagnostic output retains the latest 8 KiB from the preview’s error stream. Reading drains the stream continuously, so noisy output cannot grow the retained buffer indefinitely. Diagnostics remain in the original app’s current session; they are replaced by the next preview and are not a durable log.

## Verification

- **24 native unit tests passed**, including bounded output, a signal split across reads, early failure, cleanup, unconfirmed startup and close.
- **21 UI checks passed**, including distinct startup and failure labels.
- **52 native workflow assertions held**, including first-frame status, failed startup with diagnostic text, successful retry, captured-source refusal, build cancellation and restart recovery.
- Current release started with a real runtime, rendered its development plans and emitted the native first-frame signal.
- The previously accepted real-provider Super build opened without a new provider call, remained explicitly unconfirmed, and closed without changing the original acceptance.
- Release build, 6 intent checks, 35 WebView access checks and whitespace checks passed.

Native screenshots of failure, startup and compatibility states were visually inspected. An initial workflow test raced the asynchronous return of the Try button after close; its wait now follows the displayed control, and the full workflow passed on rerun. A separate attempt lost its native WebView session before the preview phase; that interrupted attempt is not counted as a pass. No product behavior was weakened to make that check pass.

The first-frame signal is startup feedback, not proof of continued health or permission to accept/install a build. Installation, saved-data compatibility and rollback, retained-build cleanup, and abnormal-termination cleanup remain MVP work. The broader runtime and compiler suites were not rerun because those implementations did not change.

Evidence: /home/travis/Documents/Codex/2026-09-10/let-s-continue-super-development-where-2/outputs/Super_Preview_Feedback_Gallery.html
