# Persistent Fleet settings

Super reads `$XDG_CONFIG_HOME/super/fleet.json`, or
`$HOME/.config/super/fleet.json` when the XDG path is unset, empty or relative.
This follows the [XDG base-directory specification](https://specifications.freedesktop.org/basedir/0.8/).
Settings are local operator configuration, not a world record or a webview input.
Create the file privately (mode 0600) with absolute paths:

```json
{
  "schema": "super-device-fleet@1",
  "snapshotPath": "/absolute/path/to/collector/snapshot.json",
  "checksConfigPath": "/absolute/path/to/restricted-check/config.json"
}
```

The existing collector owns and atomically updates the snapshot. The check
configuration still pins the approved target, key and known-hosts file; this
settings file neither enrolls a host nor grants execution or acceptance.
The app reads settings at launch. Restart after changing them.

`SUPER_FLEET_SNAPSHOT` and `SUPER_FLEET_CHECK_CONFIG` independently override saved
settings. An explicitly empty variable disables that feature for the launch;
an invalid explicit path does not fall back to the saved configuration.
Missing, malformed, unsupported or relative saved paths leave the relevant
feature unconfigured. Configuration files are bounded when read.

Isolated native test sessions receive their own XDG configuration directory;
explicit fixture environment paths remain supported. Real-world verification
must stop the app and take the usual locked backup first.

## FreeBSD next gate

A read-only inspection on 2026-09-14 confirmed FreeBSD 15.1, Wifibox PID 4153,
457 GiB available in zroot, no host IP forwarding, and grub2-bhyve installed.
UEFI firmware was absent at the standard package path. No separate Super guest
exists. Preserve Wifibox, tap0 and the current management route.

Next: provision a distinct Linux guest, boot firmware, storage and an isolated
network with a tested return path. Do not reuse Wifibox's VM or passed-through
Wi-Fi hardware. Consult the official [FreeBSD virtualization handbook](https://docs.freebsd.org/en/books/handbook/virtualization/).
Guest creation and a physical network-outage drill are not yet completed.
