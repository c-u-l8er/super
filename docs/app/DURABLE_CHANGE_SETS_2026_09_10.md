# Durable combined review records — 2026-09-10

Save combined review records one development-review-set@1 in the existing durable development_attempts collection. It stores two to four exact file members, each with the existing selected-file source record and shared/proposed text. The runtime validates per-file bytes and hashes, distinct membership, common HEAD, plan/repository/world context and current task revision. It derives aggregate source/result identities from the ordered path/identity pairs. These are human-recorded material, not attestation.

record_development_change_set is a bounded human-control mutation dispatched through the existing Authority/Loci transaction. It does not introduce a new participant or permission grant. client_ref provides exact-request idempotence; collisions refuse. Review notes use the existing versioned updates and preserve material. Legacy single-file text checks, test starts, native test lookup, and acceptance refuse combined records until the matching workflows exist.

The combined review UI verifies every member before recording and presents all retained files and history on the plan. Recording, staging, per-file Save and acceptance stay distinct. Task guidance identifies combined reviews without suggesting unsupported tests.

Validation: 750 runtime tests, 34 JavaScript tests, 31 native workflow assertions including SIGKILL/restart in a disposable saved world; release build and warnings-as-errors runtime compilation; six intent checks covering 25/25 human-control mutations; 35 WebView ACL checks. Eight final screenshots inspected. Native tests use a deterministic local provider. No new real-provider dogfood cycle is claimed. A native fixture comparison was changed from JSON string equality to structural equality to ignore bridge key ordering.

Tests: tools/development-change-set-smoke.mjs, tools/file-proposal-set-test.mjs, tools/task-progress-test.mjs, ampd/test/development_attempt_test.exs. Run native tests via tools/native-ui-test.sh with the established isolated display configuration.

Next: tools/lib/proposal-test-runner.mjs currently accepts selected-file-basis@1 and overlays one proposed_text. Add explicit set validation and overlay all members, bind output to aggregate source/result identities and the resulting snapshot, then extend saved-file acceptance preflight across every member. Enable UI/runtime controls only with corresponding positive and negative tests. Existing single-file behavior must remain compatible.
