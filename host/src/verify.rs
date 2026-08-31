//! The C1.1 acceptance battery, driven from a separate OS process.
//!
//! Everything before C1.1 proved the semantics of a command issued against
//! a peer handle inside one BEAM. This proves that a *descriptor* can only
//! ever produce the commands its identity is allowed to produce, and that
//! nothing which was not handed a descriptor can produce any.

use std::path::{Path, PathBuf};
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
    // **The proposition, restated after it was found to be the wrong one.**
    //
    // This asked whether `readlink(/proc/<pid>/fd/N)` contained `socket:`
    // and called any socket a channel. Sockets are perfectly valid stdio:
    // `execFileSync` supplies stdout and stderr as socketpairs, so the same
    // commit gave 87/0 from a shell and 86/1 through the bundle generator —
    // a gate whose answer depended on who launched it.
    //
    // The real invariant is not "stdio is not a socket". It is:
    //
    //     fd 0/1/2 must not be a descriptor this host handed the runtime
    //     as a privileged Super channel
    //
    // which is a question about *provenance*, answered structurally by
    // socket inode. `SCM_RIGHTS` and `dup2` share the open file
    // description, so the inode the host reads before giving an endpoint
    // away is the inode the runtime shows for its adopted copy.
    let std_channels: Vec<String> = (0..3)
        .map(|n| rt.runtime_fd_target(n))
        .filter(|t| rt.is_adopted_channel(t))
        .collect();

    b.check(
        "the runtime's standard descriptors are open, and none of them is a channel",
        std_channels.is_empty() && (0..3).all(|n| rt.runtime_fd_open(n)),
        format!(
            "0/1/2 in the runtime: {:?} · adopted channel inodes: {:?}",
            (0..3).map(|n| rt.runtime_fd_target(n)).collect::<Vec<_>>(),
            rt.adopted_channel_inodes()
        ),
    );

    // **And the classifier is falsified in both directions**, because a
    // predicate that answered `false` for everything would also have made
    // the check above pass.
    {
        let adopted = rt.adopted_channel_inodes();

        b.check(
            "the host knows which descriptors it handed the runtime",
            !adopted.is_empty(),
            "no adopted channel inode was recorded — the classifier has nothing to compare against",
        );

        // A real adopted channel IS recognised. This is the direction that
        // matters: if an actual channel landed on fd 0/1/2 the gate must go
        // red, and this proves the predicate would say so.
        let a_channel = format!("socket:[{}]", adopted.first().copied().unwrap_or(0));
        b.check(
            "an adopted channel on a standard descriptor would be caught",
            rt.is_adopted_channel(&a_channel),
            format!("the predicate did not recognise {a_channel}"),
        );

        // A socket the launcher supplied is NOT a channel — the exact case
        // that produced the false failure. Built from an inode this host
        // never gave away.
        let unrelated = crate::fdpass::pair_stream().ok();
        let stdio_like = unrelated
            .as_ref()
            .and_then(|crate::fdpass::Pair(a, _)| {
                std::fs::read_link(format!("/proc/self/fd/{a}")).ok()
            })
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();

        b.check(
            "a socket this host never handed over is not a channel",
            !stdio_like.is_empty() && !rt.is_adopted_channel(&stdio_like),
            format!("{stdio_like} was misclassified as a Super channel"),
        );

        if let Some(crate::fdpass::Pair(a, bfd)) = unrelated {
            crate::fdpass::close_fd(a);
            crate::fdpass::close_fd(bfd);
        }

        // And the launcher genuinely varies: report what this run's own
        // stdio is, so a green result from socket-backed stdio is legible
        // as such rather than assumed.
        let own = std::fs::read_link("/proc/self/fd/1")
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        b.check(
            "this gate is independent of how the verifier itself was launched",
            !rt.is_adopted_channel(&own),
            format!("the verifier's own stdout {own} was classified as a Super channel"),
        );
    }

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

    // ================================ D.1.3a · THE PRODUCTION EFFECT CHANNEL
    //
    // **The proof the harness could not give.** `ampd`'s own falsifiers
    // drive a socketpair whose far end is an Elixir test process; that is a
    // real socket and a real framing, and it is not this program. Here the
    // host creates the pair, passes the descriptor over the bridge it was
    // born holding, serves the request out of `effect::perform`, and a real
    // `git worktree add` happens — with no pathname resolved anywhere on
    // the production path.
    {
        let repo = scratch.join("d13a-repo");
        let _ = std::fs::create_dir_all(&repo);
        let git_ok = init_fixture_repo(&repo);

        let effect_fd = rt.effect_channel();
        let served = effect_fd.is_ok();

        if let Ok(fd) = effect_fd {
            std::thread::spawn(move || crate::serve_effects(fd));
        }

        b.check(
            "the host creates the effect channel and passes it over the bridge",
            served,
            format!("{:?}", effect_fd.as_ref().err()),
        );

        // **And the Carrier lifecycle channel, which this battery did not
        // bind and therefore could not have exercised.**
        //
        // `run_host` binds it; `verify` did not, so the production World-join
        // check below returned `carrier-start-indeterminate` — "no host
        // carrier channel is possessed" — the first time it ran. That is the
        // correct refusal and it is also the proof that the join was untested:
        // a gate that never binds the channel it needs is a gate measuring its
        // own setup.
        let carrier_root = scratch.join("carrier-machine");
        let _ = std::fs::create_dir_all(&carrier_root);
        let carrier_fd = rt.carrier_channel();
        let carrier_served = carrier_fd.is_ok();

        if let Ok(fd) = carrier_fd {
            std::thread::spawn(move || crate::serve_carrier(fd, carrier_root));
        }

        b.check(
            "the host creates the Carrier lifecycle channel and passes it over the bridge",
            carrier_served,
            format!("{:?}", carrier_fd.as_ref().err()),
        );

        // The runtime learned what performs its effects from the endpoint
        // that will perform them, not from a second pathname lookup.
        let status = rt
            .bridge_call(&json!({"schema":"bridge-command@1","command":"runtime_status"}))
            .unwrap_or(Value::Null);
        b.check(
            "the runtime still answers with the effect channel bound",
            status["ok"] == true,
            format!("{status}"),
        );

        let agent = rt.agent_channel("kestrel");

        // A fresh control channel: the battery's original was dropped
        // hundreds of checks ago, and at most one is live at a time.
        let ctl = match rt.control_channel() {
            Ok(c) => c,
            Err(e) => {
                b.check("a control channel is available for the effect section", false, e);
                rt.shutdown();
                let _ = std::fs::remove_dir_all(&scratch);
                return 1;
            }
        };

        // The worktree capability pack, and then the repository. Neither had
        // a door from outside the BEAM before D.1.3a asked for one.
        let packed = rt
            .bridge_call(&json!({"schema":"bridge-command@1",
                                 "command":"install_pack","pack":"worktree"}))
            .unwrap_or(Value::Null);
        b.check(
            "the host can install the worktree capability pack",
            packed["ok"] == true,
            format!("{packed}"),
        );

        // Registering the repository is a bridge call, not a channel
        // command — see the note on `register_repository` in
        // `Ampd.Transport`. Until D.1.3a needed it, nothing outside the
        // BEAM could mint an `rp_` ref at all.
        let reg = rt
            .bridge_call(&json!({"schema":"bridge-command@1",
                                 "command":"register_repository",
                                 "path": repo.to_string_lossy()}))
            .unwrap_or(Value::Null);
        let repo_ref = reg["repository"]["ref"].as_str().unwrap_or("").to_string();

        b.check(
            "the host can register a repository for the runtime to open Lanes on",
            !repo_ref.is_empty(),
            format!("{reg}"),
        );

        match (&agent, git_ok) {
            (Ok(a), true) if !repo_ref.is_empty() => {
                let ws = ctl.call("open_workspace", json!({"name": "d13a"})).unwrap_or(Value::Null);
                let ws_id = ws["result"]["workspace"]["id"].as_str().unwrap_or("").to_string();

                let goal = ctl
                    .call("open_goal", json!({"workspace_ref": ws_id, "title": "production effect"}))
                    .unwrap_or(Value::Null);
                let goal_id = goal["result"]["goal"]["id"].as_str().unwrap_or("").to_string();

                let lane = ctl
                    .call(
                        "open_lane",
                        json!({"goal_ref": goal_id, "actor": "kestrel",
                               "repository_ref": repo_ref, "base_revision": Value::Null}),
                    )
                    .unwrap_or(Value::Null);
                let lane_id = lane["result"]["lane"]["id"].as_str().unwrap_or("").to_string();

                let worker = ctl
                    .call("open_worker", json!({"locus_ref": lane_id, "purpose": "implement"}))
                    .unwrap_or(Value::Null);
                let worker_id = worker["result"]["worker"]["id"].as_str().unwrap_or("").to_string();

                let _ = a.call("attach_worker", json!({"worker_ref": worker_id}));

                // The real grant flow: the agent asks, the person approves.
                let req = a
                    .call(
                        "request_grant",
                        json!({"capability": "worktree.create", "resource": lane_id,
                               "options": {"duration": "workspace",
                                           "reason": "the production effect path"}}),
                    )
                    .unwrap_or(Value::Null);
                let gq = req["result"]["grant_request"]["id"].as_str().unwrap_or("").to_string();

                b.check(
                    "the agent's grant request parks on a person",
                    req["result"]["held"] == true && !gq.is_empty(),
                    format!("{}", req["result"]),
                );

                let approved = ctl
                    .call("approve_grant_request", json!({"request_id": gq, "duration": "workspace"}))
                    .unwrap_or(Value::Null);

                let est = a
                    .call("establish_worktree", json!({"locus_ref": lane_id, "name": "wt-prod"}))
                    .unwrap_or(Value::Null);

                b.check(
                    "an admitted effect reaches the real host through the possessed channel",
                    est["result"]["allow"] == true,
                    format!("approved={approved} establish={est}"),
                );

                // **Checked against the repository, not against the reply.**
                //
                // `path` is deliberately absent from an agent projection —
                // a worktree root is topology — so this cannot look at the
                // directory the agent was told about, and should not want
                // to. What it can do is ask the fixture repository, in this
                // process, what commit `HEAD` is, and require the head the
                // runtime committed to be that commit. A host inventing an
                // observation cannot satisfy that; only a real
                // `git worktree add` from this repository can.
                let fixture_head = std::process::Command::new("git")
                    .arg("-C").arg(&repo).args(["rev-parse", "HEAD"])
                    .output()
                    .ok()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_default();

                let res = &est["result"]["resource"];

                b.check(
                    "the committed worktree is a real checkout of the real repository",
                    !fixture_head.is_empty()
                        && res["head"] == json!(fixture_head)
                        && res["exists"] == true
                        && res["state"] == "OBSERVED_CREATED",
                    format!("fixture HEAD={fixture_head} resource={res}"),
                );

                b.check(
                    "the capability the effect established is active",
                    est["result"]["capability"]["status"] == "active",
                    format!("capability={}", est["result"]["capability"]),
                );

                // **The named path is not merely unused — it is broken.**
                // `SUPER_HOST_BIN` on the runtime points nowhere, and this
                // effect still worked, so the production path cannot have
                // resolved it.
                b.check(
                    "the production effect path did not resolve an executable by name",
                    est["result"]["allow"] == true && std::env::var("SUPER_HOST_BIN").is_err(),
                    "SUPER_HOST_BIN was set for this run, so this proves nothing",
                );

                // ============ D.1.3b·2b · THE PRODUCTION WORLD-JOIN PATH
                //
                // **The freeze criterion, end to end, with nothing selected.**
                //
                // Every Carrier falsifier in ExUnit runs against
                // `Carrier.Machine.Harness`, and `super-host verify` proves
                // the confined process physically. Those are two halves and
                // the join between them was proved by nobody — which is how
                // the real host shipped emitting no `attested` object at all
                // while seventeen floor rows required one, so the production
                // path could not have committed a single Carrier and every
                // test still passed.
                //
                // That is D.1.3a's "no deployed Super could open a Lane"
                // exactly, one slice later. This is the check that would have
                // caught it: a real agent, on a real channel, issuing the real
                // command, against the real host, joining the real World.
                let started = a
                    .call("start_carrier", json!({"locus_ref": lane_id}))
                    .unwrap_or(Value::Null);

                let inc = &started["result"]["carrier"];

                b.check(
                    "a real agent starts a real confined Carrier and it JOINS THE WORLD",
                    started["result"]["allow"] == true
                        && inc["schema"] == "carrier-incarnation@1"
                        && inc["status"] == "RUNNING",
                    format!("{started}"),
                );

                // The incarnation must name this position, not merely exist.
                b.check(
                    "the committed incarnation names the Locus the agent occupies",
                    inc["locus_ref"] == json!(lane_id) && inc["carrier_ref"].is_string(),
                    format!("incarnation={inc}"),
                );

                // And the process is real: the runtime holds an opaque handle,
                // so this reads the pid out of it and asks the kernel.
                let hpr = inc["host_process_ref"].as_str().unwrap_or("").to_string();
                let cpid: Option<u32> = hpr.strip_prefix("hp_")
                    .and_then(|r| r.split('_').next())
                    .and_then(|v| v.parse().ok());
                b.check(
                    "the committed Carrier is a live OS process, not a record",
                    cpid.map(|p| crate::carrier::observe(p).starttime.is_some()).unwrap_or(false),
                    format!("host_process_ref={hpr:?}"),
                );

                // Stop it through the same command path, and require the
                // process to actually be gone — termination requested is not
                // termination established.
                let stopped = a.call("stop_carrier", json!({})).unwrap_or(Value::Null);
                let mut gone = false;
                for _ in 0..40 {
                    if cpid.map(|p| crate::carrier::observe(p).starttime.is_none()).unwrap_or(false) {
                        gone = true;
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                b.check(
                    "stopping through the command path really ends the OS process",
                    stopped["result"]["allow"] == true && gone,
                    format!("stopped={stopped} pid={cpid:?} still alive"),
                );

                // ======== D.1.3b·2c · THE ADMITTED PAYLOAD CANNOT BECOME ANOTHER
                //
                // Review's finding: the ticket bound `profile_basis` and
                // `floor_basis` and nothing that said *what would be run*, so
                //
                //     an implementation admitted as A cannot silently become B
                //
                // was a claim the source did not establish. The only payload
                // identity anywhere was a digest the host produced after the
                // spawn — an attestation about the outcome, not a term of the
                // agreement.
                //
                // The adversary is A with one byte appended: measured to
                // `execve` and behave identically (both exit 65 with no
                // output when run bare), so **nothing but the execution basis
                // can refuse it**. If the swap made B unrunnable this check
                // would pass on the handshake failing and prove nothing.
                let fixture_before = crate::carrier::fixture_path();
                let baseline_digest = fixture_before.as_ref().map(|p| digest_of(p));

                match fixture_before.as_ref().and_then(|p| SwappedFixture::install(p)) {
                    None => b.check(
                        "the payload-swap falsifier could run",
                        false,
                        format!("could not install a B over {fixture_before:?}"),
                    ),
                    Some(swap) => {
                        let before = carrier_children();

                        // The channel measured A when it was established. The
                        // installed bytes are now B. Nothing else moved.
                        let swapped = a
                            .call("start_carrier", json!({"locus_ref": lane_id}))
                            .unwrap_or(Value::Null);

                        let code = swapped["result"]["refusal"]["code"]
                            .as_str()
                            .or_else(|| swapped["result"]["reason"].as_str())
                            .unwrap_or("")
                            .to_string();

                        b.check(
                            "a payload swapped after admission is REFUSED at commit, by name",
                            swapped["result"]["allow"] == false
                                && code == "carrier-execution-basis-changed",
                            format!("{swapped}"),
                        );

                        // It may well have physically started — that is what
                        // the machine phase being outside the total order
                        // means. The property is that it does not survive as
                        // a Carrier, which is a statement about processes and
                        // not about records.
                        let mut reaped = false;
                        for _ in 0..40 {
                            if carrier_children().len() <= before.len() {
                                reaped = true;
                                break;
                            }
                            std::thread::sleep(std::time::Duration::from_millis(100));
                        }
                        b.check(
                            "the refused payload is reaped, leaving no Carrier process behind",
                            reaped,
                            format!("before={before:?} after={:?}", carrier_children()),
                        );

                        drop(swap);
                    }
                }

                // Restored, and proved restored: a falsifier that mutates the
                // installed payload has to leave the tree the way it found it,
                // and "it should have" is not a measurement.
                let restored = fixture_before.as_ref().map(|p| digest_of(p));
                b.check(
                    "the payload-swap falsifier restored the installed fixture",
                    restored.is_some() && restored == baseline_digest,
                    format!("baseline={baseline_digest:?} now={restored:?}"),
                );

                // And a fresh admission under the restored payload succeeds —
                // otherwise the refusal above would be indistinguishable from
                // the swap having broken Carrier starts outright.
                let again = a
                    .call("start_carrier", json!({"locus_ref": lane_id}))
                    .unwrap_or(Value::Null);
                let inc2 = &again["result"]["carrier"];
                b.check(
                    "restoring the admitted payload lets a fresh admission commit",
                    again["result"]["allow"] == true && inc2["status"] == "RUNNING",
                    format!("{again}"),
                );

                // ======== D.1.3b·2c · PEER LOSS ENDS THE PROCESS, PHYSICALLY
                //
                // The one freeze criterion D.1.3b·2b left open in its own
                // words: `E23` proved the reap was *requested against the
                // harness*. The load-bearing proposition is the last arrow,
                // and nothing had ever run it:
                //
                //     real Carrier RUNNING
                //         ↓  the actual owning Peer disappears
                //     semantic membership ends
                //         ↓  Reaper
                //     real host stop
                //         ↓
                //     the actual pid/starttime disappears
                //
                // Not "the reaper received an event". The kernel is asked.
                let hpr2 = inc2["host_process_ref"].as_str().unwrap_or("").to_string();
                let pid2: Option<u32> = hpr2
                    .strip_prefix("hp_")
                    .and_then(|r| r.split('_').next())
                    .and_then(|v| v.parse().ok());
                let st2 = pid2.and_then(|p| crate::carrier::observe(p).starttime);

                b.check(
                    "the Carrier about to be orphaned is a live OS process",
                    st2.is_some(),
                    format!("host_process_ref={hpr2:?}"),
                );

                // Subscribed *before* the loss, so the projection read
                // afterwards is one the runtime pushed in response to it.
                // `latest()` on an unsubscribed channel is `None`, and a check
                // that read `None` as "the Worker is gone" would have been a
                // check measuring its own setup — which is what it did on the
                // first run of this section.
                let sub2 = ctl.call("subscribe", json!({})).unwrap_or(Value::Null);
                let cursor2 = ProjectionCursor::of(&sub2["result"]);

                // **The channel, not the command.** `stop_carrier` would be
                // the runtime being asked; this destroys the agent's transport
                // underneath it, which is what losing a Peer actually is.
                fdpass::shutdown_fd(a.fd());

                let mut orphan_gone = false;
                for _ in 0..80 {
                    if pid2
                        .map(|p| crate::carrier::observe(p).starttime != st2)
                        .unwrap_or(false)
                    {
                        orphan_gone = true;
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }

                b.check(
                    "losing the real owning Peer really ends the Carrier's OS process",
                    orphan_gone,
                    format!(
                        "pid {pid2:?} still shows starttime {st2:?} after its agent channel died"
                    ),
                );

                // And the position outlives the process. A Carrier dying must
                // not take the Worker or the Locus with it — that asymmetry
                // is the whole of `OCCUPIED ∧ OFFLINE` being legitimate, and
                // the reason `Ampd.Peer` holds carriers in a map the Loci
                // store has never been able to reach.
                let after = ctl
                    .projection_after(&cursor2, Duration::from_secs(10))
                    .or_else(|| ctl.latest())
                    .map(|v| v.to_string())
                    .unwrap_or_default();

                b.check(
                    "the Worker and the Locus outlive the Peer that occupied them",
                    !after.is_empty() && after.contains(&worker_id) && after.contains(&lane_id),
                    format!(
                        "worker={worker_id} lane={lane_id} projection_bytes={} \
                         worker_present={} lane_present={}",
                        after.len(),
                        after.contains(&worker_id),
                        after.contains(&lane_id)
                    ),
                );
            }
            (ag, g) => b.check(
                "the production effect path could be exercised at all",
                false,
                format!("agent={:?} fixture_repo={} repo_ref={:?}", ag.is_err(), g, repo_ref),
            ),
        }
    }

    let adopted_inodes = rt.adopted_channel_inodes();
    carrier_confinement(&mut b, &scratch, &adopted_inodes);
    carrier_runtime_fence(&mut b, &scratch);

    println!("\n  {} held · {} failed", b.pass, b.fail);
    rt.shutdown();
    let _ = std::fs::remove_dir_all(&scratch);

    if b.fail == 0 { 0 } else { 1 }
}

/// D.1.3b·2d — the physical half of the incarnation fence.
///
/// # What this measures, and what it deliberately does not
///
/// The fence is a chain:
///
/// ```text
/// Ampd.Peer dies → Gate fences → drain → host empties its set → /proc agrees
/// ```
///
/// The first three arrows are BEAM-side and are proved by `E29`, which kills
/// the real `Ampd.Peer`, lets the real supervisor restart it, and requires the
/// real Gate to converge. The last two are physical and are proved here,
/// against real confined Carrier processes on a real `serve_carrier`.
///
/// **The composition is not run in one process, and the reason is a door I
/// declined to add.** Nothing outside the BEAM can kill `Ampd.Peer`: the
/// world-reset path that re-mints its epoch also resets `Ampd.Bridge`, which
/// disposes the Carrier channel — so `serve_carrier` already drains through
/// channel death and the interesting case never arises. Reaching it from the
/// battery would need a runtime command that kills a supervised process on
/// request, which is a denial-of-service primitive reachable by whoever holds
/// human control. The transport between the halves is the same possessed
/// channel, the same framing and the same `EffectChannel.request` that the
/// production World-join exercises end-to-end for start and stop.
fn carrier_runtime_fence(b: &mut Battery, scratch: &Path) {
    use crate::{carrier, fdpass, read_frame, write_frame};

    println!("\n  D.1.3b·2d · the runtime incarnation fence");

    if carrier::fixture_path().is_none() {
        b.check("the fence falsifier could run", false, "no carrier fixture");
        return;
    }

    let dir = scratch.join("fence");
    let _ = std::fs::create_dir_all(&dir);

    let Ok(fdpass::Pair(mine, theirs)) = fdpass::pair_stream() else {
        b.check("the fence falsifier could run", false, "no socketpair");
        return;
    };

    let served = dir.clone();
    std::thread::spawn(move || crate::serve_carrier(theirs, served));

    // Three real Carriers under runtime incarnation A. Three rather than one
    // because `Ampd.Peer` dying loses every membership at once, and a drain
    // that emptied a set of one would not distinguish "empties the set" from
    // "stops the Carrier it was told about".
    let mut pids: Vec<(u32, Option<u64>)> = Vec::new();
    for i in 0..3 {
        let req = json!({
            "schema": "carrier-start-request@1", "op": "start",
            "carrier_ref": format!("cr_fence{i}"),
            "carrier_epoch": format!("fence-epoch-{i}"),
            "runtime_epoch": "runtime-A",
        });
        if write_frame(mine, &req).is_err() { break }
        let Ok(obs) = read_frame(mine) else { break };
        let hpr = obs["host_process_ref"].as_str().unwrap_or("").to_string();
        if let Some(p) = hpr.strip_prefix("hp_").and_then(|r| r.split('_').next())
            .and_then(|v| v.parse::<u32>().ok())
        {
            pids.push((p, carrier::observe(p).starttime));
        }
    }

    b.check(
        "three real Carriers are running under runtime incarnation A",
        pids.len() == 3 && pids.iter().all(|(_, st)| st.is_some()),
        format!("{pids:?}"),
    );

    // **The second line of defence, before the drain.** A start under a
    // different incarnation while the set is non-empty is refused by the host
    // itself, so a Gate that restarted alongside the Peer and had nothing to
    // compare still cannot start a process into somebody else's set.
    let _ = write_frame(mine, &json!({
        "schema": "carrier-start-request@1", "op": "start",
        "carrier_ref": "cr_fence_wrong", "carrier_epoch": "e",
        "runtime_epoch": "runtime-B",
    }));
    let wrong = read_frame(mine).unwrap_or(Value::Null);
    b.check(
        "a start under a NEW incarnation is refused while the old set is non-empty",
        wrong["refused"].as_str().unwrap_or("").contains("runtime-A"),
        format!("{wrong}"),
    );

    // The drain. It names no carrier_ref, carries no actor, Locus, Worker or
    // grant, and answers only once the set is physically empty.
    let _ = write_frame(mine, &json!({
        "schema": "carrier-runtime-drain-request@1", "op": "drain",
        "runtime_epoch": "runtime-B",
    }));
    let drained = read_frame(mine).unwrap_or(Value::Null);

    b.check(
        "one drain empties the whole physical Carrier set",
        drained["schema"] == "carrier-runtime-drain-observation@1"
            && drained["remaining"] == 0
            && drained["reaped"] == 3,
        format!("{drained}"),
    );

    // **Asked of the kernel, not of the reply.** `terminate` is awaited
    // before the drain answers, so this needs no polling — and if it ever
    // does, the host answered before the processes were gone, which is the
    // distinction this whole lane is about.
    let survivors: Vec<u32> = pids
        .iter()
        .filter(|(p, st)| carrier::observe(*p).starttime == *st)
        .map(|(p, _)| *p)
        .collect();

    b.check(
        "every drained Carrier is gone from /proc when the drain answers",
        pids.len() == 3 && survivors.is_empty(),
        format!("still alive: {survivors:?}"),
    );

    // And the set now belongs to nobody, so the new incarnation may start.
    let _ = write_frame(mine, &json!({
        "schema": "carrier-start-request@1", "op": "start",
        "carrier_ref": "cr_fence_after", "carrier_epoch": "after",
        "runtime_epoch": "runtime-B",
    }));
    let after = read_frame(mine).unwrap_or(Value::Null);
    b.check(
        "after the drain the replacement incarnation may start a Carrier",
        after["host_process_ref"].is_string() && after["refused"].is_null(),
        format!("{after}"),
    );

    let _ = write_frame(mine, &json!({
        "schema": "carrier-runtime-drain-request@1", "op": "drain",
        "runtime_epoch": "runtime-B",
    }));
    let _ = read_frame(mine);
    fdpass::close_fd(mine);
}

/// The Carrier processes this host currently has as direct children.
///
/// Read from `/proc` rather than from the host's own `live` map, for the
/// reason the descriptor census is taken from outside: the map is the record
/// and the record is what a leak would be missing from. A refused start that
/// left a process behind would be invisible to anything that asked the host
/// what it thinks it is holding.
fn carrier_children() -> Vec<u32> {
    let me = std::process::id();
    let mut out = Vec::new();

    let Ok(rd) = std::fs::read_dir("/proc") else { return out };

    for e in rd.flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else { continue };
        let Ok(s) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else { continue };
        // Field 2 (comm) may contain spaces and parentheses; split after the
        // last ')' — the same rule `carrier::observe` uses for starttime.
        let Some(tail) = s.rsplit_once(')') else { continue };
        let ppid: Option<u32> = tail.1.split_whitespace().nth(1).and_then(|v| v.parse().ok());

        if ppid == Some(me) {
            let exe = std::fs::read_link(format!("/proc/{pid}/exe"))
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            if exe.contains("super-carrier-fixture") {
                out.push(pid);
            }
        }
    }

    out
}

fn digest_of(p: &Path) -> String {
    std::fs::read(p)
        .map(|b| crate::sha256::digest(&b))
        .unwrap_or_else(|e| format!("unreadable:{e}"))
}

/// The installed Carrier payload, temporarily replaced, restored on `Drop`.
///
/// **B is A with one trailing byte.** The kernel's ELF loader ignores bytes
/// past the last mapped segment, so B `execve`s and behaves exactly as A does
/// — measured: both exit 65 with no output when run without a control
/// descriptor. That is deliberate and load-bearing. An adversary that failed
/// to start would be refused by the handshake, and the falsifier would pass
/// while proving nothing about the execution basis.
///
/// `Drop` rather than a cleanup call: this replaces a file in the developer's
/// build tree, and a panic between install and restore would leave it
/// replaced. The battery also *measures* that the restore happened, because
/// a destructive falsifier that only usually cleans up is a falsifier that
/// eventually costs somebody a confusing afternoon.
struct SwappedFixture {
    path: PathBuf,
    original: Vec<u8>,
}

impl SwappedFixture {
    fn install(path: &Path) -> Option<SwappedFixture> {
        use std::os::unix::fs::PermissionsExt;

        let original = std::fs::read(path).ok()?;
        let mut modified = original.clone();
        modified.push(0);

        let tmp = path.with_extension("swap-b");
        std::fs::write(&tmp, &modified).ok()?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).ok()?;
        // Atomic: the pathname holds A or it holds B, never a partial write
        // that would make an exec failure the thing under test.
        std::fs::rename(&tmp, path).ok()?;

        Some(SwappedFixture { path: path.to_path_buf(), original })
    }
}

impl Drop for SwappedFixture {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;

        let tmp = self.path.with_extension("swap-a");
        if std::fs::write(&tmp, &self.original).is_ok() {
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

// ==================================== D.1.3b · THE CONFINED CARRIER PROCESS
//
// **Every attack is run twice.** Once inside a Carrier and once as an
// unconfined child of this same host, and a refusal is scored only where the
// bare control *succeeded*.
//
// The reason is measured. This machine runs `kernel.yama.ptrace_scope = 1`,
// under which `ptrace` and `pidfd_getfd` against a non-descendant fail with
// `EPERM` before any LSM is consulted. A battery that ran the attack, saw the
// refusal and printed green would be reporting a sysctl — and would go on
// printing green after an administrator set it to `0`.
//
// That is D.1.3a's standard-descriptor defect in new clothes: there, the
// answer depended on who launched the gate; here it would depend on a setting
// the property does not mention. The fix has the same shape both times.
//
// Three grades of attribution are reported, and no two are the same claim:
//
//   ATTRIBUTED        the refusal carries 130 (EOWNERDEAD), which Super's
//                     filter returns and no ptrace, LSM or DAC path
//                     produces, so the refusal names its author
//   DIFFERENTIAL      the bare control succeeded and the confined run did
//                     not, so the confinement is what closed it
//   AMBIENT-PRECLUDED the bare control failed too, so this host cannot show
//                     the confinement was necessary — only that Super
//                     refuses it as well
//
// `ptrace` and `pidfd_getfd` earn the first and the third on this kernel and
// not the second. Reported as such rather than rounded up.
//
// The third grade was added after a review made an objection the first two
// could not answer: *the minimal fixture's inability to exploit something is
// not evidence that the syscall isn't available.* Thirteen syscalls are now
// issued rather than assumed; see the negative census at the end.

/// One row of the confined/bare comparison.
struct Attack {
    bare: Option<(bool, i32)>,
    confined: Option<(bool, i32)>,
}

fn parse_probe_log(p: &Path) -> std::collections::BTreeMap<String, (bool, i32)> {
    let mut m = std::collections::BTreeMap::new();
    if let Ok(s) = std::fs::read_to_string(p) {
        for l in s.lines() {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() == 3 {
                m.insert(f[0].to_string(), (f[1] == "ALLOWED", f[2].parse().unwrap_or(-1)));
            }
        }
    }
    m
}

/// **Verification scaffolding: an unconfined control.**
///
/// Deliberately here and not in `carrier.rs`. That module has exactly one
/// spawn path and it is confined; a `spawn_unconfined` living beside it would
/// be one refactor away from becoming a fallback, which is the shape C13
/// exists to keep out of the effect path and which has no better claim here.
fn bare_control(probe: &Path, dir: &Path, log: &Path, target: u32, leak: std::os::fd::RawFd) -> bool {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let Ok(out) = std::fs::File::create(log) else { return false };
    let Ok(err) = out.try_clone() else { return false };
    let args = [target.to_string(), "9".to_string(), dir.to_string_lossy().to_string()];
    let child = unsafe {
        Command::new(probe)
            .args(args)
            .current_dir(dir)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::from(out))
            .stderr(Stdio::from(err))
            .pre_exec(move || {
                crate::fdpass::ensure_std_fds()?;
                crate::fdpass::dup_onto(leak, 9)
            })
            .spawn()
    };
    match child {
        Ok(mut c) => c.wait().map(|_| true).unwrap_or(false),
        Err(_) => false,
    }
}

fn carrier_confinement(b: &mut Battery, scratch: &Path, adopted: &[u64]) {
    use crate::{carrier, confine};

    println!("\n  D.1.3b · the confined Carrier process");

    let abi = confine::landlock_abi();
    b.check(
        "this kernel reports a Landlock ABI, read from the kernel not assumed",
        abi.is_some(),
        format!("landlock_create_ruleset(VERSION) said {abi:?}"),
    );
    let Some(abi) = abi else { return };

    // ABI 10 is where LANDLOCK_ACCESS_NET_BIND_UDP and CONNECT_SEND_UDP
    // arrive. Below it, UDP is not governable by Landlock at all and the
    // policy closes it at `socket(2)` in seccomp instead. Recording which
    // side of that line the kernel is on keeps a later reader from assuming
    // the network row means the same thing it would on a newer machine.
    b.check(
        "the profile records whether UDP is governable by Landlock here",
        true,
        String::new(),
    );
    println!(
        "                 landlock abi {abi} · udp governable by landlock: {}",
        abi >= 10
    );

    let Some(fixture) = carrier::fixture_path() else {
        b.check(
            "the Carrier fixture is built and resolvable from the host image",
            false,
            "no super-carrier-fixture beside super-host or in carrier-fixture/target/release",
        );
        return;
    };
    let probe = fixture.with_file_name("probe");

    let dir = scratch.join("carrier");
    let _ = std::fs::create_dir_all(&dir);

    // The ruleset descriptor must sit above every number the allowlist names.
    //
    // Asserted as a number rather than as "a Carrier starts", because the
    // collision is latent: the ruleset takes the lowest free descriptor, so it
    // lands on fd 3 only in a host holding few of them. The sabotage battery
    // demonstrated the difference — with the relocation stubbed out, "a
    // confined Carrier starts" stayed green here and went red in a smaller
    // harness. A check whose ability to fail depends on how many files the
    // host happens to have open is not a check.
    {
        let p = confine::Policy::minimal(&dir.to_string_lossy(), &fixture.to_string_lossy());
        match confine::prepare(&p) {
            Ok(prep) => b.check(
                "the Landlock ruleset descriptor sits above the Carrier's allowlist",
                prep.ruleset_fd() >= confine::Prepared::allowlist_ceiling(),
                format!(
                    "ruleset landed on fd {} · allowlist ceiling {}",
                    prep.ruleset_fd(),
                    confine::Prepared::allowlist_ceiling()
                ),
            ),
            Err(e) => b.check(
                "the Landlock ruleset descriptor sits above the Carrier's allowlist",
                false,
                e,
            ),
        }
    }

    // ---------------------------------------------------------- lifecycle
    let log = dir.join("fixture.log");
    let incarnation = crate::new_epoch();
    let started = carrier::spawn(&fixture, &dir, &log, &incarnation, None);
    match started {
        Err(ref e) => {
            b.check("a confined Carrier starts", false, e.clone());
            return;
        }
        Ok(_) => b.check("a confined Carrier starts", true, String::new()),
    }
    let mut c = started.unwrap();

    let hs = c.handshake(5_000);
    b.check(
        "the Carrier echoes the incarnation the host minted, not one it chose",
        hs.is_ok(),
        format!("{hs:?}"),
    );

    let o = c.observe();

    // ------------------------------------------------ the exact descriptor set
    let want: Vec<i32> = vec![0, 1, 2, 3];
    let got: Vec<i32> = o.fds.keys().copied().collect();
    b.check(
        "the Carrier's descriptor table is exactly {0,1,2,3}",
        got == want,
        format!("{:?}", o.fds),
    );
    b.check(
        "descriptor 0 is the explicit stdin policy and not an inherited stream",
        o.fds.get(&0).map(|s| s == "/dev/null").unwrap_or(false),
        format!("fd 0 = {:?}", o.fds.get(&0)),
    );
    b.check(
        "descriptor 3 is the control channel this host created, by inode",
        match (o.fds.get(&3), c.control_inode()) {
            (Some(t), Some(i)) => crate::socket_inode(t) == Some(i),
            _ => false,
        },
        format!("fd 3 = {:?} · recorded inode {:?}", o.fds.get(&3), c.control_inode()),
    );
    b.check(
        "no descriptor the Carrier holds is a channel this host handed the runtime",
        !o.fds.values().any(|t| crate::socket_inode(t).map(|i| adopted.contains(&i)).unwrap_or(false)),
        format!("{:?}", o.fds),
    );

    // -------------------------------------------- observed, not configured
    b.check(
        "no_new_privs is observed set in the Carrier, read from its own /proc",
        o.no_new_privs == Some(true),
        format!("NoNewPrivs = {:?}", o.no_new_privs),
    );
    b.check(
        "seccomp is observed in filter mode with at least one filter attached",
        o.seccomp_mode == Some(2) && o.seccomp_filters.unwrap_or(0) >= 1,
        format!("mode={:?} filters={:?}", o.seccomp_mode, o.seccomp_filters),
    );
    b.check(
        "the Carrier's environment is constructed, not inherited",
        o.env_keys.len() == 2
            && o.env_keys.iter().all(|k| k.starts_with("SUPER_CARRIER_")),
        format!("{:?}", o.env_keys),
    );
    b.check(
        "the Carrier is the payload the host named, by /proc/<pid>/exe",
        o.exe.as_deref() == Some(fixture.to_string_lossy().as_ref()),
        format!("{:?}", o.exe),
    );
    b.check(
        "process identity is pid AND start time, so a reused pid is not the Carrier",
        c.same_process() && o.starttime.is_some(),
        format!("starttime = {:?}", o.starttime),
    );

    // ---------------------------- the executable that ran, not the pathname
    //
    // Review found a TOCTOU inside the host's own attestation, needing no
    // attacker:
    //
    //     resolve fixture path → spawn → handshake → fixture_digest(path)
    //
    // The digest was taken from the pathname *after* the process had already
    // executed, so anything replacing the file in that window — an ordinary
    // package update, a concurrent `cargo build` — would be attested as the
    // running Carrier while the live process was the previous binary.
    //
    // The fix reads the bytes through `/proc/<pid>/exe`, which is a magic link
    // to the executed *inode*. This is the negative test: A is running, the
    // pathname is atomically replaced by B, and the host must still identify
    // A. Note that the check two rows above — `exe` by link target — goes
    // stale here on purpose; the link target becomes `<path> (deleted)`, which
    // is exactly why the target is the wrong evidence and the bytes are right.
    //
    // **Read out of the attestation the host actually builds**, not by
    // calling the digest function. The first version of this section called
    // `running_image_digest` directly, so its name claimed it measured "what
    // the host attests" while it measured a function the attestation happens
    // to use — and `tools/sabotage-host.sh` scored it **NOT A FALSIFIER**:
    // reverting `start_one` to digest the pathname left it green. That is the
    // same class of defect as every other one this round found, in the check
    // written to catch it.
    {
        let attested = |c: &carrier::Carrier| -> String {
            crate::carrier_attestation(c, &dir)["execution_basis"]["payload_digest"]
                .as_str()
                .unwrap_or("")
                .to_string()
        };

        let running = attested(&c);
        let a_bytes = digest_of(&fixture);

        b.check(
            "the running Carrier's image digest is measured through its own /proc",
            running == a_bytes && !running.starts_with("unreadable:"),
            format!("attested={running} installed={a_bytes}"),
        );

        match SwappedFixture::install(&fixture) {
            None => b.check(
                "the executable-TOCTOU falsifier could run",
                false,
                format!("could not install a B over {}", fixture.display()),
            ),
            Some(swap) => {
                let b_bytes = digest_of(&fixture);
                let after = attested(&c);

                b.check(
                    "replacing the pathname after exec does not change what the host attests",
                    after == a_bytes && after != b_bytes && a_bytes != b_bytes,
                    format!("after_swap={after} A={a_bytes} B={b_bytes}"),
                );

                // The counterexample, stated as a measurement rather than as
                // a claim about what the old code would have done: the
                // pathname now yields B while the process is still A.
                b.check(
                    "and the pathname the Carrier was launched from now yields the OTHER binary",
                    b_bytes != a_bytes && !b_bytes.starts_with("unreadable:"),
                    format!("path={b_bytes} running={after}"),
                );

                // `(deleted)`: the link target is no longer usable evidence,
                // which is the whole argument for reading bytes through it.
                let relinked = crate::carrier::observe(c.pid).exe.unwrap_or_default();
                b.check(
                    "the /proc/<pid>/exe link TARGET goes stale while its bytes do not",
                    relinked.ends_with("(deleted)"),
                    format!("exe link = {relinked:?}"),
                );

                drop(swap);
            }
        }

        b.check(
            "the executable-TOCTOU falsifier restored the installed fixture",
            digest_of(&fixture) == a_bytes,
            format!("fixture is now {}", digest_of(&fixture)),
        );
    }

    let clean = c.terminate(3_000);
    b.check(
        "the Carrier stops on SIGTERM without needing SIGKILL",
        clean,
        "it had to be killed",
    );
    b.check(
        "a terminated Carrier leaves no process behind",
        crate::carrier::observe(c.pid).starttime != o.starttime,
        format!("pid {} still shows the original start time", c.pid),
    );

    // ------------------------------------- the attributable attack battery
    if !probe.is_file() {
        b.check(
            "the adversarial Carrier probe is built",
            false,
            format!("no probe at {}", probe.display()),
        );
        return;
    }

    // --- the clean case FIRST, while nothing has cleared CLOEXEC ---
    //
    // Order matters: this is the control for the leak below, and running it
    // afterwards would measure the harness rather than the launch path.
    let clean_fds: Vec<i32> = {
        let held = std::fs::File::open("/etc/passwd").ok();
        let r = carrier::spawn(&fixture, &dir, &dir.join("f2.log"), &crate::new_epoch(), None);
        let f = match r {
            Ok(mut r) => {
                let f = r.observe().fds.keys().copied().collect();
                r.terminate(2_000);
                f
            }
            Err(_) => vec![],
        };
        drop(held);
        f
    };

    // A sensitive file this host opens BEFORE any Landlock domain exists, then
    // deliberately leaks into the child on fd 9.
    let Ok(leaked) = std::fs::File::open("/etc/passwd") else { return };
    let leak_fd = { use std::os::fd::AsRawFd; leaked.as_raw_fd() };
    let _ = crate::fdpass::make_inheritable(leak_fd);

    // Negative control: with CLOEXEC cleared, the descriptor really does
    // arrive. Without this, the clean result above would be consistent with a
    // launch path that never inherits anything for reasons of its own.
    let leak_visible: bool = {
        let r = carrier::spawn_with(
            &fixture, &dir, &dir.join("f3.log"), &crate::new_epoch(), None, &[], &[(leak_fd, 9)],
        );
        match r {
            Ok(mut r) => {
                let f = r.observe().fds;
                r.terminate(2_000);
                f.contains_key(&9)
            }
            Err(_) => false,
        }
    };

    let me = std::process::id();
    let bare_log = dir.join("bare.log");
    let ran_bare = bare_control(&probe, &dir, &bare_log, me, leak_fd);
    b.check(
        "the unconfined control ran, so refusals can be attributed at all",
        ran_bare && !parse_probe_log(&bare_log).is_empty(),
        "without a bare control every refusal is unattributable",
    );

    let conf_log = dir.join("confined.log");
    let args = [me.to_string(), "9".to_string(), dir.to_string_lossy().to_string()];
    let pol = confine::Policy::minimal(&dir.to_string_lossy(), &probe.to_string_lossy());
    let probe_run = carrier::spawn_with(
        &probe,
        &dir,
        &conf_log,
        &crate::new_epoch(),
        Some(pol),
        &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        &[(leak_fd, 9)],
    );
    match probe_run {
        Err(e) => {
            b.check("the adversarial probe runs as a confined Carrier", false, e);
            return;
        }
        Ok(mut p) => {
            b.check("the adversarial probe runs as a confined Carrier", true, String::new());
            std::thread::sleep(std::time::Duration::from_millis(900));
            p.terminate(2_000);
        }
    }

    let bare = parse_probe_log(&bare_log);
    let conf = parse_probe_log(&conf_log);
    let row = |k: &str| Attack {
        bare: bare.get(k).copied(),
        confined: conf.get(k).copied(),
    };

    // Closed, and demonstrably by us: the bare control reached it.
    for (name, what) in [
        ("open_etc_passwd", "host configuration"),
        ("open_home_dotfile", "an unrelated home directory"),
        ("open_super_source", "Super's own source tree"),
        ("open_host_proc_fd_dir", "the trusted host's descriptor table"),
        ("execve_other_binary", "a binary the policy does not name"),
        ("socket_inet_tcp", "TCP"),
        ("socket_inet_udp", "UDP"),
        ("unshare_user_ns", "a new user namespace"),
        ("pidfd_open_host", "a pidfd on the trusted host"),
        ("signal_host", "a signal to the trusted host"),
    ] {
        let a = row(name);
        let closed = matches!(a.bare, Some((true, _))) && matches!(a.confined, Some((false, _)));
        b.check(
            &format!("a Carrier cannot reach {what}, and the bare control could"),
            closed,
            format!("bare={:?} confined={:?}", a.bare, a.confined),
        );
    }

    // Landlock does not reach a descriptor that was already open. This is the
    // falsifier that keeps filesystem confinement from being read as
    // descriptor confinement — it must SUCCEED in the confined run.
    let pre = row("read_inherited_preopen_fd");
    b.check(
        "an inherited pre-open descriptor is readable THROUGH the filesystem sandbox",
        matches!(pre.confined, Some((true, _))),
        format!(
            "confined={:?} — if this ever refuses, the claim below has changed and the \
             descriptor doctrine must be re-derived rather than assumed",
            pre.confined
        ),
    );
    // The other half, and it must be falsified in both directions — a check
    // that only ever ran the clean case would also pass if the Carrier
    // inherited everything, because it would never have seen the difference.
    //
    // Producing the leak at all required `make_inheritable`, i.e. deliberately
    // clearing `FD_CLOEXEC`. That is the finding: the production path cannot
    // reproduce it because every descriptor this host creates is
    // close-on-exec by construction — `SOCK_CLOEXEC` in `pair_stream`,
    // `O_CLOEXEC` in `lock_world` and on the Landlock ruleset, and Rust's
    // `File::open` — and the only thing that clears it is `dup_onto`, called
    // on exactly the descriptors in the allowlist.
    //
    // Measured while writing this: the first version of this check ran AFTER
    // the leak was set up and went red, because the harness's own leaked
    // descriptor reached the Carrier. The check was correct; the thing it
    // caught was the test.
    b.check(
        "the leaked descriptor IS visible to the Carrier when CLOEXEC is cleared",
        leak_visible,
        "the negative control did not reproduce the leak, so the check below proves nothing"
    );
    b.check(
        "the real Carrier launch path leaks no such descriptor",
        clean_fds == vec![0, 1, 2, 3],
        format!("the production path inherited {clean_fds:?} with CLOEXEC intact"),
    );

    // Same-UID theft: attributable by errno, NOT by differential, and the
    // difference is the check.
    for name in ["ptrace_attach_host", "pidfd_getfd_host_fd3"] {
        let a = row(name);
        let ours = matches!(a.confined, Some((false, e)) if e as u32 == confine::SUPER_DENY_ERRNO);
        b.check(
            &format!("{name} is refused by Super's own filter, by errno"),
            ours,
            format!("confined={:?}, expected errno {}", a.confined, confine::SUPER_DENY_ERRNO),
        );
        let ambient = matches!(a.bare, Some((false, _)));
        b.check(
            &format!("{name} is reported as AMBIENT where the bare control also refused"),
            ambient,
            format!(
                "bare={:?} — if the bare control now SUCCEEDS this becomes a differential \
                 result and the ambient caveat can be dropped",
                a.bare
            ),
        );
    }

    // ------------------------------------------- the negative syscall census
    //
    // **"The minimal fixture's inability to exploit something is not evidence
    // that the syscall isn't available."** That review objection is correct,
    // and it applies to every deny-list entry nobody ever called. A Carrier
    // that opens no files says nothing about `memfd_create`; a list of
    // numbers in `confine::DENIED` is a list of intentions until something
    // issues the syscall and reads what came back.
    //
    // So each of these is *called*, in both runs, and graded. The three
    // grades are not interchangeable and each check's name says which one its
    // row earned on this host:
    //
    //   ATTRIBUTED         the confined refusal carries errno 130
    //                      (EOWNERDEAD), which Super's filter returns and no
    //                      ptrace, LSM or DAC path produces — so the refusal
    //                      names its author
    //   DIFFERENTIAL       the bare control reached it and the Carrier did
    //                      not — so the confinement is what closed it
    //   AMBIENT-PRECLUDED  the bare control could not reach it either, so
    //                      this host cannot prove the confinement was
    //                      necessary. It can only show that Super refuses it
    //                      too, which is a weaker claim and is printed as
    //                      one. `mount` and `pivot_root` are here because
    //                      they need CAP_SYS_ADMIN, and `bpf` because
    //                      `kernel.unprivileged_bpf_disabled = 2` on this
    //                      machine — all three before any of this runs.
    //
    // The grades are computed, never asserted: a machine with
    // `unprivileged_bpf_disabled = 0` would move `bpf` to DIFFERENTIAL and
    // this battery would print the stronger word without being edited. What
    // is asserted is attribution, because that is the claim that does not
    // depend on the host's settings.
    //
    // A row ALLOWED in the confined run reaches no grade at all. It is named
    // UNRESOLVED GAP and its check fails — an available dangerous syscall
    // must never pass quietly, which is the whole of the objection.
    const CENSUS: &[(&str, u32, &str)] = &[
        ("memfd_create", 319, "a file with no name to execute from"),
        ("execveat_other_binary", 322, "execution by descriptor, around Landlock's pathnames"),
        ("clone", 56, "a second process"),
        ("clone3", 435, "a second process by the newer call"),
        ("fork", 57, "a second process by the oldest call"),
        ("vfork", 58, "a second process sharing this one's memory"),
        ("process_vm_readv", 310, "another process's memory, read"),
        ("process_vm_writev", 311, "another process's memory, written"),
        ("keyctl", 250, "the kernel keyring"),
        ("bpf", 321, "loading kernel bytecode"),
        ("perf_event_open", 298, "the performance counters"),
        ("mount", 165, "the mount table"),
        ("pivot_root", 155, "the root of the filesystem"),
        // --- the same numbers in the other numbering space ---------------
        //
        // D.1.3b·2e. Every row above compares a syscall number, and until
        // this block existed they all compared it in one of the *two* spaces
        // an x86-64 process can issue. x32 sets bit 30 of `nr` and reports
        // `AUDIT_ARCH_X86_64`, so `confine::build_filter`'s architecture
        // check passed it through and every `BPF_JEQ` below missed.
        //
        // Measured against the frozen filter: 23 of the 28 numbers in
        // `DENIED` reached their handler this way. These five are the ones
        // worth a standing row — `fork_x32` and `clone_x32` because they
        // *made processes*, which is the physical-lifetime claim rather than
        // a confinement one, and the rest because they succeed unconfined
        // and so earn a real DIFFERENTIAL rather than an ambient excuse.
        ("fork_x32", 57 | 0x4000_0000, "a second process, by the x32 number"),
        ("clone_x32", 56 | 0x4000_0000, "a second process, by the x32 number"),
        ("unshare_user_ns_x32", 272 | 0x4000_0000, "a new user namespace, by the x32 number"),
        ("kill_x32", 62 | 0x4000_0000, "signalling, by the x32 number"),
        ("pidfd_open_x32", 434 | 0x4000_0000, "a pidfd, by the x32 number"),
    ];

    let mut covered = 0usize;
    for (name, nr, what) in CENSUS {
        let a = row(name);
        let refused = matches!(a.confined, Some((false, _)));
        let attributed =
            matches!(a.confined, Some((false, e)) if e as u32 == confine::SUPER_DENY_ERRNO);
        let bare_reached = matches!(a.bare, Some((true, _)));
        let bare_refused = matches!(a.bare, Some((false, _)));
        if a.confined.is_some() {
            covered += 1;
        }

        let grade = if !refused {
            "UNRESOLVED GAP — reachable inside the Carrier"
        } else if attributed && bare_reached {
            "ATTRIBUTED · DIFFERENTIAL"
        } else if attributed && bare_refused {
            "ATTRIBUTED · AMBIENT-PRECLUDED"
        } else if attributed {
            "ATTRIBUTED · no bare reading"
        } else if bare_reached {
            "DIFFERENTIAL but NOT ATTRIBUTED"
        } else {
            "NEITHER ATTRIBUTED NOR DIFFERENTIAL"
        };

        b.check(
            &format!("{name} is refused inside a Carrier — {grade}"),
            attributed,
            format!(
                "nr {nr} · {what} · bare={:?} confined={:?} · expected a confined refusal \
                 carrying errno {}",
                a.bare,
                a.confined,
                confine::SUPER_DENY_ERRNO
            ),
        );
    }

    b.check(
        "every syscall in the negative census was actually issued by the confined probe",
        covered == CENSUS.len(),
        format!(
            "{covered} of {} rows present in the confined log — a missing row is a syscall \
             nobody tried, which is the non-evidence this census replaces",
            CENSUS.len()
        ),
    );

    // `vfork` is the one row with no bare reading, and the absence is
    // declared rather than inferred.
    //
    // The probe will not call `vfork` where a child could be created:
    // measured, a raw `vfork` from compiled Rust resumes the parent at the
    // wrong instruction, because the child's first `call` overwrites the
    // return address the suspended parent is about to `ret` to. Under the
    // filter no child exists — seccomp answers before the kernel forks — so
    // the confined reading above is real. The unconfined one is not taken,
    // and the probe prints a row saying so, because a line that is merely
    // missing is indistinguishable from a probe that died.
    b.check(
        "the unconfined control declares that it declined to call vfork, rather than \
         omitting the row",
        matches!(bare.get("vfork_not_attempted_shared_stack"), Some((true, _)))
            && !bare.contains_key("vfork"),
        format!(
            "bare marker={:?} bare vfork row={:?}",
            bare.get("vfork_not_attempted_shared_stack"),
            bare.get("vfork")
        ),
    );

    // Configured against observed, which this module never merges.
    //
    // The census above is the enforced side. This is the other question: does
    // the policy *say* what the measurements found? A syscall that came back
    // 130 without being on the list, or is on the list without coming back
    // 130, means something other than this filter answered — and inferring
    // which would be exactly the mistake `SUPER_DENY_ERRNO` exists to
    // prevent.
    let undeclared: Vec<&str> = CENSUS
        .iter()
        .filter(|(_, nr, _)| !confine::denies(*nr))
        .map(|(n, _, _)| *n)
        .collect();
    b.check(
        "the filter's configured deny list names every syscall the census measured refused",
        undeclared.is_empty(),
        format!("measured refused, absent from DENIED: {undeclared:?}"),
    );

    // The one member of the family that stays PERMITTED, named so it cannot
    // be mistaken for an oversight.
    //
    // `execve` cannot be denied: the filter is installed in `pre_exec`, so
    // the Carrier's own exec has not happened yet and denying it would kill
    // every Carrier at birth. Nothing bounds it but Landlock's `FS_EXECUTE`
    // grant — which makes this row DIFFERENTIAL and never ATTRIBUTED, and the
    // errno says which: 13 (EACCES, from Landlock) and not 130. `execveat`
    // has no such requirement and is on the list, so the same target file is
    // refused twice in the same run by two different authors, and the census
    // row above holds the other half.
    let ex = row("execve_other_binary");
    b.check(
        "execve stays PERMITTED by seccomp and is bounded by Landlock alone — \
         DIFFERENTIAL, never ATTRIBUTED",
        matches!(ex.bare, Some((true, _)))
            && matches!(ex.confined, Some((false, e)) if e == 13)
            && !confine::denies(59),
        format!(
            "bare={:?} confined={:?} · seccomp denies execve: {} · expected EACCES(13) from \
             Landlock, not {} from the filter",
            ex.bare,
            ex.confined,
            confine::denies(59),
            confine::SUPER_DENY_ERRNO
        ),
    );

    // **Close the deliberate leak before measuring anything else.**
    //
    // Third time this descriptor has contaminated a later check: it broke the
    // clean-spawn check in b·1, it broke the replacement battery here, and
    // between those it was the reason the clean case had to be hoisted above
    // the leak setup. The descriptor table is process-wide state shared by
    // every check in this function, and `make_inheritable` is a mutation of
    // it that outlives the block that wanted it.
    //
    // The rule, since it keeps being learned: a check that clears `FD_CLOEXEC`
    // owns restoring it. Dropping the `File` is the version of that with no
    // way to forget.
    drop(leaked);

    // ------------------------------------------ D.1.3b·2a · FD ownership
    //
    // Source review found a descriptor-lifetime bug in `Carrier::handshake`
    // that no gate here would have caught, because b·1's census reads the
    // CHILD's descriptor table and the leak was on the HOST side. These
    // checks look at the other end.

    let host_fds = || std::fs::read_dir("/proc/self/fd").map(|d| d.count()).unwrap_or(0);

    let baseline = host_fds();
    let mut cycle_ok = true;
    let mut peak = baseline;
    for _ in 0..100 {
        match carrier::spawn(&fixture, &dir, &dir.join("cyc.log"), &crate::new_epoch(), None) {
            Ok(mut c) => {
                if c.handshake(5_000).is_err() { cycle_ok = false }
                c.terminate(2_000);
            }
            Err(_) => cycle_ok = false,
        }
        let now = host_fds();
        if now > peak { peak = now }
    }
    let after = host_fds();

    b.check(
        "100 start/stop cycles complete",
        cycle_ok,
        "a cycle failed to start, handshake or stop",
    );
    b.check(
        "100 start/stop cycles leave the host descriptor table at baseline",
        after <= baseline,
        format!("host fds {baseline} -> {after} (peak {peak}) — one leak per handshake is +100"),
    );

    // The other half, and the sharper one. A leaked descriptor is a resource
    // bug; a STALE NUMBER is a correctness bug, because closing it closes
    // whatever the kernel has since handed that number to.
    {
        let r = carrier::spawn(&fixture, &dir, &dir.join("reuse.log"), &crate::new_epoch(), None);
        match r {
            Ok(mut c) => {
                let hs = c.handshake(5_000).is_ok();
                // The control endpoint must still work AFTER the handshake.
                // Under the old shape the reader thread had already closed it.
                let alive = c.speak("IDENT", 2_000).is_ok();
                c.terminate(2_000);
                // Take the numbers the Carrier used, then prove terminating a
                // second time cannot close them again.
                let probe = std::fs::File::open("/etc/hostname").ok();
                let second = c.terminate(2_000);
                b.check(
                    "the control endpoint survives its own handshake",
                    hs && alive,
                    format!("handshake={hs} ident={alive}"),
                );
                b.check(
                    "terminating twice cannot close a descriptor the host has since reused",
                    probe.as_ref().map(|f| {
                        use std::os::fd::AsRawFd;
                        crate::fdpass::fd_state(f.as_raw_fd()) != crate::fdpass::FdState::Closed
                    }).unwrap_or(false) && second,
                    "a second terminate closed an unrelated reused descriptor",
                );
            }
            Err(e) => b.check("the fd-reuse falsifier could run", false, e),
        }
    }

    // ------------------------------------ D.1.3b·2a · replacement ownership
    //
    // b·1 proved one Carrier's descriptor table. That does not compose: the
    // handshake leak was invisible to it precisely because it was one-shot.
    {
        let mut a = carrier::spawn(&fixture, &dir, &dir.join("A.log"), &crate::new_epoch(), None).ok();
        let a_inode = a.as_ref().and_then(|c| c.control_inode());
        if let Some(c) = a.as_mut() { let _ = c.handshake(5_000); c.terminate(2_000); }
        drop(a);

        let mut bcar = carrier::spawn(&fixture, &dir, &dir.join("B.log"), &crate::new_epoch(), None).ok();
        let b_inode = bcar.as_ref().and_then(|c| c.control_inode());
        let b_fds = bcar.as_ref().map(|c| c.observe().fds).unwrap_or_default();
        if let Some(c) = bcar.as_mut() { c.terminate(2_000); }

        b.check(
            "a replacement Carrier gets a control endpoint that is not its predecessor's",
            a_inode.is_some() && b_inode.is_some() && a_inode != b_inode,
            format!("A inode {a_inode:?} · B inode {b_inode:?}"),
        );
        b.check(
            "a replacement Carrier inherits no descriptor from the one it replaced",
            b_fds.keys().copied().collect::<Vec<i32>>() == vec![0, 1, 2, 3]
                && !b_fds.values().any(|t| crate::socket_inode(t) == a_inode),
            format!("{b_fds:?}"),
        );
    }

    // ------------------------------- D.1.3b·2a · the host cannot orphan them
    //
    // `serve_carrier` reaps its map when the lifecycle channel closes, and
    // `Carrier::drop` covers every in-process path — neither runs on SIGKILL.
    // PR_SET_PDEATHSIG is what makes the kernel do it instead.
    {
        let r = carrier::spawn(&fixture, &dir, &dir.join("pd.log"), &crate::new_epoch(), None);
        match r {
            Ok(mut c) => {
                let hs = c.handshake(5_000).is_ok();
                let pid = c.pid;
                // **This was a vacuous check and is now two honest ones.**
                //
                // The first version asserted that `/proc/<pid>/status` has a
                // `PPid:` line, which is true of every process that has ever
                // existed. It could not fail.
                //
                // There is no `/proc` field for `PR_SET_PDEATHSIG` — like
                // Landlock, it is set by the host and is not readable from
                // outside the process it was set on. So it is **attested**,
                // and the honest checks are: the child is really our child
                // (which is what makes the signal reach it), and the host
                // says it armed it. The behavioural proof that the
                // attestation corresponds to something needs a sacrificial
                // intermediate parent and is recorded as an open gap.
                let is_our_child = std::fs::read_to_string(format!("/proc/{pid}/status"))
                    .and_then(|s| {
                        s.lines()
                            .find(|l| l.starts_with("PPid:"))
                            .and_then(|l| l.split_whitespace().nth(1))
                            .and_then(|v| v.parse::<u32>().ok())
                            .ok_or_else(|| std::io::Error::other("no PPid"))
                    })
                    .map(|ppid| ppid == std::process::id())
                    .unwrap_or(false);
                c.terminate(2_000);
                b.check(
                    "the Carrier is a direct child of this host, so a parent-death signal reaches it",
                    hs && is_our_child,
                    format!("the carrier's PPid is not this process ({})", std::process::id()),
                );
                b.check(
                    "PR_SET_PDEATHSIG is ATTESTED, not observed — no /proc field exposes it",
                    true,
                    String::new(),
                );
            }
            Err(e) => b.check("the parent-death falsifier could run", false, e),
        }
    }

    // --------- D.1.3b·2b · the payload cannot cut its own death binding
    //
    // `prctl(PR_SET_PDEATHSIG, 0)` clears the parent-death signal. Today's
    // fixture never calls it; a PTY or Motor payload can, and would then
    // survive the host it is bound to — undoing the mechanism the check below
    // proves. Argument-aware seccomp refuses exactly that option while
    // leaving `PR_GET` and every other `prctl` alone.
    //
    // This is the one property where the payload IS the right witness. The
    // question is not "is the binding set" — the host attests that, and the
    // sacrificial-parent check proves it — but "can the payload cut it", and
    // only the payload can attempt that.
    {
        let g = row("prctl_get_pdeathsig");
        let c = row("prctl_clear_pdeathsig");
        b.check(
            "a confined Carrier sees SIGKILL as its parent-death signal",
            matches!(g.confined, Some((true, 9))),
            format!("confined={:?} (expected ALLOWED with value 9)", g.confined),
        );
        b.check(
            "a confined Carrier cannot clear its parent-death signal — ATTRIBUTED",
            matches!(c.confined, Some((false, e)) if e as u32 == confine::SUPER_DENY_ERRNO),
            format!("confined={:?}, expected errno {}", c.confined, confine::SUPER_DENY_ERRNO),
        );
        b.check(
            "and the bare control CAN clear it — DIFFERENTIAL",
            matches!(c.bare, Some((true, _))),
            format!("bare={:?} — without this the refusal above is unattributable", c.bare),
        );
    }

    // ------------------------ D.1.3b·2b · the host cannot orphan a Carrier
    //
    // Attested is not proved. There is no `/proc` field for
    // `PR_SET_PDEATHSIG`, so the only way to show the binding works is to
    // kill a parent and watch the child go. A sacrificial intermediate host
    // does that without touching the real one.
    {
        use std::process::{Command, Stdio};
        use std::io::BufRead as _;
        let exe = std::env::current_exe()
            .unwrap_or_else(|_| std::path::PathBuf::from("super-host"));
        let child = Command::new(&exe)
            .arg("carrier-orphan-fixture")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();

        match child {
            Ok(mut inter) => {
                let line = inter
                    .stdout
                    .take()
                    .map(|o| {
                        let mut s = String::new();
                        let _ = std::io::BufReader::new(o).read_line(&mut s);
                        s
                    })
                    .unwrap_or_default();

                let parts: Vec<&str> = line.split_whitespace().collect();
                let cpid: Option<u32> = parts.first().and_then(|v| v.parse().ok());
                let cstart: Option<u64> = parts.get(1).and_then(|v| v.parse().ok());

                let alive_before = cpid
                    .map(|p| carrier::observe(p).starttime == cstart)
                    .unwrap_or(false);

                // SIGKILL: no destructor, no serve-loop cleanup, no Drop.
                // Exactly what a crashed host does.
                let _ = inter.kill();
                let _ = inter.wait();

                let mut gone = false;
                for _ in 0..50 {
                    if cpid.map(|p| carrier::observe(p).starttime != cstart).unwrap_or(false) {
                        gone = true;
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }

                b.check(
                    "a sacrificial host really started a Carrier",
                    alive_before,
                    format!("line {line:?}"),
                );
                b.check(
                    "SIGKILLing the host kills its Carrier — PR_SET_PDEATHSIG, proved not attested",
                    gone,
                    format!("carrier pid {cpid:?} survived its host being killed"),
                );
            }
            Err(e) => b.check("the orphan falsifier could run", false, e.to_string()),
        }
    }

    // The policy must still be a policy and not a wall.
    let w = row("write_own_workdir");
    b.check(
        "the Carrier can still write its own working directory",
        matches!(w.confined, Some((true, _))),
        format!("confined={:?}", w.confined),
    );
}

/// A git repository with one commit, for the production effect path to
/// create a worktree from.
fn init_fixture_repo(dir: &Path) -> bool {
    use std::process::Command;
    let _ = std::fs::write(dir.join("README"), "d13a\n");
    let steps: &[&[&str]] = &[
        &["init", "-q", "-b", "main"],
        &["config", "user.email", "d13a@example.invalid"],
        &["config", "user.name", "D13a"],
        &["config", "commit.gpgsign", "false"],
        &["add", "-A"],
        &["commit", "-q", "-m", "init"],
    ];
    for args in steps {
        let ok = Command::new("git")
            .arg("-C").arg(dir).args(*args)
            .output().map(|o| o.status.success()).unwrap_or(false);
        if !ok { return false; }
    }
    true
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
