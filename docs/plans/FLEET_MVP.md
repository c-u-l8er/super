# Two-machine fleet MVP

Updated 2026-09-14. User now has Proxmox and FreeBSD on the same home network.
This adds a fleet delivery alongside the existing provider-recovery work.

## Current evidence

- FreeBSD: `cd-floor-01`, SSH alias of the same name, unprivileged user `travis`, last known address `192.168.1.71`. Read-only SSH succeeded today: FreeBSD 15.1-RELEASE, 16 logical CPUs, 30,854,651,904 bytes RAM. Git is available; Node, Erlang and Elixir were not found in the login environment.
- Proxmox: `locuchest`, management address `https://192.168.1.69:8006/`. SSH verified against the user-supplied ED25519 fingerprint on 2026-09-14. Proxmox 9.2.2, Ryzen 7 PRO 6850U, 16 logical CPUs, 28,841 MiB RAM, approximately 349 GiB empty thin guest storage at enrollment. No pre-existing VMs or containers. Browser access remains certificate-limited; verified SSH works.
- `192.168.1.70` / Locuvault was the older Omarchy setup in the same task. It is not the Proxmox address and is not currently reachable. Do not enroll it as a third machine.
- FreeBSD Wi-Fi SSH was previously configured in **Install FreeBSD research node**, using a pinned SSH identity and access from laptop `192.168.1.68`. Addresses are DHCP and may change.
- Fleet & placement now consumes bounded host observations through the operator projection and has a host/guest schematic. Runtime peers remain local channel bindings, distinct from these network observations.
- The execution host uses Linux-specific `/proc`, process identity and confinement facilities. A Linux guest under FreeBSD bhyve can provide that environment without first porting the execution host. FreeBSD already has bhyve, the loaded vmm module and an existing Wifibox guest; that guest supplies Wi-Fi and is not a Super worker.

## First delivery

1. **Inventory preflight (implemented).** `node tools/fleet-probe.mjs SSH_ALIAS` makes one bounded, host-key-checked SSH request. It reports identity, CPU count, memory and tool presence. Failed or malformed observations have no usable inventory. It does not enroll a host, install software, forward an agent, or assert worker readiness. Evidence lives in the development workspace under `outputs/fleet-bootstrap/`.
2. **Linux guest provisioned and bootstrap validated.** VM 100, `super-worker-01`, Debian 13, 4 vCPUs, 8 GiB fixed RAM, 48 GiB thin disk. Official cloud image verified with SHA-512. Proxmox built-in user-mode NAT supplies guest DHCP/DNS through existing Wi-Fi without host forwarding or firewall changes. Guest administration uses the QEMU guest agent through the verified Proxmox connection; the `super` check account has a locked password and no sudo grant. A one-shot native test is a bootstrap measurement, not task-bound dispatch from Super.
3. **Observation contract implemented; execution enrollment remains.** Persistent host identity, user-visible name, verified transport identity and selected guest; separate last successful observation from current availability. Poll outside the authority mutation path with bounded responses, backoff and stale-state withdrawal. No idle poll may create runtime refusal traffic. Define a projection-backed inventory before implementing its desktop consumer.
4. **Fleet screen and host/guest schematic implemented.** Show named hosts, OS, actual capabilities, last contact, unavailable reason and one next action. Distinguish physical Proxmox host, its Linux guest, and FreeBSD node. Connections: task → assigned bot → eligible execution guest → request → evidence. Mark these as observed relationships only when runtime evidence exists.
5. **Run one bounded remote check.** Bind the request to host identity, task revision, repository snapshot and a unique request ID. Stage exact source in a dedicated guest workspace; run a defined check with resource limits; return output and exit status. Keep output/logs separate from approved source changes. Do not install provider credentials on the fleet merely to run checks.
6. **Prove interruption behavior.** Disconnect while idle and during a request, restart the observer, reconnect and repeat. Surface unknown remote outcome explicitly; reconcile durable request IDs before retrying. An SSH timeout does not prove the remote process ended. No duplicate check or automatic source application.

## Acceptance gate

Both physical machines are named in Super with truthful current observation states.
A selected Linux guest runs one real task-bound check whose output and outcome are
visible in Continue work and Schematics. Offline/reconnect behavior cannot fabricate
readiness, completion, or rerun an uncertain request. FreeBSD remains observation-only
until a separate bhyve Linux check guest is provisioned and validated. Native FreeBSD execution portability is a distinct future option.

## Research supporting the transport choice

- [OpenSSH client configuration](https://man.openbsd.org/ssh_config.5): batch mode, strict host-key checks, forwarding controls and connection liveness. Existing SSH provides a practical first transport; job lifecycle still needs its own records.
- [FreeBSD security handbook](https://docs.freebsd.org/en/books/handbook/security/): OpenSSH is included with FreeBSD, supporting the initial observation path without installing another daemon.
- [Proxmox network configuration](https://pve.proxmox.com/wiki/Network_Configuration): guest bridges and routed configurations must be verified separately from host management access.

The first fleet pass does not require clustering Proxmox or distributing the Super
authority world across hosts. Keep the existing world as the source of task and
review decisions while introducing a specifically scoped remote execution path.

## Verified worker bootstrap, 2026-09-14

- VM 100 (`super-worker-01`) completed cloud-init, with Node 20.19.2 and a non-admin `super` account. Guest agent access works through the pinned Proxmox connection; no guest SSH port was forwarded.
- Eleven real tests passed inside the guest: six task-activity tests and five fleet-probe tests. Source commit `b3f79b98d882f75ade8843d1827b54519f8ce4b8`; the transferred archive's SHA-256 was checked before extraction.
- Outbound HTTPS returned 200 from Debian. A guest reboot changed its boot ID; the durable test receipt was identical afterwards and the test request was not resubmitted.
- The request was explicitly recorded as a setup-session check with no task reference. This does not complete the task-bound app dispatch, enrollment, lost-connection reconciliation or multi-host scheduling gates.
- Provisioning and evidence: development workspace `work/proxmox-fleet/` and `outputs/fleet-bootstrap/`. The tested source bundle and run script are retained. The cloud seed contains no provider credentials or login password.
- Next: define the runtime-backed host inventory, introduce Fleet screen observations and schematics, then add a task/snapshot-bound remote check with durable request reconciliation. FreeBSD execution portability remains separate.

## Runtime observation delivery, 2026-09-14

The local `fleet-collector.mjs` service reads explicitly configured SSH targets every
30 seconds (after each bounded collection). Proxmox uses a dedicated command-only
key restricted to this laptop, inventory output, no PTY and no forwarding. A test
request for a different shell command returned inventory only. Existing FreeBSD
SSH is used to observe the host and names in `/dev/vmm`; those guest entries are
labeled **present**, not claimed running or assigned to Super.

The collector atomically publishes a local owner-only snapshot. `Ampd.Fleet`
reads at most 64 KiB, validates up to eight hosts and 24 guests each, strips unknown
fields, and exposes only observations through the operator projection. No new
human-control or agent commands were added. Observation reads are not authority
operations. Identical snapshots do not advance the view clock; observations older
than 90 seconds lose current guest state. Invalid files withdraw the inventory.
`workerReady` is always false: connection and VM status do not grant execution.

Validation: 185 behavior tests, 5 runtime tests, 9 dedicated native Fleet checks,
and all 42 existing native schematic/workflow checks passed. Permission checks
passed (6 intent checks and 41 WebView checks). Fleet, diagram and narrow-screen
screenshots were visually inspected. Evidence is in `outputs/fleet-live/`.

The desktop delivery adds observation only. Next: a task-bound remote check using
a durable request ID, current task revision and exact source snapshot, followed by
lost-connection reconciliation. Then provision a separate Linux guest on bhyve,
preserving the existing Wifibox guest and its network path.

## Task-bound advisory check implementation, 2026-09-14

Implemented `fleet_checks` as a native, main-WebView-only command. Continue work
and development plans have a collapsed **Remote checks** panel; a matching result
has its own Schematics node. Records remain device-local and advisory, outside
runtime review tests and acceptance. This is not distributed scheduling.

The first profile captures four named files from one concrete Git commit: task
activity, fleet probing, and their two behavior-test files. Dirty edits, review
proposals, other source, dependencies and credentials are excluded. The UI names
that scope. Native code verifies the selected repository and current task revision
against the runtime before and after capture. Each request binds the world,
task revision, commit, file-content digest, Proxmox host and VM 100.

The proposed guest endpoint durably reserves a request before execution. It runs
one profile as `super` with bubblewrap filesystem/network isolation, a 512 MiB
systemd memory limit, 128 tasks and a 35-second runtime limit. Receipts are private
and outside the test namespace. The same request ID is never executed twice;
status retrieval reconciles uncertain results. An interrupted reservation stays
unknown. Unknown requests block new dispatch on the device; explicit abandonment
and retention management are future work. Tests do not grant worker readiness.

**Historical activation gate (approval received in the next turn).** Automatic approval review rejected
installing a separate Proxmox root authorized key and privileged fixed-command
bridge. Neither the bridge/key nor the guest endpoint was installed by this
increment. The running inventory observer is unchanged. The desktop is shipped
without `SUPER_FLEET_CHECK_CONFIG`, so execution controls stay disabled.

The reviewable endpoint sources are `tools/fleet/worker.py` and
`tools/fleet/proxmox-bridge.py`; transport and durable local request handling are
in `tools/fleet/check-client.mjs`. The proposed key is restricted to this laptop,
no PTY or forwarding, and this fixed endpoint in VM 100. It does not authorize
arbitrary host commands. Enabling it still changes root SSH authorization, which
is why explicit approval is required.

Validation evidence: development workspace `outputs/fleet-checks/`. Native UI
screenshots are labeled simulation fixtures, not remote execution evidence.
After approval: install the endpoint/key, run a real task-bound check through the
app, test lost-response reconciliation and inspect actual result screenshots.
Then provision a separate bhyve Linux guest without disturbing Wifibox.

Transport research: [QEMU guest agent reference](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html#command-guest-exec-status)
explains that process status retrieval reaps completed metadata. Therefore the
worker's durable receipt, rather than a guest-agent PID, is the reconciliation key.

This increment passed 191 JavaScript behavior tests, eight guest-ledger tests,
two native request-boundary tests, nine native UI checks with simulated outcomes,
and the 42 existing native Continue work / Schematics checks. Static permission
checks also passed. A narrow desktop header wrap found during screenshot review
was fixed and verified. Actual remote execution remains untested for this new
endpoint until its installation is approved.

## Approved activation and real app checks, 2026-09-14

The user explicitly approved the restricted Proxmox key, fixed bridge and VM-100
runner. Installed those endpoints and bubblewrap. Verified that requesting an
alternate shell command with this key still returns only the fixed endpoint's
status response. No provider credentials were copied to the guest.

Super dispatched the current saved plan `dt_0039`, revision 1, from the native
Continue work control. Eleven real tests passed on committed source `f157d419`.
The four-file snapshot digest is
`6e80550427ee941d6e76c9630cb99d8bf8bc86257460d62910f119b730c6e7bb`.
First request: `fc-7fa4c0256e9bfd70fb11cb33b265f9d1`.

A second real request, `fc-1f75428d6d9bbefc16aa5197402c9e82`, had its local
result receiver deliberately stopped and killed after dispatch. The app showed
an unconfirmed outcome and disabled new starts. **Check remote status** recovered
the original passing receipt; no second start was submitted. This tests a real
receiver interruption, not a simulated result or a physical network outage.
Accepted review `da_0038` and the task revision were unchanged.

Fixed guest source-directory permissions for a restrictive agent umask while
keeping receipts private. Added a direct Fleet → Continue work route and removed
empty status boxes. Evidence and actual screenshots: `outputs/fleet-active/` in
the development workspace. Startup uses `SUPER_FLEET_CHECK_CONFIG` pointing to
`work/fleet-checks/config.json`; the separate observation service is unchanged.

During restart verification, guest kernel 6.12.107 faulted in ftrace/BPF teardown
while systemd was shutting down. A full VM stop/start recovered the agent; both
receipt hashes survived unchanged. A 743 MB VM backup was retained at
`/var/lib/vz/dump/vzdump-qemu-100-2026_09_14-15_14_33.vma.zst` (guest freeze was
unavailable). Debian's existing backports repository supplied kernel 7.1.8; the
old kernel remains installed. Kernel-only replacement did not resolve shutdown,
so the virtual CPU configuration is being tested separately. Do not describe this
as a confirmed upstream kernel fix. Consult the final verification below.

### Verified worker configuration

VM 100 now uses the standard `x86-64-v3` CPU profile with Debian kernel
`7.1.8+deb13-amd64`. A normal Proxmox reboot succeeded and the guest agent returned;
the two prior receipts were byte-for-byte unchanged. The exact upstream cause is
not isolated: kernel replacement alone failed, while this CPU/kernel combination
passed. Original CPU configuration and kernel are retained for rollback.

The app then ran eleven tests successfully again on this configuration, request
`fc-2bf78cdca1e3a10e9eb30e6c5bea9f31`. All three runs are advisory checks for the
same saved task revision and committed snapshot. General worker placement,
proposal acceptance using remote evidence, a physical network-outage drill,
and a separate FreeBSD bhyve Linux guest remain future gates.

### Standalone launch persistence

Fleet now supports saved local settings as well as explicit launch overrides.
See [device settings and the FreeBSD next gate](FLEET_DEVICE_SETTINGS.md).
The native fixture harness isolates its configuration directory. Verification
must prove the installed app restores observations and retained check receipts
with both temporary Fleet environment variables removed.
