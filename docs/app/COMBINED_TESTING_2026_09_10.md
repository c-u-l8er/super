# Combined testing and acceptance — 2026-09-10

Supersedes the testing/acceptance limitation in DURABLE_CHANGE_SETS_2026_09_10.md.

The existing runner now recognizes development-review-set@1 and validates selected-file-set-basis@1 against all 2–4 members. It validates each member's content and source identity, common context, distinct non-conflicting paths and aggregate identities. Capture checks every original source, then overlays every proposed replacement before calculating one test snapshot. The result retains aggregate source/result identities and applied paths. Single-file review compatibility is preserved.

Acceptance preflight overlays nothing: every saved replacement must match its retained result bytes, and the complete captured repository must match the passing snapshot. The runtime uses its existing test admission, outcome, profile-coverage and human acceptance controls against aggregate identities. A member-only outcome is refused. No new commands or permission grants were added. Standalone text checks remain unavailable for sets.

The plan now exposes the existing test/acceptance panel for combined reviews, with labels describing all reviewed files and the shared snapshot. Save remains per-file. Changes after review can require a fresh review; this is not an atomic disk transaction or an integration/rebuild workflow.

Validation: full runtime suite 751 tests/0 failures; 17 sandboxed runner tests including joint source/test replacements that fail separately and pass together, partial-save rejection and unrelated-file rejection; 20 focused UI tests; 28 native workflow checks including actual process restart with preserved acceptance. Release build, runtime compile, intent gate 6 held covering 25/25 human-control mutations, ACL 35 held and whitespace checks passed. Five selected native screenshots inspected. Native fixture uses a deterministic local provider, not real-provider dogfooding. An initial fixture attempted to click a hidden list item for an already-open plan; corrected to respect the visible view.

Tests: tools/proposal-test-runner-spec.mjs (set SUPER_RUNNER_TEST_ROOT to a disposable directory), tools/combined-testing-smoke.mjs (via tools/native-ui-test.sh), ampd/test/development_attempt_test.exs and tools/task-progress-test.mjs. Existing fixed JS/Elixir/Rust profiles remain bounded; this does not select a required profile policy per task.

Next: required-check policy, integration/rebuild within Super, repeated real-provider development cycles, and release/recovery readiness.
