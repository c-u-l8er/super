# Real Super dogfooding: proposal to running app

September 10, 2026. This cycle used Super’s real ChatGPT/Codex connection after explicit user authorization. The model was gpt-6-astra; no provider fixture or synthetic acceptance was used.

Super proposed a one-line fix: failed builds whose reason is timeout now show **Build timed out**. The original snapshot, running, interrupted, completed, cancelled and generic failure rules remain intact.

## What completed

- Created a plan with criteria in a separate saved world and a captured copy of current Super source.
- Sent the selected component, plan metadata and fix instructions through Super. Workspace context sharing was off.
- Reviewed the exact returned one-line diff, preserving its source and result identity.
- Ran the required JavaScript profile inside Super: **20 checks passed**. The added regression test failed before the proposal.
- Used Editor Save, then accepted the exact passing result inside Super.
- Used **Build accepted app** to compile the full accepted Super source offline.
- Launched its generated bundle separately. The captured runtime connected, development plans rendered, and the embedded component returned **Build timed out**.
- Promoted only the accepted component and regression test into the main checkout after verifying the original file identity. Main release build, 20 UI tests, 6 intent checks, 35 access checks and whitespace checks passed.

## Evidence and limits

The native workflow recorded 9 assertions and 10 screenshots. Key review, tests, acceptance, build and startup screenshots were visually inspected. The previous increment’s broader runtime, native recovery and compiler suites were not rerun for this one-line presentation change.

The provider result was reviewed and accepted under supervision. Source promotion and the separate launch were performed by this coding task. Super still needs a clearer launch/install handoff, rollback, retained-build cleanup and more ordinary real-provider cycles. The broader MVP is not finished.

Accepted snapshot: `079d5e2230b744e8d1c88162b44c6964d813eb7d4c65d8b47086814d6cdd3783`  
Executable SHA-256: `1fcfdbf52e63903837ffaadd05aef80c368f848454451243c09c75cc77b21f01`

Evidence gallery and receipts: /home/travis/Documents/Codex/2026-09-10/let-s-continue-super-development-where-2/outputs/Super_Real_Dogfood_Gallery.html
