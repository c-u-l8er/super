# Every record id on screen is a reference

September 18, 2026. Travis, that evening: *"there are many areas of plain text where
the id of a record is being displayed without the hyperlink or tooltip thing we built
earlier … if this could somehow be standardized so this bug doesn't happen again
during dev that would be good … thorough checks to make sure this is working in every
place text is displayed."*

## What was wrong, measured at `2190d36`

`cockpit/ui/references.js` already rendered ids in text as links with a tooltip
(`a[data-record-ref]`, title `Kind: id — open current record`), and `openRecord`
answered the click. It was bypassed in two ways:

1. **The id pattern was typed by hand beside the kinds table**, and knew six prefixes
   (`ws gl ln wk rp bt`). Development plans (`dt_`) and review attempts (`da_`) were
   minted by the runtime, projected on every frame and searched by the palette — and
   never linked, even inside a paragraph.
2. **`node()` in `app-shell.js` linked `<p>` only.** Every span, summary, heading,
   list item, `small` and button carrying an id printed it plain: the record page
   header (`span.record-id`), the plan rows on record pages (`dt_… · rev … · status`),
   the palette results (`kind · id · title`), the attempt card summaries
   (`… · da_…`), the plan meta line, the related-work rows built by `detail()`.
   `development.js` (the Editor screen) and both phone modules had their own element
   helpers with the same omission.

## The rule

- **A record id in any text is a reference, by construction.** `node()` routes every
  tag through `referenceText` except raw-data and form tags (`pre code textarea input
  select script style`) and `option`, which keeps its own labelling. `development.js`'s
  `el()` and the phone's `node()` / `el()` follow the same rule.
- **The pattern is derived from the kinds table.** `references.js` holds one table —
  kind, prefix, projection collection, record route — and builds the regexp from it.
  Adding a kind is the whole change; a hand-typed list cannot drift from it again.
- **Two display forms.** `display:'label'` (default) shows the record's name with the
  id in the tooltip — prose. `display:'id'` shows the id with the name in the tooltip —
  for lines whose job is the identity: record headers, plan rows, palette results,
  attempt summaries, the plan meta line, related-work subtitles.
- **Inside a control there is no link.** A reference inside a `button`, `summary`,
  `label` or another `a` renders as `span.record-ref` with the same identity and
  tooltip; the control owns the click. A nested anchor is invalid HTML and steals the
  click. References built before their control existed are demoted after each frame
  (`demoteNestedReferences`, on `runtime-view-rendered`).
- **Plans and attempts route to the wizard, not a record page.** A plan or attempt
  link dispatches `open-development-task`; `development-tasks.js` answers with one
  `reveal(taskId, attemptId)` shared with `[data-development-task]` controls (record
  pages, the palette). An attempt id opens its card and switches the wizard to every
  section when the step hides it.
- **The phone** (`mobile/ui`) uses the same renderer through the gateway
  (`/references.js`), in id form; it can open a plan or an attempt's plan, so only
  those kinds are links there — the rest are tooltip spans (`setReferenceRouting`).

## What holds it

- **Static gate** `tools/check-reference-text.mjs`, in `tools/gates.sh`: no text sink
  (`textContent=`, `innerText=`, `createTextNode(`) under `cockpit/ui` or `mobile/ui`
  writes an id-bearing value; every generic element factory imports and calls
  `referenceText`; every collection the palette finder searches is a kind in the
  table; the derived pattern matches every kind; the runtime names every collection
  the table does. 31 checks. A new call site that bypasses the renderer fails it.
- **Unit tests** `tools/references-test.mjs` (9 tests, a ten-line fake DOM): pattern
  coverage, plan/attempt indexing and labels, both display forms, the control rule,
  demotion, routing per surface, the fast path, world isolation.
- **Driven smoke** `tools/reference-text-smoke.mjs`: real cockpit, throwaway world with
  a bot, lane and plan. Visits the rails, all 26 navigable screens, six record page
  kinds, the plan detail in every reachable wizard step and with every section shown,
  and the palette results; on each asserts no text node matches the pattern outside
  `[data-record-ref]` and no link sits inside a control. Then clicks a plan reference
  (opens the plan in the wizard), a repository reference and a workspace reference
  (open their record pages), and checks a lane id inside a related-work button is a
  tooltip span. **55 held · 0 failed.**

Also run on the rebuilt binary: `palette-records-smoke` 12/12, `plan-steps-smoke`
9/9, `registered-repository-smoke` 19/19, `mobile-conversation-smoke` all PASS;
`node --test tools/*-test.mjs` 284/284; `bash tools/gates.sh` 7 held · 2 failed
(ordered boundary, ordered closure — pre-existing, `ampd/lib` only).

## Not seen on a screen

- **A review attempt reference.** Recording an attempt needs the Editor's file-proposal
  flow, which the smoke world does not run; the route is unit-tested and shares the
  plan route. `mobile-task-discussion-smoke` could not run here (its native folder
  chooser did not confirm — environment, not this change).
- **The phone on a phone.** The gateway serves the renderer and the conversation smoke
  loads the page; no Android device is on the tailnet.

## Done outside Super, and why

Written directly. Six UI files change together (the rule is one rule), two of them
above the 24 KB share cap (`development.js` 54 KB, `development-tasks.js` 34 KB), and
the review-attempt directory is full (`attempt-directory-full` since the afternoon), so
no round could be recorded, tested or accepted through Super regardless. Recorded as a
plan with this note.
