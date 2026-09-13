# T&R road surface in Super

**Status: implemented, Linux integration measured 2026-09-12.**

**3D travel added in the subsequent pass.** The shared road now uses Three.js
from RRABBIT checkpoint `de1252a`
and the same geometry constants as T&R. Scroll or use Up/Down to drive; Entrance
passes through the entrance gantry, Exit travels past the end gantry, Home
returns to the start, and End drives to the exit. Selecting an app flies to its
front normal before creating the native pane. Leaving destroys that pane and
flies back to the saved lane position. Published sign faces are textures;
no live webview image is sampled. Keyboard focus highlights the 3D sign.

This pass measured **22 integrated checks**, **29 standalone lifecycle checks**,
and **23 accepted-handoff checks**, all passing. The fullscreen pose probe
observed the approach with no native pane and measured zero pixel offset at
arrival. The original compositor build and its 65 operation, 35 wiring and
34 track-store checks passed after extracting the shared geometry constants.

The cockpit's **T&R road** button opens the road in the same Super process.
The road fills its window, supports native fullscreen, hosts Notes and Digest
as child webviews, and exposes a **Super (CD)** sign to return to the cockpit.
Services contains the diagnostic controls; the normal road has no JSON panel.

The cockpit is still the `main` webview. The road is `cd-road`, in a separate
window, with a disjoint capability. It cannot submit runtime intents, open
terminals, select repositories, or use bot/development commands. Returning to
the cockpit closes the road's live app pane and leaves road fullscreen first.
Closing and reopening the native road window creates a new generation; late
destruction events only clean up the generation they belong to.

The code is the shared `RRABBIT/tier1-proof` Rust library with its
`super-integration` feature. `cockpit/build.rs` copies the frontend into
`cockpit/ui/road` from the adjacent RRABBIT checkout. Edit that source, not the
generated copy. Both repositories must be available in the existing sibling
layout to build Super. The standalone harness still builds independently.
The shared-runtime checkpoint for this integration is RRABBIT `9365ee9`.

```sh
cd cockpit
cargo build --release --offline
cd ..
tools/start-desktop.sh
```

Use **T&R road** in the cockpit. `SUPER_ROAD=1 tools/start-desktop.sh` also opens
the road at startup. This does not start the standalone road process.

```sh
node tools/check-webview-acl.mjs
node tools/road-battery.mjs /tmp/super-road.png
```

The native integration test uses an ephemeral runtime world and never opens
the user's saved world. It measured 17 passing assertions with the optional
capture enabled: entry from the cockpit, host recognition, road/app denials,
fullscreen, app pane creation, return, road reuse, native close/reopen and
stale-generation rejection. It requires the existing Tauri/WebKit driver,
X11 capture tools, and a C compiler/X11 headers for the native close helper.
At the initial integration checkpoint, Super's cockpit battery passed **89 checks**, and the expanded
static ACL gate passed **41 checks**. The shared runtime's four principal tests
passed with the integration feature enabled. These are targeted integration and
regression results, not a new claim that the complete sabotage sweep was run.

**Two-lane pass, 2026-09-12:** Documents contains Notes; Summaries contains Digest.
The lane sign takes a paved exit/return/entrance ramp. Accepted handoffs travel
to the destination lane before opening its app; leaving restores that lane's
saved read-entry position. Driving cannot interrupt a connecting ramp. These are
fixed presentation lanes, not Super runtime work lanes, and N=1 is unchanged.

The two-lane integration battery passed **30 checks**, including two captures,
on a 1920×1080 isolated Mutter/XWayland desktop. The user's locked desktop paused
animation frames, so the test ran without unlocking it. Headless GPU buffer
allocation failed initially; the passing run used software rendering:

```sh
WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 \
  dbus-run-session -- mutter --headless --wayland --virtual-monitor 1920x1080 \
  -- node tools/road-battery.mjs /tmp/super-lanes.png
```

This proves the native transitions on that test display, not physical monitor
performance. The static capability gates remained 41/41 in Super and 24/24 in
the shared runtime. No new full sabotage-sweep or macOS claim is made.
The accepted-handoff battery passed 24 checks, including destination-lane arrival.
The fullscreen native pane measured 1382×670 at (269,205), zero offset in all
four coordinates, at 1920×1080 and 1× scale. The integration battery also checks
the destination lane's projected sign against the CSS read frame.

The full T&R cockpit, cockpit-as-an-in-road-pane, and routing
Super runtime tasks through road manifests are not implemented. macOS remains
unmeasured. This separate-surface integration does not decide the pending
ROAD_SHELL §13 ruling about replacing Super's `main` with the road.
