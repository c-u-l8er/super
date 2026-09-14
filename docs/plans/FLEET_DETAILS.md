# Machine, VM and record navigation

Machine and VM observations use the existing record-page lifecycle and history. Fleet registers one machine record per host and one VM record per (host, guest ID). Display names never determine routes. Machine pages link to their VMs; VM pages link to their host. Schematic nodes open the same records. Failed or removed observations cannot retain a live guest detail, and stale observations show unknown guest state.

The existing workspace, goal, lane, worker, bot, repository, evidence and authority record pages remain the corresponding detail surfaces. Shared record rows now display exact stable identities, names, state and available relationship context. Workspace selection and reference-bearing options also retain IDs. Repository projection exposes a folder leaf name plus reference, never its full local path. Missing names fall back to exact references instead of numbered aliases.

Guest resource metrics, lifecycle commands and additional check enrollment need their own verified backend contracts. The VM page labels missing CPU/memory/disk measurements as unavailable. It does not infer guest resources from host capacity or treat a present bhyve device as proof of running state. No new execution authority is added.

Validation includes duplicate names, identical guest IDs on different hosts, stale and unavailable observations, native machine/VM/back navigation, small-window layout, and saved-world repository labels. The existing locus confinement test at line 1587 fails during worktree setup on the unchanged baseline too; the new repository test verifies leaf-only projection directly.

Design reference: [W3C link-purpose guidance](https://www.w3.org/WAI/WCAG22/Understanding/link-purpose-in-context.html): destination names and their associated context should distinguish navigation choices.
