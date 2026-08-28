# W.2.2 · addendum, written AFTER the artifact was sealed

**This file is deliberately outside `and-super-rev-w22.zip`.** The receipt binds the archive's
figures to the archive's bytes, and editing a document inside it after packaging would break
exactly the property W.1.4.1 was spent establishing. Everything below happened after
`RELEASE OK`, so it travels beside the artifact rather than in it.

Artifact this refers to:

```
and-super-rev-w22.zip
  sha256   d0a2a1877423218846a235428630f77941e5c8ea1dfbaad948809b71dd6e3a96
  content  bed61ce4a8efb493a3747ef363ede80d1f383b8e981c519ac3c2911ecc50de59
  146 files · 1,569,661 bytes · artifact_replay: scope matched, content byte-identical
```

---

## 1 · The flagship passed on the run that produced this artifact

`§6` of the brief describes a wedge that failed the flagship on the **first** attempt at this
revision. That section stands and should be read. What it could not say, because it was written
before the run finished:

```
attempt 1   cockpit battery: 25 held · 6 failed     ← §6
attempt 2   (killed by me before the cockpit stage — a sed had gone dead, §4)
attempt 3   cockpit battery: 32 held · 0 failed     ← this artifact
```

So the wedge is confirmed **intermittent** rather than deterministic, which is what §6 assumed
and is the reason it recommends withholding the LIVE LOCAL freeze. A green run does not retire
it. Standalone reproduction attempts now total **six full battery runs and eighty
hold → intent → release cycles**, all green.

---

## 2 · A second hypothesis, formed after the brief and **refuted by measurement**

Before packaging I had one candidate for §6 — `Delivery::send` dropping the sink on a transient
`Channel::send` error. Afterwards I found a second one that fit better, and then measured it
away. Both halves are worth recording, because the second is a real property of the transport
that this product is now sitting close to.

### The hypothesis

`tauri-2.11.5`, `src/ipc/channel.rs`, `channel_on()` has **two delivery paths chosen by payload
size**:

```rust
const MAX_JSON_DIRECT_EXECUTE_THRESHOLD: usize = 8192;

InvokeResponseBody::Json(s) if s.len() < MAX_JSON_DIRECT_EXECUTE_THRESHOLD =>
    webview.eval(format_raw_js(callback_id, …))?,          // direct

_ => {                                                     // park + fetch
    webview.state::<ChannelDataIpcQueue>().0.lock().unwrap().insert(data_id, body);
    webview.eval(format!(
      "window.__TAURI_INTERNALS__.invoke('{FETCH_CHANNEL_DATA_COMMAND}', …)
         .then((response) => window.__TAURI_INTERNALS__.runCallback({callback_id}, …))
         .catch(console.error)"))?;
}
```

On the second path `Channel::send` returns `Ok(())` as soon as the `eval` is *injected*. The
Rust side therefore believes the frame was delivered and sets `in_flight = Some(seq)`. If the
page's follow-up fetch then fails, the message dies in `.catch(console.error)` — `onmessage`
never fires, nothing is acknowledged, and the valve is closed forever.

That is the W.2 wedge, arriving through the mechanism the Channel was adopted to remove, and it
is **size-dependent** — which is what an intermittent failure looks like. `Channel<Value>`
serializes through `impl<T: Serialize> IpcResponse for T`, so the JSON arm and its 8192-byte
threshold govern every cockpit frame.

### The measurement

Frames measured as the page receives them, at queue depth 1, with the fixture seeded and the
world moved three times:

```
THRESHOLD: 8192 bytes

  seq   1    2342 bytes  live-local  direct eval
  seq   2    2342 bytes  live-local  direct eval
  seq   3    2342 bytes  live-local  direct eval
  seq   4    2342 bytes  live-local  direct eval

  largest frame: 2342 bytes · 5850 bytes of headroom
```

**Refuted.** Every frame takes the direct path with more than twice its own size to spare, and
the size did not move as the world moved. So the fetch path is not what wedged the flagship,
and §6's sink hypothesis remains the one I would test first.

### Why it is still worth writing down

The margin is 5,850 bytes, and `Ampd.Projection.operator/0` is not a fixed-size document. It
carries `authority_snapshot`, `pending_approvals`, `effects`, `channels`, `peers`,
`recent_refusals` (up to 20), and four windowed histories — `receipts`, `effects_history`,
`grant_requests_history`, and the request history. A world with real traffic in it crosses 8192
without anything in this repository changing.

At that point every cockpit frame silently switches to a delivery path whose failure mode is
`console.error` and whose success the sender cannot observe — and the one-frame-in-flight valve
turns a lost message into a permanent wedge rather than a dropped frame. **Nothing measures
that boundary today**, and the battery would not notice being on the far side of it until a
frame went missing.

If §6 is investigated, this is the second thing to instrument, and the cheap version is a check
that asserts the frame stays under the threshold — which would also be the thing that tells you
the day the projection outgrows it.

---

## 3 · What I am not claiming

- I did **not** reproduce the §6 wedge. Six battery runs and eighty cycles, all green.
- I did **not** prove the sink hypothesis. `Channel::send` bottoms out in the webview's IPC and
  I found no way to make it fail on demand.
- The refutation in §2 is scoped to **this workload** — a fixture world with one grant. It says
  the fetch path was not reached here; it does not say it cannot be.
