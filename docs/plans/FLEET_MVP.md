# Two-machine fleet MVP

Updated 2026-09-14. User now has Proxmox and FreeBSD on the same home network.
This adds a fleet delivery alongside the existing provider-recovery work.

## Current evidence

- FreeBSD: `cd-floor-01`, SSH alias of the same name, unprivileged user `travis`, last known address `192.168.1.71`. Read-only SSH succeeded today: FreeBSD 15.1-RELEASE, 16 logical CPUs, 30,854,651,904 bytes RAM. Git is available; Node, Erlang and Elixir were not found in the login environment.
- Proxmox: management address `https://192.168.1.69:8006/`, recovered from task **Connect Proxmox via Ethernet**. Its browser certificate requires the user's manual acceptance in this task. No trusted SSH host key is configured locally for this address. Guest inventory and resources remain unverified.
- `192.168.1.70` / Locuvault was the older Omarchy setup in the same task. It is not the Proxmox address and is not currently reachable. Do not enroll it as a third machine.
- FreeBSD Wi-Fi SSH was previously configured in **Install FreeBSD research node**, using a pinned SSH identity and access from laptop `192.168.1.68`. Addresses are DHCP and may change.
- Fleet & placement is currently an unavailable destination in the desktop. Runtime peers represent local channel bindings, not enrolled network machines.
- The execution host uses Linux-specific `/proc`, process identity and confinement facilities. Reachable FreeBSD is not evidence of a portable Super worker.

## First delivery

1. **Inventory preflight (implemented).** `node tools/fleet-probe.mjs SSH_ALIAS` makes one bounded, host-key-checked SSH request. It reports identity, CPU count, memory and tool presence. Failed or malformed observations have no usable inventory. It does not enroll a host, install software, forward an agent, or assert worker readiness. Evidence lives in the development workspace under `outputs/fleet-bootstrap/`.
2. **Verify Proxmox and select a Linux guest.** Inspect existing guests and available resources after management access is established. Prefer a dedicated Linux guest for Super execution. Choose its storage, resource limits and network route from actual host inventory. Preserve existing workloads. Wi-Fi host management does not prove guest networking works.
3. **Define enrollment and observation contract.** Persistent host identity, user-visible name, verified transport identity and selected guest; separate last successful observation from current availability. Poll outside the authority mutation path with bounded responses, backoff and stale-state withdrawal. No idle poll may create runtime refusal traffic. Define a projection-backed inventory before implementing its desktop consumer.
4. **Build the Fleet screen and schematic.** Show named hosts, OS, actual capabilities, last contact, unavailable reason and one next action. Distinguish physical Proxmox host, its Linux guest, and FreeBSD node. Connections: task → assigned bot → eligible execution guest → request → evidence. Mark these as observed relationships only when runtime evidence exists.
5. **Run one bounded remote check.** Bind the request to host identity, task revision, repository snapshot and a unique request ID. Stage exact source in a dedicated guest workspace; run a defined check with resource limits; return output and exit status. Keep output/logs separate from approved source changes. Do not install provider credentials on the fleet merely to run checks.
6. **Prove interruption behavior.** Disconnect while idle and during a request, restart the observer, reconnect and repeat. Surface unknown remote outcome explicitly; reconcile durable request IDs before retrying. An SSH timeout does not prove the remote process ended. No duplicate check or automatic source application.

## Acceptance gate

Both physical machines are named in Super with truthful current observation states.
A selected Linux guest runs one real task-bound check whose output and outcome are
visible in Continue work and Schematics. Offline/reconnect behavior cannot fabricate
readiness, completion, or rerun an uncertain request. FreeBSD remains observation-only
until its execution backend passes separate platform checks.

## Research supporting the transport choice

- [OpenSSH client configuration](https://man.openbsd.org/ssh_config.5): batch mode, strict host-key checks, forwarding controls and connection liveness. Existing SSH provides a practical first transport; job lifecycle still needs its own records.
- [FreeBSD security handbook](https://docs.freebsd.org/en/books/handbook/security/): OpenSSH is included with FreeBSD, supporting the initial observation path without installing another daemon.
- [Proxmox network configuration](https://pve.proxmox.com/wiki/Network_Configuration): guest bridges and routed configurations must be verified separately from host management access.

The first fleet pass does not require clustering Proxmox or distributing the Super
authority world across hosts. Keep the existing world as the source of task and
review decisions while introducing a specifically scoped remote execution path.
