# Before/after evidence

In a task review, **Run selected tests** has **Also run the starting source and compare benchmarks when configured** checked by default. Uncheck it for a candidate-only run.

The native runner captures the Git-listed working source once, validates the selected review basis, and retains two immutable snapshots: the source before the proposal and the source with the proposal applied. It runs the chosen profile on both. A baseline assertion failure is evidence, not a reason to hide the candidate result. Missing suites, timeouts and cancellation are not passing results. If the suite list differs, the comparison says so. Acceptance continues to use only the exact candidate test outcome and saved-file checks.

For JavaScript performance comparisons, put the same `tools/task-benchmark.mjs` in both snapshots. This is the only supported benchmark command; no arbitrary command is accepted from the task page. It must write a single JSON object to stdout:

```js
import {performance} from 'node:perf_hooks';
import {operation} from '../src/operation.mjs';
// Fix the input and do any in-process warmup required by the operation.
const input = Array.from({length: 1000}, (_, i) => i);
for (let i = 0; i < 1000; i++) operation(input);
let checksum = 0;
const iterations = 10000, start = performance.now();
for (let i = 0; i < iterations; i++) checksum += operation(input);
if (!Number.isFinite(checksum)) throw Error('Invalid operation result');
console.log(JSON.stringify({metrics: [{name: 'operation latency',
  value: (performance.now() - start) * 1e6 / iterations,
  unit: 'ns', direction: 'lower'}]}));
```

The runner uses one excluded warmup process and three measured processes per side, alternates their order, pins Node, and isolates every execution without network or home-directory access. Each sample has a five-second limit. Metrics must keep their names, order, units and direction across every sample. Supported units: ns, us, ms, s, bytes, ops/s, items/s, count. Values must be finite and nonnegative; a zero baseline has no percentage delta. Results retain raw samples, median, range, source hashes, entry-point hash, Node hash and host/CPU information. A benchmark error does not manufacture a passing benchmark. Three samples are exploratory evidence, not a statistical guarantee or a substitute for workload-specific validation.

Recorded before/after logs and benchmark results are retained automatically for the task revision and available to paired mobile. Imported logs stay separate.

## Local preview screenshots

Open the target local app in Super's Browser. In the task's Before/After panel, refresh preview tabs, select the correct tab, and use **Capture before from preview** or **Capture after from preview**. Super captures that WebKit viewport directly and attaches it; it does not capture the desktop, other applications or the task's review page. PNG and size restrictions remain in force.

Run the starting app version before capturing Before, and the changed version before capturing After. Capture records the actual local URL and viewport, but does not prove which source built the served app. Preview captures are operator-triggered; automatic launch of arbitrary baseline/candidate apps is not implemented. Existing manual screenshots and task history are never replaced by guessed baseline images.

References: [WebKit snapshot API](https://webkitgtk.org/reference/webkit2gtk/stable/method.WebView.get_snapshot.html), [Google Benchmark reporting and repeat controls](https://google.github.io/benchmark/user_guide.html).

## Android emulator screenshots

In Before and after, click **Refresh emulators**, expand **Capture an Android emulator** under the desired side, select the running emulator, and click **Capture before from emulator** or **Capture after from emulator**. Start the emulator and open the intended app screen first. Capture reads its actual full display, including system and browser bars, using Android's screenshot command. It works for the foreground app, including native apps; it does not require a Browser preview or an uploaded file.

Each image retains the emulator serial, model, Android version, pixel dimensions, foreground activity and capture time. The same images and identifying details are available on paired mobile. SDK discovery uses ANDROID_HOME, ANDROID_SDK_ROOT, the standard Linux user SDK locations, or /usr/bin/adb. Physical devices, offline devices, malformed targets, incomplete boot and a changing foreground app are rejected. A failed capture leaves the previous image intact. Existing PNG limits apply.

This is an operator-triggered capture of a running emulator. It neither builds nor launches the baseline/candidate app and therefore explicitly marks the app source version unverified. Automatic launch and source-bound capture remain unfinished. iOS Simulator capture is not implemented.

Reference: [Android screenshot command](https://developer.android.com/tools/adb#screencap), [Android emulator startup](https://developer.android.com/studio/run/emulator-commandline).
