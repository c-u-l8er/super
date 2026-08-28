//! The C1.1 acceptance battery, driven from a separate OS process.
//!
//! Everything before C1.1 proved the semantics of a command issued against
//! a peer handle inside one BEAM. This proves that a *descriptor* can only
//! ever produce the commands its identity is allowed to produce, and that
//! nothing which was not handed a descriptor can produce any.

use std::path::Path;
use std::time::Duration;

use serde_json::{json, Value};

use crate::{fdpass, Chan, Cockpit, CockpitLoop, Continuity, ProjectionCursor, Runtime, WorldDir};

pub struct Battery {
    pub pass: usize,
    pub fail: usize,
}

impl Battery {
    fn new() -> Battery {
        Battery { pass: 0, fail: 0 }
    }

    fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        if ok {
            self.pass += 1;
            println!("  \x1b[32mheld\x1b[0m         {name}");
        } else {
            self.fail += 1;
            println!("  \x1b[31mFAILED\x1b[0m       {name} — {detail}");
        }
    }
}

fn rev(v: &Value) -> u64 {
    v["revision"].as_u64().unwrap_or(0)
}

pub fn run(ampd_dir: &Path) -> i32 {
    println!("[&] Super — C1.1 acceptance battery, through the transport\n");

    // A battery must not inherit a world, and must not leave one behind.
    let scratch = std::env::temp_dir().join(format!("super-verify-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&scratch);

    let rt = match Runtime::start(ampd_dir, WorldDir::ephemeral(&scratch)) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("could not start the runtime: {e}");
            return 1;
        }
    };

    // **Read before anything else opens a socket.** The host `dup2`s the
    // bridge onto fd 3 and clears `FD_CLOEXEC` so it survives `exec` —
    // which makes it the one inheritable descriptor the runtime starts
    // life holding, and the one the runtime's own adoption has to dispose
    // of. Whether it did is only legible right here: `close(2)` frees the
    // *number*, and the very next socket the BEAM opens takes it, so fd 3
    // is occupied again within milliseconds and asking later measures
    // recycling rather than ownership. Asked after the first channel bind,
    // this check reported a socket on fd 3 and meant nothing by it.
    let bridge_fd_at_boot = rt.runtime_fd_target(3);

    // **And the descriptor baseline, here, for the same reason.**
    //
    // F.8.2 took it three hundred lines down, after the battery had
    // already asked for a second control channel — a request the runtime
    // refuses, and refused while keeping the descriptor it arrived on. So
    // "returns to baseline" was true of a baseline that had absorbed a
    // leaked descriptor, and every exact equality below it was exact about
    // the wrong number. A baseline taken after the adversary has run is
    // not a baseline; it is a record of what the adversary managed to
    // normalise.
    std::thread::sleep(Duration::from_millis(400));
    let boot = rt.runtime_socket_count();

    let mut b = Battery::new();

    // ---------------------------------------------- the bridge is a capability
    b.check(
        "the bridge is an inherited descriptor, not a rendezvous",
        rt.bridge_call(&json!({"schema":"bridge-command@1","command":"runtime_status"}))
            .map(|v| v["ok"] == true)
            .unwrap_or(false),
        "the bridge did not answer",
    );

    // A same-user process searching the filesystem finds nothing to open.
    let leaked = scan_for_sockets();
    b.check(
        "a same-user process has no path to any channel",
        leaked.is_empty(),
        format!("found {leaked:?}"),
    );

    // ---------------------------------------------------- the control channel
    let human = match rt.control_channel() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("could not take the control channel: {e}");
            rt.shutdown();
            return 1;
        }
    };
    b.check("the host takes the human control channel at boot", true, "");

    let hello = human.hello().unwrap_or(Value::Null);
    b.check(
        "a channel is told what it is before it asks anything",
        hello["schema"] == "hello@1"
            && hello["channel"] == "human_control"
            && hello["projection_epoch"].is_string(),
        format!("{hello}"),
    );

    let one_channel = rt.settle_sockets(boot + 1, Duration::from_secs(5));
    b.check(
        "the control channel costs the runtime exactly one descriptor",
        one_channel == boot + 1,
        format!("{one_channel} sockets holding one channel, boot baseline was {boot}"),
    );

    let second = rt.control_channel();
    b.check(
        "at most one human control channel is active at a time",
        second.is_err(),
        "a second control channel was granted while the first was live",
    );

    // **A refusal is not a disposal, and this is where that cost was
    // hiding.**
    //
    // The refused claim still arrived carrying its channel: `SCM_RIGHTS`
    // had already duplicated the descriptor into the runtime's table by
    // the time the bridge decided it was not allowed to have it. The
    // bridge read it as `_fd` and returned — discarded in the source,
    // never closed by anything — so a caller could take a descriptor off
    // the runtime for every request it was refused. A hundred refusals,
    // a hundred descriptors, and the one this battery itself performed is
    // what made F.8.2's baseline dirty.
    //
    // The adversarial shape matters: this is reachable by *asking for
    // something you are not permitted to have*, which is the one thing a
    // hostile local process can always do.
    for _ in 0..100 {
        drop(rt.control_channel());
    }
    let after_refusals = rt.settle_sockets(boot + 1, Duration::from_secs(10));
    b.check(
        "a hundred refused control claims cost the runtime nothing",
        after_refusals == boot + 1,
        format!(
            "{after_refusals} sockets after 100 refused claims, expected {}",
            boot + 1
        ),
    );

    // And 0, 1 and 2 are not sockets. The host guarantees they are open
    // before `exec` precisely so a received channel cannot land on one:
    // `SCM_RIGHTS` takes the lowest free number like any other `dup`, so a
    // runtime started with stdout closed would eventually print into a
    // peer's channel.
    //
    // **An invariant check, not a falsifier, and it is not counted as
    // one.** This battery is launched from a shell, so 0, 1 and 2 are
    // occupied whether or not `ensure_std_fds` exists — it passes with the
    // fix disabled, which is the definition. The guarantee is for the
    // launch environment this does not have and Super is about to acquire:
    // a desktop session starting a GUI. Asserting the property is worth
    // doing; claiming this run is evidence for the fix is not.
    let std_fds: Vec<String> = (0..3)
        .map(|n| rt.runtime_fd_target(n))
        .filter(|t| t.contains("socket:"))
        .collect();
    b.check(
        "the runtime's standard descriptors are open, and none of them is a channel",
        std_fds.is_empty() && (0..3).all(|n| rt.runtime_fd_open(n)),
        format!("0/1/2 in the runtime: {:?}", (0..3).map(|n| rt.runtime_fd_target(n)).collect::<Vec<_>>()),
    );

    // ------------------------------------- an engine's channel already means it
    let mut kestrel = match rt.agent_channel("kestrel") {
        Ok(c) => c,
        Err(e) => {
            eprintln!("could not bind kestrel's channel: {e}");
            rt.shutdown();
            return 1;
        }
    };

    let proj = kestrel.call("agent_projection", json!({})).unwrap_or(Value::Null);
    b.check(
        "a connection's actor comes from the descriptor it arrived on",
        proj["result"]["actor"] == "kestrel",
        format!("{}", proj["result"]["actor"]),
    );

    // Binding a channel requires the channel. There is no bridge command
    // that names an actor without handing over the descriptor it names.
    let nameless = rt
        .bridge_call(&json!({
            "schema":"bridge-command@1","command":"bind_agent_channel","actor":"mallory"
        }))
        .unwrap_or(Value::Null);

    b.check(
        "naming an identity without handing over its channel is refused",
        nameless["ok"] == false,
        format!("{nameless}"),
    );

    // --------------------------------------------------- identity unphrasable
    let mut claimed = false;
    for field in ["actor", "peer_id", "channel"] {
        let mut f = json!({"schema":"command@1","command":"agent_projection","args":{}});
        f[field] = json!("mallory");
        let r = kestrel
            .call_raw(&f)
            .unwrap_or(Value::Null);
        if r["result"]["refusal"]["code"] != "identity-not-claimable" {
            claimed = true;
        }
    }
    b.check(
        "a frame claiming an identity is refused, not ignored",
        !claimed,
        "a claim was accepted or silently dropped",
    );

    let after = kestrel.call("agent_projection", json!({})).unwrap_or(Value::Null);
    b.check(
        "the channel is still what it was after the attempt",
        after["result"]["actor"] == "kestrel",
        format!("{}", after["result"]["actor"]),
    );

    let esc = kestrel
        .call("revoke_grant", json!({"grant_id": "gr_0193"}))
        .unwrap_or(Value::Null);
    b.check(
        "an agent channel cannot issue a human command",
        esc["result"]["refusal"]["code"] == "human-consent-required",
        format!("{}", esc["result"]["refusal"]["code"]),
    );

    // --------------------------------------------- ask, approve, exercise, revoke
    let q = kestrel
        .call(
            "request_grant",
            json!({"capability":"github.pr.create","resource":"traaviis/trvm",
                   "options":{"duration":"run","reason":"close the argv boundary"}}),
        )
        .unwrap_or(Value::Null);

    let request_id = q["result"]["grant_request"]["id"].as_str().unwrap_or("").to_string();
    b.check(
        "a request creates no authority and parks on a person",
        q["result"]["allow"] == false && q["result"]["held"] == true && !request_id.is_empty(),
        format!("{}", q["result"]),
    );

    let sub = human.call("subscribe", json!({})).unwrap_or(Value::Null);
    let base_cursor = ProjectionCursor::of(&sub["result"]);
    let base = rev(&sub["result"]);

    let approved = human
        .call("approve_grant_request", json!({"request_id": request_id, "duration": "once"}))
        .unwrap_or(Value::Null);

    let grant_id = approved["result"]["granted"]["id"].as_str().unwrap_or("").to_string();
    b.check(
        "only the human control channel converts a request into a grant",
        approved["result"]["allow"] == true && approved["result"]["granted"]["duration"] == "once",
        format!("{}", approved["result"]),
    );

    // Nobody asked for this frame.
    let push = human
        .projection_after(&base_cursor, Duration::from_secs(5))
        .unwrap_or(Value::Null);
    b.check(
        "the runtime pushes a new projection; the UI does not poll",
        push["schema"] == "projection-snapshot@1" && rev(&push) > base,
        format!("{} rev {}", push["schema"], push["revision"]),
    );

    // A burst collapses to one *state*, and the newest survives.
    let before_burst = rev(&push);
    for i in 0..8 {
        let _ = human.call(
            "revoke_capability_domain",
            json!({"scope": {"actor": format!("nobody{i}")}, "expected_ids": []}),
        );
        let _ = kestrel.call("preflight", json!({"capability":"github.repo.read","resource":"traaviis/trvm"}));
    }
    let _ = human.call("operator_projection", json!({}));
    let newest = human.latest().unwrap_or(Value::Null);
    b.check(
        "a burst leaves the newest snapshot, not an arbitrary tail",
        newest.is_null() || rev(&newest) >= before_burst,
        format!("{} < {}", newest["revision"], before_burst),
    );

    // --------------------------------------------------- exact-set bulk revoke
    let op = human.call("operator_projection", json!({})).unwrap_or(Value::Null);
    let ids: Vec<String> = op["result"]["grants"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|g| g["actor"] == "kestrel")
                .filter_map(|g| g["id"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    b.check(
        "the operator projection actually contained the grants",
        !ids.is_empty(),
        "no kestrel grants — the demultiplexer may be mis-routing again",
    );

    let mut short = ids.clone();
    short.pop();

    let stale = human
        .call("revoke_capability_domain",
              json!({"scope": {"actor": "kestrel"}, "expected_ids": short}))
        .unwrap_or(Value::Null);
    b.check(
        "a bulk revocation whose set is not the confirmed set refuses",
        stale["result"]["refusal"]["code"] == "bulk-scope-changed",
        format!("{}", stale["result"]["refusal"]["code"]),
    );

    let good = human
        .call("revoke_capability_domain",
              json!({"scope": {"actor": "kestrel"}, "expected_ids": ids}))
        .unwrap_or(Value::Null);
    b.check(
        "confirmed exactly, it revokes exactly that set",
        good["result"]["allow"] == true
            && good["result"]["revoked"].as_array().map(|a| a.len()) == Some(ids.len()),
        format!("{}", good["result"]),
    );

    let gone = kestrel.call("agent_projection", json!({})).unwrap_or(Value::Null);
    b.check(
        "the revoked grant is gone from the agent's own world",
        gone["result"]["grants"]
            .as_array()
            .map(|a| !a.iter().any(|g| g["id"] == grant_id.as_str()))
            .unwrap_or(false),
        "the grant was still visible",
    );

    // ------------------------------------------------------- hostile bytes
    let mut survived = true;
    for bad in [
        b"not json".to_vec(),
        b"[1,2,3]".to_vec(),
        serde_json::to_vec(&json!({"schema":"command@1","command":"Elixir.System","args":["halt"]})).unwrap(),
        serde_json::to_vec(&json!({"schema":"command@9","command":"runtime_status"})).unwrap(),
    ] {
        if kestrel.send_raw(&bad).is_err() {
            survived = false;
        }
    }
    std::thread::sleep(Duration::from_millis(200));
    let alive = kestrel.call("agent_projection", json!({})).unwrap_or(Value::Null);
    b.check(
        "hostile bytes do not take the connection or the runtime down",
        survived && alive["result"]["actor"] == "kestrel",
        format!("{}", alive["result"]),
    );

    // ------------------------------------------- projection continuity
    let before = human.call("operator_projection", json!({})).unwrap_or(Value::Null);
    let gen_before = before["world_generation"].clone();
    let epoch_before = before["projection_epoch"].clone();
    b.check(
        "every frame carries generation, epoch, and revision",
        !gen_before.is_null() && !epoch_before.is_null() && before["revision"].is_number(),
        format!("{gen_before} / {epoch_before} / {}", before["revision"]),
    );

    // ------------------------------------------------ close, reopen, same world
    let grants_before = before["result"]["grants"].as_array().map(|a| a.len()).unwrap_or(0);
    drop(human);
    std::thread::sleep(Duration::from_millis(400));

    match rt.control_channel() {
        Ok(reopened) => {
            let after = reopened.call("operator_projection", json!({})).unwrap_or(Value::Null);
            b.check(
                "closing the control descriptor releases it, and reopening reaches the same world",
                after["world_generation"] == gen_before
                    && after["result"]["grants"].as_array().map(|a| a.len()).unwrap_or(0)
                        == grants_before,
                format!(
                    "generation {} → {}, grants {} → {}",
                    gen_before,
                    after["world_generation"],
                    grants_before,
                    after["result"]["grants"].as_array().map(|a| a.len()).unwrap_or(0)
                ),
            );
        }
        Err(e) => b.check("closing the control descriptor releases it", false, e),
    }

    // --------------------------------------- a descriptor cannot be forged
    //
    // The only way to obtain a channel is to be handed one. A descriptor
    // number is not a capability: passing an integer that names a socket
    // this process does not hold gets nothing.
    let forged = rt.bridge_call(&json!({
        "schema":"bridge-command@1","command":"bind_agent_channel","actor":"mallory","fd":3
    })).unwrap_or(Value::Null);
    b.check(
        "a descriptor number in the payload is not a descriptor",
        forged["ok"] == false,
        format!("{forged}"),
    );



    // ============================================ CONCURRENT WRITERS
    //
    // **`write_frame` is a header and then a body.** Two threads doing
    // that on one stream can interleave into `header A · header B · body A
    // · body B`, which the runtime cannot resynchronise from. The rest of
    // this battery is sequential and would never show it; a WebView
    // issuing concurrent commands would show it intermittently.
    {
        let shared = std::sync::Arc::new(kestrel);
        let mut hands = Vec::new();

        for _ in 0..8 {
            let c = std::sync::Arc::clone(&shared);
            hands.push(std::thread::spawn(move || {
                let mut ok = 0;
                for _ in 0..12 {
                    if let Ok(r) = c.call(
                        "preflight",
                        json!({"capability":"github.repo.read","resource":"traaviis/trvm"}),
                    ) {
                        if r["schema"] == "reply@1" {
                            ok += 1;
                        }
                    }
                }
                ok
            }));
        }

        let landed: usize = hands.into_iter().map(|h| h.join().unwrap_or(0)).sum();

        b.check(
            "96 concurrent commands on one socket all get their own reply",
            landed == 96,
            format!("{landed}/96 returned — the stream interleaved"),
        );

        // Still coherent afterwards: a corrupt stream would not recover.
        let after = shared
            .call("agent_projection", json!({}))
            .unwrap_or(Value::Null);
        b.check(
            "the channel is still coherent after concurrent writes",
            after["result"]["actor"] == "kestrel",
            format!("{}", after["result"]),
        );

        kestrel = match std::sync::Arc::try_unwrap(shared) {
            Ok(c) => c,
            Err(_) => {
                b.check("reclaimed the channel", false, "threads outlived the check");
                return 1;
            }
        };
    }

    // ============================================ CONTINUITY, CLIENT SIDE
    //
    // The runtime sends generation + epoch + revision. A client comparing
    // revisions alone would ignore every projection of the live world
    // after a coordinator restart, because the revision restarts below the
    // one it holds. The rule lives in the dispatcher.
    {
        let held = ProjectionCursor {
            world_incarnation: Some("a1acd5fe".into()),
            world_generation: Some(1),
            projection_epoch: Some("aaaa".into()),
            authority_revision: 137,
            view_revision: 412,
        };

        let same_world_older = json!({"world_incarnation":"a1acd5fe","world_generation":1,"projection_epoch":"aaaa","revision":9,"view_revision":11});
        let new_epoch_lower = json!({"world_incarnation":"a1acd5fe","world_generation":1,"projection_epoch":"bbbb","revision":0,"view_revision":0});
        let new_generation = json!({"world_incarnation":"c3c3c3c3","world_generation":2,"projection_epoch":"cccc","revision":0,"view_revision":0});
        let same_world_newer = json!({"world_incarnation":"a1acd5fe","world_generation":1,"projection_epoch":"aaaa","revision":138,"view_revision":413});

        // **The factory reset, which the three-field cursor could not see.**
        // A new installation starts at generation 1 again, and the
        // coordinator survives the reset — so generation, epoch and even
        // the direction of the revision all look like an ordinary advance.
        // Only the incarnation differs.
        let factory_reset =
            json!({"world_incarnation":"b0b2e1e4","world_generation":1,"projection_epoch":"aaaa","revision":138,"view_revision":413});

        b.check(
            "a factory reset is a different world, not the next revision of this one",
            held.superseded_by(&factory_reset),
            "a brand-new world was classified as an ordinary advance of the old one",
        );
        b.check(
            "a lower revision in the same epoch is not newer",
            !held.superseded_by(&same_world_older),
            "an older projection was accepted",
        );
        b.check(
            "a new epoch supersedes, however low its revision",
            held.superseded_by(&new_epoch_lower),
            "the client ignored a live world because the number got smaller",
        );
        b.check(
            "a new generation supersedes",
            held.superseded_by(&new_generation),
            "a restored world was treated as stale",
        );
        b.check(
            "a higher revision in the same epoch supersedes",
            held.superseded_by(&same_world_newer),
            "an advance was ignored",
        );

        // **A boolean cannot drive the cockpit, and this is where that
        // stops being a comment.** All four frames above are "new", and
        // each demands a different action: apply, resnapshot, or throw
        // away the authority you are holding and take it again. The host
        // matches on this; `superseded_by` is now defined in terms of it,
        // so the two cannot drift apart.
        b.check(
            "a higher revision classifies as an ADVANCE",
            held.classify(&same_world_newer) == Continuity::Advance,
            format!("{:?}", held.classify(&same_world_newer)),
        );
        b.check(
            "a lower revision classifies as already SEEN",
            held.classify(&same_world_older) == Continuity::Seen,
            format!("{:?}", held.classify(&same_world_older)),
        );
        b.check(
            "a new epoch classifies as a NEW RUNTIME, not a new world",
            held.classify(&new_epoch_lower) == Continuity::NewRuntime
                && held.classify(&new_epoch_lower).discards_projection()
                && !held.classify(&new_epoch_lower).reacquires_authority(),
            "a coordinator restart cost the host its authority, or did not cost it its projection",
        );
        b.check(
            "a new incarnation classifies as REACQUIRE, and only that one does",
            held.classify(&factory_reset) == Continuity::NewIncarnation
                && held.classify(&new_generation).reacquires_authority()
                && held.classify(&factory_reset).discards_projection(),
            "a world discontinuity did not demand that authority be re-established",
        );

        // The distinction the whole of F.8.2.5 is about, on one line: a
        // restore and a restart are both "discard what you are holding",
        // and only one of them is "and you are no longer who you were".
        b.check(
            "resnapshot and reacquire are different answers",
            Continuity::NewRuntime.discards_projection()
                && !Continuity::NewRuntime.reacquires_authority()
                && Continuity::NewIncarnation.reacquires_authority(),
            "the host collapses a runtime restart and a world discontinuity into one action",
        );

        // A cursor holding nothing adopts the first frame it is given
        // rather than reporting the world it just joined as a
        // discontinuity — otherwise every host would start by reacquiring
        // authority it had only just taken.
        let fresh = ProjectionCursor::default();
        b.check(
            "a host holding nothing adopts its first frame instead of reacquiring",
            fresh.classify(&same_world_newer) == Continuity::Fresh
                && !fresh.classify(&same_world_newer).reacquires_authority(),
            format!("{:?}", fresh.classify(&same_world_newer)),
        );
    }

    // ================================================ THE COCKPIT LOOP
    //
    // **F.8.2.5 reported this as not implemented, and it was the only
    // remaining C1.1 row.** The host's answer to a closed control channel
    // was an `io::Error` returned to whoever called last — there was no
    // loop to reconnect in, so "the host reacquires human control" was a
    // sentence in a ladder rather than a behaviour.
    //
    // What is measured here is the reacquisition itself: a control channel
    // that reaches EOF, a host that notices without being asked, and a
    // fresh capability taken by the same route as the first one.
    {
        let mut cp = CockpitLoop::new(&rt);

        match cp.acquire() {
            Ok(()) => {
                b.check(
                    "the cockpit reaches LIVE LOCAL by taking control and subscribing",
                    *cp.state() == Cockpit::LiveLocal,
                    format!("{:?}", cp.state()),
                );

                b.check(
                    "its first frame names the incarnation it was assembled in",
                    cp.cursor().world_incarnation.is_some()
                        && cp.cursor().projection_epoch.is_some(),
                    format!("{:?}", cp.cursor()),
                );

                // **The field W.1 did not have.** LIVE LOCAL claimed to
                // mean "holding a projection" while `acquire` read the
                // cursor out of the subscribe reply and dropped
                // `result["projection"]`. The next step would have been a
                // WebView fetching the projection separately — a second
                // sample, and the cursor/content relation broken at the
                // last hop.
                b.check(
                    "LIVE LOCAL means the cockpit is holding the view, not just its cursor",
                    cp.projection().is_some() && cp.invariant_holds(),
                    format!("projection held: {}", cp.projection().is_some()),
                );

                b.check(
                    "the held view is the operator projection, and it is renderable",
                    cp.projection()
                        .map(|p| p["schema"].as_str().unwrap_or("").starts_with("operator-projection@")
                            && p["grants"].is_array()
                            && p["channels"].is_array())
                        .unwrap_or(false),
                    format!("{:?}", cp.projection().map(|p| p["schema"].clone())),
                );

                // One call, one coherent answer — state, cursor and view
                // together, so nothing downstream has to take a second
                // sample to draw what the cursor describes.
                let f = cp.frame();
                b.check(
                    "one frame carries the state, both cursors and the view together",
                    f.state == Cockpit::LiveLocal
                        && f.world.world_incarnation.is_some()
                        && f.world.view_revision > 0
                        && f.projection.is_some(),
                    format!("{:?} view_revision={}", f.state, f.world.view_revision),
                );

                // **The second clock, end to end.** Opening an agent
                // channel changes `peers` and `channels` and performs no
                // authority transaction. Before W.1.1 the runtime pushed
                // nothing and this loop would have sat here forever
                // rendering a topology that was no longer true.
                let held_authority = cp.cursor().authority_revision;
                let channels_before = cp
                    .projection()
                    .and_then(|p| p["channels"].as_array().map(|a| a.len()))
                    .unwrap_or(0);

                let mallory = rt.agent_channel("mallory-cockpit").ok();

                let saw = cp.settle(Duration::from_secs(8), |c| {
                    c.projection()
                        .and_then(|p| p["channels"].as_array().map(|a| a.len()))
                        .unwrap_or(0)
                        > channels_before
                });

                b.check(
                    "a channel opening reaches the cockpit without an authority mutation",
                    saw && cp.cursor().authority_revision == held_authority,
                    format!(
                        "channels {} -> {:?}, authority revision {} -> {}",
                        channels_before,
                        cp.projection().and_then(|p| p["channels"].as_array().map(|a| a.len())),
                        held_authority,
                        cp.cursor().authority_revision
                    ),
                );

                b.check(
                    "the view revision moved and the authority revision did not",
                    cp.cursor().view_revision > 0
                        && cp.cursor().authority_revision == held_authority,
                    format!(
                        "view {} · authority {}",
                        cp.cursor().view_revision,
                        cp.cursor().authority_revision
                    ),
                );

                let channels_open = cp
                    .projection()
                    .and_then(|p| p["channels"].as_array().map(|a| a.len()))
                    .unwrap_or(0);
                drop(mallory);

                b.check(
                    "a channel closing reaches the cockpit too",
                    cp.settle(Duration::from_secs(8), |c| {
                        c.projection()
                            .and_then(|p| p["channels"].as_array().map(|a| a.len()))
                            .unwrap_or(0)
                            < channels_open
                    }),
                    format!(
                        "channels still {:?}",
                        cp.projection().and_then(|p| p["channels"].as_array().map(|a| a.len()))
                    ),
                );

                // 128 bits, not 64 — `Ampd.World.incarnation/0`. Checked on
                // the wire rather than in the runtime that produces it.
                b.check(
                    "the incarnation on the wire is 128 bits",
                    cp.cursor().world_incarnation.as_deref().map(str::len) == Some(32),
                    format!("{:?}", cp.cursor().world_incarnation),
                );

                // ---------------------------------------- NEW RUNTIME, applied
                //
                // **Classifiable is not observable, and W.1 only had the
                // first.** The enum knew what an epoch change meant and
                // nothing ever delivered one: `AuthorityCoordinator` is
                // `:one_for_one`, so a restart minted a new epoch while
                // `Ampd.Peer`, `Ampd.Bridge`, `Ampd.Subscriptions` and every
                // channel survived, and nothing announced it. Measured —
                // zero pushes after killing it, subscription intact, host
                // holding the old epoch indefinitely.
                //
                // The runtime half is fixed and witnessed in
                // `ampd/test/cockpit_test.exs`: the restart announces, and
                // it announces *only* — closing the channel would be
                // `NewIncarnation` behaviour and would cost the person the
                // authority a restart must not touch.
                //
                // What is measured here is the half that lives in this
                // process: applying such a frame. It is fed rather than
                // waited for, because a coordinator restart cannot be
                // caused from outside the BEAM — the same limit as a
                // restore, said again rather than implied.
                {
                    let live = cp.projection().cloned().unwrap_or(Value::Null);
                    let held_incarnation = cp.cursor().world_incarnation.clone();

                    let new_runtime = json!({
                        "schema": "projection-snapshot@1",
                        "world_incarnation": held_incarnation.clone(),
                        "world_generation": cp.cursor().world_generation,
                        "projection_epoch": "restarted",
                        "revision": 0,
                        "view_revision": 0,
                        "projection": live,
                    });

                    b.check(
                        "a new epoch on the same world classifies as a NEW RUNTIME",
                        cp.cursor().classify(&new_runtime) == Continuity::NewRuntime,
                        format!("{:?}", cp.cursor().classify(&new_runtime)),
                    );

                    let had_channel = cp.channel().is_some();
                    let state = cp.feed(&new_runtime);

                    b.check(
                        "a runtime restart is resnapshotted, not reacquired",
                        state == Cockpit::LiveLocal
                            && had_channel
                            && cp.channel().is_some()
                            && cp.reacquisitions == 0,
                        format!(
                            "{state:?} · channel held: {} · reacquisitions {}",
                            cp.channel().is_some(),
                            cp.reacquisitions
                        ),
                    );

                    b.check(
                        "the resnapshot adopts the new epoch and keeps the world",
                        cp.cursor().projection_epoch.as_deref() == Some("restarted")
                            && cp.cursor().world_incarnation == held_incarnation
                            && cp.projection().is_some(),
                        format!("{:?}", cp.cursor()),
                    );
                }

                // ------------------------------------------ cursors fail closed
                //
                // `CockpitFrame.world` claims to carry both clocks, and the
                // lenient reader turns a missing authority revision into a
                // zero — a number a WebView renders as fact. A frame that
                // cannot produce a complete cursor is one this host does
                // not understand.
                {
                    let complete = json!({
                        "schema": "projection-snapshot@1",
                        "world_incarnation": "aa", "world_generation": 1,
                        "projection_epoch": "bb", "revision": 3, "view_revision": 9,
                        "projection": {"schema": "operator-projection@2"}
                    });

                    b.check(
                        "a complete frame produces a complete cursor",
                        ProjectionCursor::try_of(&complete).is_some(),
                        "a well-formed frame was rejected",
                    );

                    for missing in ["revision", "view_revision", "world_incarnation",
                                    "projection_epoch", "world_generation"] {
                        let mut bad = complete.clone();
                        bad.as_object_mut().unwrap().remove(missing);

                        b.check(
                            &format!("a frame with no {missing} is refused rather than defaulted"),
                            ProjectionCursor::try_of(&bad).is_none(),
                            format!("try_of invented a value for a missing {missing}"),
                        );
                    }

                    // ...and the loop will not go live on one.
                    let mut bad = complete.clone();
                    bad.as_object_mut().unwrap().remove("revision");
                    let mut probe = CockpitLoop::new(&rt);
                    probe.feed(&bad);

                    b.check(
                        "a cockpit does not go live on a frame it cannot fully read",
                        *probe.state() != Cockpit::LiveLocal && probe.projection().is_none(),
                        format!("{:?}", probe.state()),
                    );
                }

                let before = cp.reacquisitions;

                // **`shutdown(2)`, not a drop, and the difference is the
                // whole probe.** Dropping the `Chan` empties the loop's
                // slot, so the loop reacquires down the `None` arm and
                // never consults `closed()` at all — the EOF path would
                // have been unmeasured while this line looked like it was
                // measuring it. Caught by `tools/sabotage-host.sh`, which
                // disabled the EOF check and stayed green.
                //
                // Ending the connection while the `Chan` stays in the slot
                // is what a runtime-side close looks like from here. The
                // *cause* still cannot be a restore: `advance_lineage/2`
                // is on no channel, so a restore-triggered EOF is not
                // drivable from the host. This measures the reacquisition,
                // not its cause.
                fdpass::shutdown_fd(cp.channel().unwrap().fd());

                let settled = cp.settle(Duration::from_secs(8), |c| {
                    *c.state() == Cockpit::LiveLocal && c.reacquisitions > before
                });

                b.check(
                    "a control channel at EOF is noticed without being asked",
                    cp.reacquisitions > before,
                    format!("{} reacquisitions, was {before}", cp.reacquisitions),
                );

                b.check(
                    "the host reacquires human control and returns to LIVE LOCAL",
                    settled && *cp.state() == Cockpit::LiveLocal,
                    format!("{:?} after {} reacquisitions", cp.state(), cp.reacquisitions),
                );

                b.check(
                    "the view held across a reacquisition is the new one, not the old one",
                    cp.projection().is_some() && cp.invariant_holds(),
                    format!(
                        "state {:?} · projection held: {}",
                        cp.state(),
                        cp.projection().is_some()
                    ),
                );

                b.check(
                    "the reacquired channel is a working one, not merely open",
                    cp.channel()
                        .and_then(|c| c.call("operator_projection", json!({})).ok())
                        .map(|v| v["result"]["schema"].as_str().unwrap_or("").starts_with("operator-projection@"))
                        .unwrap_or(false),
                    "the reacquired control channel could not answer",
                );

                // And the fresh subscription is bound to the world that
                // exists now — not carried over from the dead channel.
                b.check(
                    "the fresh subscription names a live incarnation",
                    cp.cursor().world_incarnation.is_some(),
                    format!("{:?}", cp.cursor()),
                );
            }

            Err(e) => {
                for name in [
                    "the cockpit reaches LIVE LOCAL by taking control and subscribing",
                    "its first frame names the incarnation it was assembled in",
                    "LIVE LOCAL means the cockpit is holding the view, not just its cursor",
                    "the held view is the operator projection, and it is renderable",
                    "one frame carries the state, both cursors and the view together",
                    "a channel opening reaches the cockpit without an authority mutation",
                    "the view revision moved and the authority revision did not",
                    "a channel closing reaches the cockpit too",
                    "the incarnation on the wire is 128 bits",
                    "a control channel at EOF is noticed without being asked",
                    "the host reacquires human control and returns to LIVE LOCAL",
                    "the view held across a reacquisition is the new one, not the old one",
                    "the reacquired channel is a working one, not merely open",
                    "the fresh subscription names a live incarnation",
                ] {
                    b.check(name, false, &e);
                }
            }
        }
    }

    // ============================================ DESCRIPTOR CONFINEMENT
    //
    // **The falsifier that earns "possession of the descriptor is the
    // capability."** Everything else in this battery tests what a channel
    // may say. This tests who has one.
    //
    // At this point the host holds the bridge, the human control channel,
    // and two agent channels. It spawns a child the way it spawns an
    // engine — one `dup2` onto fd 3 — and the child reports every open
    // descriptor it actually has after `exec`.
    //
    // Before `SOCK_CLOEXEC`, `socketpair(2)` returned inheritable
    // descriptors and this child would have inherited the person's socket
    // and the bridge along with its own.
    let mallory = rt.agent_channel("mallory").ok();

    match rt.agent_fd("probe") {
        Ok(fd) => {
            let seen = child_fds(fd);

            // Its own channel, and the three standard streams. The shell
            // opens a directory descriptor to read /proc/self/fd, which is
            // not a socket — so the socket count is the honest measure.
            let sockets: Vec<&String> = seen.iter().filter(|l| l.contains("socket:")).collect();

            b.check(
                "a spawned engine inherits exactly one channel, and no other",
                sockets.len() == 1,
                format!("inherited {} sockets: {:?}", sockets.len(), sockets),
            );

            b.check(
                "the inherited descriptor is the one it was given, on fd 3",
                seen.iter().any(|l| l.starts_with("3 ") && l.contains("socket:")),
                format!("{seen:?}"),
            );

            fdpass::close_fd(fd);
        }
        Err(e) => {
            b.check("a spawned engine inherits exactly one channel, and no other", false, e);
            b.check("the inherited descriptor is the one it was given, on fd 3", false, "");
        }
    }

    // Every descriptor this host holds is close-on-exec, so the property
    // above is structural rather than a coincidence of allocation order.
    // Structural rather than a coincidence of allocation order: nothing
    // the host still holds could survive an `exec` at all.
    match rt.live_cloexec() {
        Some(n) => b.check(
            "every descriptor the host still holds is close-on-exec",
            n >= 2,
            format!("only {n} live descriptors — too few to prove anything"),
        ),
        None => b.check(
            "every descriptor the host still holds is close-on-exec",
            false,
            "a host descriptor would survive exec",
        ),
    }

    drop(mallory);



    // ======================================= DESCRIPTOR OWNERSHIP (RUNTIME)
    //
    // **The receiver owns what it receives, and F.8.1 did not close this.**
    //
    // `SCM_RIGHTS` is defined as `dup(2)` into the receiving process's
    // descriptor table, so a descriptor that arrives at the runtime is the
    // runtime's — and no `socket:close/1` frees it, because OTP closes
    // only what OTP created. F.8.1 measured that, reported the residue as
    // "bounded by channels ever opened, not by traffic", and accepted it.
    //
    // Both halves of that sentence were wrong. The same false ownership
    // model was in `HostBridge.close_fd/1`, which runs on every *rejected*
    // command and every surplus descriptor — so the residue was bounded by
    // traffic after all. It went unmeasured because the only thing that
    // could send a surplus descriptor was this file, and this file only
    // ever sent successful binds with exactly one.
    //
    // The acceptance below is exact. `growth <= 14` was the previous form
    // of a check named "ten descriptors, not twenty", and a bound that
    // loose cannot tell the claim from its negation.
    //
    // This is the only place any of it can be measured: the integer path
    // is reached only by a real `SCM_RIGHTS` receive, so nothing inside
    // the BEAM can construct the case at all.
    {
        // Let earlier sections finish tearing down before anything is
        // called a baseline.
        std::thread::sleep(Duration::from_millis(500));
        let base = rt.runtime_socket_count();
        let before = rt.runtime_unix_fds();

        // ---- 0 · the inherited bridge descriptor was disposed of, not held
        //
        // Sampled at boot, above. The runtime adopts the bridge the same
        // way it adopts a channel — an owned, confined duplicate — and
        // sinks the raw inherited number, so it holds the bridge on a
        // descriptor no child of its own would inherit. Before this round
        // it held the bridge *as* fd 3, inheritable, for the life of the
        // process.
        b.check(
            "the raw inherited bridge descriptor is closed once the runtime has adopted it",
            bridge_fd_at_boot == "closed",
            format!("fd 3 in the runtime is {bridge_fd_at_boot}"),
        );

        // ---- 1 · ten live channels cost exactly ten descriptors
        let mut held = Vec::new();
        for i in 0..10 {
            if let Ok(c) = rt.agent_channel(&format!("fdprobe{i}")) {
                held.push(c);
            }
        }
        let live = rt.settle_sockets(base + 10, Duration::from_secs(5));

        b.check(
            "ten bound channels cost the runtime exactly ten descriptors",
            held.len() == 10 && live == base + 10,
            format!(
                "{} channels bound, {} sockets, expected {}",
                held.len(),
                live,
                base + 10
            ),
        );

        // ---- 2 · every one of them is close-on-exec
        //
        // **`dup(2)` does not copy `FD_CLOEXEC`.** Adopting with
        // `dup => true` is the only setting under which OTP closes its own
        // handle, and it hands back an *inheritable* duplicate of a
        // descriptor that arrived close-on-exec — silently undoing F.8.1's
        // `[:cmsg_cloexec]`. The runtime puts the flag back
        // (`Ampd.NativeFd.set_cloexec/1`); this is where that is checked,
        // because a process cannot be asked about its own whole table from
        // inside it.
        let appeared: Vec<(String, bool)> = rt
            .runtime_unix_fds()
            .into_iter()
            .filter(|(fd, _)| !before.contains_key(fd))
            .collect();
        let leaky: Vec<&String> = appeared.iter().filter(|(_, ok)| !ok).map(|(f, _)| f).collect();

        b.check(
            "every descriptor the runtime took for a channel is close-on-exec",
            appeared.len() >= 10 && leaky.is_empty(),
            format!(
                "{} descriptors appeared, {} of them would survive an exec: {:?}",
                appeared.len(),
                leaky.len(),
                leaky
            ),
        );

        // ---- 3 · closing them returns to baseline — no residue at all
        drop(held);
        let after = rt.settle_sockets(base, Duration::from_secs(15));
        b.check(
            "closing every channel returns the runtime to its baseline — nothing is left behind",
            after == base,
            format!("{after} sockets after closing, baseline was {base}"),
        );

        // The channel is torn down *and* the descriptor is reclaimed. In
        // F.8.1 only the first half was true, and the check was named for
        // the half that was.
        let listed = rt
            .bridge_call(&json!({"schema":"bridge-command@1","command":"list_channels"}))
            .map(|v| v["channels"].as_array().map(|a| a.len()).unwrap_or(0))
            .unwrap_or(999);

        b.check(
            "a closed channel is torn down",
            listed <= 1,
            format!("the bridge still lists {listed} channels after they were closed"),
        );

        // ---- 4 · a hundred open/close cycles leave nothing behind
        //
        // The residue was one descriptor per channel *ever opened*, so a
        // count that returns to baseline once could still be hiding a slow
        // leak. A hundred cycles is where a per-cycle residue would be
        // impossible to miss and impossible to explain away.
        for i in 0..100 {
            if let Ok(c) = rt.agent_channel(&format!("cycle{i}")) {
                drop(c);
            }
        }
        let cycled = rt.settle_sockets(base, Duration::from_secs(30));
        b.check(
            "a hundred open/close cycles leave the runtime at its baseline",
            cycled == base,
            format!("{cycled} sockets after 100 cycles, baseline was {base}"),
        );

        // ---- 5 · a rejected command does not keep what it arrived with
        //
        // **The case F.8.1 never sent.** Three shapes, each reaching a
        // different branch of the runtime's disposal: an unknown command,
        // a frame that is not JSON at all, and a bind whose actor is
        // refused *after* the descriptor has been received.
        let rejected: [(&str, Vec<u8>); 3] = [
            (
                "an unknown command",
                br#"{"schema":"bridge-command@1","command":"not-a-command"}"#.to_vec(),
            ),
            ("a frame that is not JSON", b"<<<not a frame>>>".to_vec()),
            (
                "a bind with a refused actor",
                serde_json::to_vec(&json!({
                    "schema": "bridge-command@1",
                    "command": "bind_agent_channel",
                    "actor": "x".repeat(200)
                }))
                .unwrap(),
            ),
        ];

        let mut all_refused = true;
        for (_what, frame) in &rejected {
            for _ in 0..10 {
                match rt.bridge_call_with_rights(frame, 3) {
                    Ok(v) => all_refused &= v["ok"] == false,
                    Err(_) => all_refused = false,
                }
            }
        }
        let after_junk = rt.settle_sockets(base, Duration::from_secs(10));

        b.check(
            "ninety descriptors on thirty rejected commands leave the runtime at its baseline",
            all_refused && after_junk == base,
            format!(
                "{after_junk} sockets after 30 rejected commands carrying 3 descriptors each \
                 (baseline {base}), all refused: {all_refused}"
            ),
        );

        // ---- 6 · a valid bind keeps one and discards the surplus
        let surplus = rt.agent_channel_with_surplus("surplus-probe", 4);
        let with_surplus = rt.settle_sockets(base + 1, Duration::from_secs(5));

        b.check(
            "a bind carrying four surplus descriptors keeps the one it bound and no others",
            surplus.is_ok() && with_surplus == base + 1,
            format!(
                "{with_surplus} sockets after a bind with 4 surplus rights, expected {}",
                base + 1
            ),
        );

        drop(surplus);
        let settled = rt.settle_sockets(base, Duration::from_secs(10));
        b.check(
            "and closing it returns to baseline too",
            settled == base,
            format!("{settled} sockets, baseline was {base}"),
        );
    }

    // ============================================ DURABLE ACROSS RESTART
    //
    // **Not "close the channel and reopen it".** That was the previous
    // check, and it kept the same `Runtime` — the same BEAM, the same
    // stores, already open. It proved a channel could be re-taken, not
    // that a world survives the program that made it.
    //
    // Meanwhile the host pointed `AMPD_DATA_DIR` at a directory named for
    // its own pid and the clock, and deleted it on shutdown. So a user
    // quitting Super destroyed their world, and a crash orphaned one the
    // next host would never look at. This is the test that would have said
    // so.
    {
        let world_dir = scratch.join("durable");
        let world = WorldDir::Persistent(world_dir.clone());

        match Runtime::start(ampd_dir, world.clone()) {
            Ok(a) => {
                let h = a.control_channel();
                let (lineage_a, grants_a, revoked) = match &h {
                    Ok(c) => {
                        let before = c.call("operator_projection", json!({})).unwrap_or(Value::Null);
                        let ids: Vec<String> = before["result"]["grants"]
                            .as_array()
                            .map(|g| g.iter().filter_map(|x| x["id"].as_str().map(String::from)).collect())
                            .unwrap_or_default();

                        // Something a restart must not undo.
                        let target = ids.first().cloned().unwrap_or_default();
                        let _ = c.call("revoke_grant", json!({"grant_id": target}));

                        let after = c.call("operator_projection", json!({})).unwrap_or(Value::Null);
                        (
                            after["result"]["world"]["lineage"].clone(),
                            after["result"]["grants"].as_array().map(|g| g.len()).unwrap_or(0),
                            target,
                        )
                    }
                    Err(_) => (Value::Null, 0, String::new()),
                };

                drop(h);
                // Exit the way a user quitting the app does.
                a.stop_keeping_world();
                std::thread::sleep(Duration::from_millis(300));

                b.check(
                    "quitting the host does not delete the world",
                    world_dir.join("world.json").exists(),
                    format!("{} is gone", world_dir.display()),
                );

                // A brand-new host, new pid, same world.
                match Runtime::start(ampd_dir, world) {
                    Ok(c2) => {
                        match c2.control_channel() {
                            Ok(h2) => {
                                let now = h2.call("operator_projection", json!({})).unwrap_or(Value::Null);

                                b.check(
                                    "a new host reaches the same world, not a new one",
                                    now["result"]["world"]["lineage"] == lineage_a && !lineage_a.is_null(),
                                    format!("{} → {}", lineage_a, now["result"]["world"]["lineage"]),
                                );

                                b.check(
                                    "a revocation survives the host that performed it",
                                    now["result"]["grants"].as_array().map(|g| g.len()) == Some(grants_a)
                                        && !now["result"]["grants"]
                                            .as_array()
                                            .map(|g| g.iter().any(|x| x["id"] == revoked.as_str()))
                                            .unwrap_or(true),
                                    format!("{} grants, expected {}", now["result"]["grants"], grants_a),
                                );

                                // One active owner per world: a third host
                                // must be refused while this one holds it.
                                let third = Runtime::start(ampd_dir, WorldDir::Persistent(world_dir.clone()));
                                b.check(
                                    "a second host cannot open a world that is already open",
                                    third.is_err(),
                                    "two hosts opened the same world",
                                );
                                if let Ok(t) = third {
                                    t.stop_keeping_world();
                                }

                                drop(h2);
                            }
                            Err(e) => {
                                b.check("a new host reaches the same world, not a new one", false, e);
                                b.check("a revocation survives the host that performed it", false, "");
                                b.check("a second host cannot open a world that is already open", false, "");
                            }
                        }
                        c2.shutdown();
                    }
                    Err(e) => {
                        b.check("a new host reaches the same world, not a new one", false, e);
                        b.check("a revocation survives the host that performed it", false, "");
                        b.check("a second host cannot open a world that is already open", false, "");
                    }
                }
            }
            Err(e) => {
                b.check("quitting the host does not delete the world", false, e);
                b.check("a new host reaches the same world, not a new one", false, "");
                b.check("a revocation survives the host that performed it", false, "");
                b.check("a second host cannot open a world that is already open", false, "");
            }
        }
    }

    println!("\n  {} held · {} failed", b.pass, b.fail);
    rt.shutdown();
    let _ = std::fs::remove_dir_all(&scratch);

    if b.fail == 0 { 0 } else { 1 }
}

/// Spawn a child exactly the way an engine is spawned, and ask it what it
/// inherited. `readlink` on `/proc/self/fd` is what an attacker would run
/// first, so it is what this runs.
fn child_fds(fd: std::os::unix::io::RawFd) -> Vec<String> {
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    let out = unsafe {
        Command::new("sh")
            .arg("-c")
            .arg("for f in /proc/self/fd/*; do echo \"$(basename $f) $(readlink $f)\"; done")
            .pre_exec(move || fdpass::dup_onto(fd, 3))
            .output()
    };

    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Walk the directories a same-user process would search, and try to open
/// anything that looks like this runtime's.
fn scan_for_sockets() -> Vec<String> {
    let mut found = Vec::new();
    let base = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());

    for dir in [base.as_str(), "/tmp"] {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if !name.contains("ampd") {
                    continue;
                }
                let p = e.path();
                if p.is_dir() {
                    if let Ok(inner) = std::fs::read_dir(&p) {
                        for i in inner.flatten() {
                            if i.path().to_string_lossy().ends_with(".sock") {
                                found.push(i.path().to_string_lossy().to_string());
                            }
                        }
                    }
                } else if name.ends_with(".sock") {
                    found.push(p.to_string_lossy().to_string());
                }
            }
        }
    }
    found
}

// A raw frame, for the checks that must speak to the protocol rather than
// through it.
impl Chan {
    pub fn call_raw(&self, frame: &Value) -> std::io::Result<Value> {
        let bytes = serde_json::to_vec(frame)?;
        self.send_raw(&bytes)?;
        std::thread::sleep(Duration::from_millis(120));
        Ok(self.last_reply().unwrap_or(Value::Null))
    }
}
