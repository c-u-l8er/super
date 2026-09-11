# Super: required plan checks

September 10, 2026

Super now saves required test profiles with a development plan. The plan form defaults to JavaScript and allows Elixir and Rust to be selected. At least one is required in the app. Reviews show missing or failed required checks and only offer acceptance when every required profile, plus every other profile actually run, has its latest passing result on the same captured source snapshot. The runtime independently enforces that rule during acceptance preparation and acceptance.

Required checks persist through planning status updates and restart. They cannot be edited on an existing plan in this increment; create a new plan for a different policy. Existing plans and older clients that omit the new optional field retain the legacy rule: all profiles actually run must pass on the same snapshot. No existing records are silently migrated.

## Verification

- 752 runtime tests passed, including required-profile omission, failed required results, eventual passing coverage, invalid/duplicate/empty policies, retry conflicts and legacy compatibility.
- 21 focused UI behavior tests passed, including required profiles absent from run history and existing snapshot/failure rules.
- 32 native workflow assertions passed on the rebuilt app: empty selection refusal, durable policy, missing and failed checks, successful rerun, combined testing, partial-save refusal, unrelated-edit refusal, acceptance and actual process restart.
- Release build, warnings-as-errors runtime compilation, six human-control boundary checks (25/25 mutations), 35 webview access checks and whitespace checks passed.
- Native screenshots were captured and visually inspected. The first inspection found checkbox spacing that was corrected before the final build and screenshot pass.

The native test uses a disposable Git repository, saved runtime world and deterministic local provider fixture. It deliberately makes the JavaScript test fail, restores the fixture test, and reruns against a newly captured snapshot. Missing additional required profiles are separately exercised by runtime and UI tests. This is not another real-provider dogfooding cycle.

## MVP impact and remaining work

This closes the basic required-check policy gap for newly created app plans, including combined-file reviews. It does not yet provide custom test commands or editing a plan's policy. Existing language profiles remain focused checks, not whole-project certification.

Integration and rebuilding from inside Super, recovery edge cases, installation checks and repeated ordinary Super development tasks through a real provider remain. The broader MVP is still unfinished.

Evidence: current Codex task outputs/Super_Required_Checks_Gallery.html.
