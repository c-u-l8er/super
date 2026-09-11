# Durable development plans — September 8, 2026

Development tasks now has a sidebar destination. A person chooses an existing lane assigned to a registered bot, writes a task title and acceptance criteria, and creates a durable plan. Workspace, goal, repository, bot and requested base revision come from that lane. Bot Work and related workspace/goal/lane/bot/repository records link to the task workflow.

A plan has an ordered identity, revision and append-only planning history. Planned, blocked and cancelled are the available states. Updates require a reason and the revision the person reviewed. Repeating the exact creation request or most recent update returns its existing result; a conflicting stale update refuses. Cancellation is terminal for this plan. The record is retained, not deleted.

These are human-authored plans, not execution runs. Creation starts no process and adds no grant. Planning states cannot claim running, validated or accepted work. The lane base is a requested reference, possibly absent or symbolic; it is explicitly not a tested result. Pinning actual source bytes, assigning a run identity, execution, validation and acceptance remain subsequent work.

`development-task@1` lives in the existing loci store. Old and sealed snapshots gain an empty collection without authority. Creation and update use two typed human-control mutations in the existing native intent queue and ordered store boundary. Planning records are supplied through the operator projection only. The app waits for confirming frames and clears current task visibility on withdrawal; it never installs a submission response as current runtime state.

Limits: 50 plans, 64 KiB aggregate logical directory size, 32 history events per plan. Existing records remain intact when a limit refuses a write. These are bounded first-slice limits; archive/paged history must replace them before extended daily use. Saved plans survive store restart. Unsubmitted task forms are not yet persisted across page/process restart. Existing conversation and editor recovery remain independent.

The editor-selected repository is still a separate native selection. A task's lane repository reference does not automatically select it or give the editor new filesystem authority. The next stage must verify that connection before recording a tested result.
