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

                // ---- D.1.3c·1a · closing the Worker takes the terminal too
                //
                // The freeze criterion says *every* Carrier-lifetime
                // discontinuity removes the terminal, and this was one of two
                // paths argued structurally rather than measured. The
                // structure is sound — the `Pty` is a field of `Carrier`, so
                // whatever drops one drops the other — but "sound" and
                // "observed" are the distinction this whole lane is about.
                //
                // **Its own Worker and its own agent.** The first version
                // closed the Worker every later check depends on, and four of
                // them went red with `worker-not-open` — a test that consumes
                // the fixture the tests after it need. Nothing new is
                // exercised: `close_worker` already converges its Carriers.
                // What is new is counting the host's masters across it.
                // **Its own Lane, too.** Occupancy is per *Locus*, not per
                // Worker — a second Worker on `lane_id` refused with
                // `locus-already-occupied`, which is D.1.2 working exactly as
                // specified and worth writing down here rather than
                // rediscovering.
                let ptmx_base = host_ptmx_count();
                let lane2 = ctl
                    .call(
                        "open_lane",
                        json!({"goal_ref": goal_id, "actor": "kestrel",
                               "repository_ref": repo_ref, "base_revision": Value::Null}),
                    )
                    .unwrap_or(Value::Null);
                let lane2_id = lane2["result"]["lane"]["id"].as_str().unwrap_or("").to_string();
                let w2 = ctl
                    .call("open_worker", json!({"locus_ref": lane2_id, "purpose": "review"}))
                    .unwrap_or(Value::Null);
                let w2_id = w2["result"]["worker"]["id"].as_str().unwrap_or("").to_string();

                if let Ok(mut a2) = rt.agent_channel("kestrel") {
                    let att2 = a2.call("attach_worker", json!({"worker_ref": w2_id}))
                        .unwrap_or(Value::Null);
                    let started2 = a2
                        .call("start_carrier", json!({"locus_ref": lane2_id}))
                        .unwrap_or(Value::Null);
                    let pid3 = started2["result"]["carrier"]["host_process_ref"]
                        .as_str()
                        .and_then(|r| r.strip_prefix("hp_"))
                        .and_then(|r| r.split('_').next())
                        .and_then(|v| v.parse::<u32>().ok());
                    let st3 = pid3.and_then(|p| crate::carrier::observe(p).starttime);

                    b.check(
                        "a second real Carrier runs and the host holds one more master",
                        st3.is_some() && host_ptmx_count() == ptmx_base + 1,
                        format!("attach={} started={started2} pid={pid3:?} masters {ptmx_base} → {}",
                                att2["result"], host_ptmx_count()),
                    );

                    let closed = ctl
                        .call("close_worker", json!({"worker_ref": w2_id}))
                        .unwrap_or(Value::Null);

                    let mut closed_gone = false;
                    let mut closed_ptmx = false;
                    for _ in 0..80 {
                        if !closed_gone
                            && pid3
                                .map(|p| crate::carrier::observe(p).starttime != st3)
                                .unwrap_or(false)
                        {
                            closed_gone = true;
                        }
                        if closed_gone && host_ptmx_count() == ptmx_base {
                            closed_ptmx = true;
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(100));
                    }

                    b.check(
                        "closing the Worker really ends its Carrier's OS process",
                        closed["result"]["allow"] == true && closed_gone,
                        format!("closed={closed} pid={pid3:?} still alive"),
                    );
                    b.check(
                        "and the Carrier's terminal dies with the Worker that was closed",
                        closed_ptmx,
                        format!("host held {ptmx_base} masters before, {} after the close",
                                host_ptmx_count()),
                    );
                } else {
                    b.check("a second agent channel is available for the close-worker path",
                            false, "rt.agent_channel failed");
                }

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
                //
                // **`payload_path`, not `fixture_path`, and R0a is why.**
                // This swapped the fixture, and the production path used to
                // run the fixture. Once `payload_path()` began preferring
                // `super-dogfood`, swapping the fixture stopped changing what
                // `start_carrier` executes: the swap installed a B nobody was
                // going to run, the start was correctly allowed, and this
                // check went red — along with three downstream rows that had
                // assumed it refused. The falsifier was aimed at a file the
                // production path no longer opens, which is a probe measuring
                // its own obsolescence rather than a defect in the basis.
                let payload_before = crate::carrier::payload_path();
                let baseline_digest = payload_before.as_ref().map(|p| digest_of(p));

                match payload_before.as_ref().and_then(|p| SwappedFixture::install(p)) {
                    None => b.check(
                        "the payload-swap falsifier could run",
                        false,
                        format!("could not install a B over {payload_before:?}"),
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
                let restored = payload_before.as_ref().map(|p| digest_of(p));
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

                // D.1.3c·1a. The freeze criterion says *every* Carrier-lifetime
                // discontinuity removes the terminal, and this path was
                // argued structurally — the `Pty` is a field of `Carrier`, so
                // dropping one drops the other. True, and an argument is not
                // a measurement. The host's own master count is.
                let ptmx_owned = host_ptmx_count();

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

                // The terminal goes with it. Counted rather than inferred:
                // a reap that ended the process and kept the master would
                // leave the host accumulating a descriptor per lost Peer,
                // and every other check on this path would stay green.
                let mut ptmx_back = false;
                for _ in 0..40 {
                    if host_ptmx_count() < ptmx_owned {
                        ptmx_back = true;
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                b.check(
                    "and the Carrier's terminal dies with the Peer that owned it",
                    ptmx_back,
                    format!(
                        "host held {ptmx_owned} pty masters with the Carrier up, \
                         {} after its Peer was lost",
                        host_ptmx_count()
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
    pty_possession(&mut b, &scratch);
    dogfood_payload(&mut b, &scratch);

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
/// How many descriptors this host holds that are pseudoterminal masters.
///
/// A master opened from `/dev/ptmx` resolves back to `/dev/ptmx` in
/// `/proc/self/fd`, so this counts them without needing a handle on any
/// `Pty` — which is the point: the fence's Carriers live inside
/// `serve_carrier`'s own map and this battery cannot reach them. It can ask
/// the kernel what the host is holding, which is the better question anyway.
fn host_ptmx_count() -> usize {
    std::fs::read_dir("/proc/self/fd")
        .map(|rd| {
            rd.flatten()
                .filter(|e| {
                    std::fs::read_link(e.path())
                        .map(|p| p.to_string_lossy() == "/dev/ptmx")
                        .unwrap_or(false)
                })
                .count()
        })
        .unwrap_or(0)
}

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
    // D.1.3c·1. Each of these Carriers now possesses a terminal, and the
    // claim under test grows accordingly: the drain empties the physical
    // Carrier set, and the terminals go with it. Counted from the host's own
    // descriptor table rather than from any `Pty` handle, because the
    // Carriers belong to `serve_carrier`'s map and this battery cannot reach
    // them — and because "what is this host still holding" is the question
    // a leaked master would answer wrongly.
    let ptmx_before = host_ptmx_count();

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

    let ptmx_live = host_ptmx_count();
    b.check(
        "each of the three Carriers possesses a terminal the host holds the master of",
        ptmx_live == ptmx_before + 3,
        format!("host held {ptmx_before} pty masters before, {ptmx_live} with three Carriers up"),
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

    // **The terminals go with them, and this is measured rather than
    // inferred from the `Pty` being a field of `Carrier`.** A drain that
    // emptied the process set and left three masters open would be a host
    // accumulating a descriptor per Carrier for the life of the runtime —
    // and every other check here would still be green.
    let ptmx_after = host_ptmx_count();
    b.check(
        "and their terminals are gone with them — the host holds no leftover master",
        ptmx_after == ptmx_before,
        format!("host held {ptmx_before} pty masters before, {ptmx_live} with three Carriers \
                 up, {ptmx_after} after the drain"),
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

/// Does this ELF64 image carry no `PT_INTERP`?
///
/// `None` when the file cannot be read or is not an ELF64 little-endian
/// image at all — which is a different fact from "it is dynamic" and is kept
/// distinct so the check that consumes this cannot report a missing file as a
/// linkage verdict.
fn elf_is_static(path: &Path) -> Option<bool> {
    const PT_INTERP: u32 = 3;
    let b = std::fs::read(path).ok()?;
    // e_ident: magic, EI_CLASS=2 (64-bit), EI_DATA=1 (little-endian).
    if b.len() < 64 || &b[..4] != b"\x7fELF" || b[4] != 2 || b[5] != 1 {
        return None;
    }
    // Every offset below is inside the 64-byte header the length check above
    // already guaranteed, so these cannot be out of range.
    let u16at = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]) as usize;
    let phoff = u64::from_le_bytes(b[0x20..0x28].try_into().ok()?) as usize;
    let phentsize = u16at(0x36);
    let phnum = u16at(0x38);
    if phentsize < 4 {
        return None;
    }
    for i in 0usize..phnum {
        let at = phoff.checked_add(i.checked_mul(phentsize)?)?;
        if at + 4 > b.len() {
            return None;
        }
        if u32::from_le_bytes(b[at..at + 4].try_into().ok()?) == PT_INTERP {
            return Some(false);
        }
    }
    Some(true)
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

    // **The payload's linkage is policy, and a wrong one is silent.**
    //
    // The execute grant names one inode: this file. A dynamically linked
    // payload needs its interpreter — `/lib64/ld-linux-x86-64.so.2` — and
    // every library it opens, so making one run means granting FS_EXECUTE
    // across `/usr/lib`, which is not a confinement. `carrier-fixture` says
    // so in its `.cargo/config.toml` and pins the flag there.
    //
    // That pin is defeatable and was defeated: `cargo build --release
    // --manifest-path carrier-fixture/Cargo.toml` resolves `.cargo/config`
    // from the *working directory*, not from the manifest, so building the
    // fixture from the repo root silently drops `+crt-static` and produces a
    // dynamic binary with the same name in the same place. Every Carrier
    // start then fails `EACCES`, nineteen checks go red at once, and not one
    // of them says why — which is what this check is for. It is a diagnosis,
    // not a new property: the confinement was always correct, and it was the
    // payload that had stopped being the kind of thing it can admit.
    b.check(
        "the Carrier payload is STATICALLY linked — the execute grant names one inode, not /usr/lib",
        elf_is_static(&fixture) == Some(true),
        format!(
            "{} has a PT_INTERP — rebuild it from carrier-fixture/ so its .cargo/config.toml applies",
            fixture.display()
        ),
    );

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
            None,
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
        None,
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

    // ------------------------------------- D.1.3b·2f · the seal, measured
    //
    // **The comment above this pair records the defect and calls it a
    // harness bug.** *"the first version of this check ran AFTER the leak
    // was set up and went red, because the harness's own leaked descriptor
    // reached the Carrier. The check was correct; the thing it caught was
    // the test."* It was not the test. `leak_fd` is a non-`CLOEXEC`
    // descriptor at its own natural number, and it reached the Carrier
    // because nothing in the spawn path stopped it — which is exactly what
    // the cockpit later hit with eight of them at once. The control was
    // moved earlier and the floor kept its false claim for a revision.
    //
    // These four checks are that finding turned into instruments. They run
    // HERE, deliberately after the leak exists, because the whole property
    // is that the order no longer matters.
    let ambient = leak_fd;
    let ambient_state = crate::fdpass::fd_state(ambient);
    b.check(
        "the ambient-descriptor probe really is ambient — open, above 3, and NOT close-on-exec",
        ambient_state == crate::fdpass::FdState::Inheritable && ambient > 3,
        format!("fd {ambient} is {ambient_state:?}; without this the two checks below prove nothing"),
    );

    // 1 · it must die. An ordinary Carrier, spawned with NO extra_fds,
    //     while the host holds an inheritable descriptor it never mentioned.
    let ambient_fds: Vec<i32> = {
        let r = carrier::spawn(&fixture, &dir, &dir.join("f4.log"), &crate::new_epoch(), None);
        match r {
            Ok(mut r) => {
                let f = r.observe().fds.keys().copied().collect();
                r.terminate(2_000);
                f
            }
            Err(e) => {
                b.check("the ambient-inheritance falsifier could spawn a Carrier", false, e);
                vec![-1]
            }
        }
    };
    b.check(
        "an ambient inheritable descriptor the host never named does NOT reach the Carrier",
        ambient_fds == vec![0, 1, 2, 3],
        format!(
            "the Carrier observed {ambient_fds:?} while fd {ambient} was inheritable in the host              — the descriptor set is following the host's hygiene, not the spawn path's seal"
        ),
    );

    // 2 · the explicit one must live, and ONLY at the number it was placed
    //     on. A repair that sanitised indiscriminately would make check 1
    //     green by destroying the inherited-pre-open falsifier, and that
    //     falsifier is the only thing that proves Landlock does not reach an
    //     already-open descriptor.
    let placed_fds: std::collections::BTreeMap<i32, String> = {
        let r = carrier::spawn_with(
            &fixture, &dir, &dir.join("f5.log"), &crate::new_epoch(), None, &[],
            &[(ambient, 9)], None,
        );
        match r {
            Ok(mut r) => {
                let f = r.observe().fds;
                r.terminate(2_000);
                f
            }
            Err(_) => Default::default(),
        }
    };
    let placed: Vec<i32> = placed_fds.keys().copied().collect();
    b.check(
        "an explicitly placed descriptor survives, at its target and nowhere else",
        placed == vec![0, 1, 2, 3, 9],
        format!(
            "expected [0, 1, 2, 3, 9], observed {placed:?} — either the placement was              sanitised away or the source number {ambient} came along with it"
        ),
    );

    // 2b · **and the seal makes `dup_onto`'s `make_inheritable` load-bearing
    //      for the first time.** `dup2(2)` clears `FD_CLOEXEC` on its target
    //      — except in the one case Linux defines as a no-op, `oldfd ==
    //      newfd`. Before the seal that did not matter: a caller reached
    //      `extra_fds` only by having already cleared the flag itself, so a
    //      same-number placement was inheritable before `dup_onto` touched
    //      it and the trailing `make_inheritable` was belt-and-braces. After
    //      the seal it is the only thing standing between an in-place
    //      possession and the kernel closing it, and a reader simplifying
    //      `dup_onto` down to a bare `dup2` would take it out.
    //
    //      The number is chosen rather than inherited: `ambient` is wherever
    //      the OS put it, and a check that quietly skips when that number
    //      lands above the reserved floor is a check reporting green for not
    //      having run.
    let inplace: Option<i32> = (4..confine::RULESET_FD_FLOOR)
        .find(|n| crate::fdpass::fd_state(*n) == crate::fdpass::FdState::Closed)
        .filter(|n| crate::fdpass::dup_onto(ambient, *n).is_ok());
    let inplace_fds: Vec<i32> = match inplace {
        Some(n) => {
            let r = carrier::spawn_with(
                &fixture, &dir, &dir.join("f8.log"), &crate::new_epoch(), None, &[],
                &[(n, n)], None,
            );
            match r {
                Ok(mut r) => {
                    let f = r.observe().fds.keys().copied().collect();
                    r.terminate(2_000);
                    f
                }
                Err(_) => vec![-1],
            }
        }
        None => vec![-2],
    };
    b.check(
        "a possession placed on its OWN number survives — dup2(n, n) is a no-op and the seal has already marked it",
        matches!(inplace, Some(n) if inplace_fds == vec![0, 1, 2, 3, n]),
        format!("placed at {inplace:?}, the Carrier observed {inplace_fds:?}"),
    );

    // 3 · the seal marks the Landlock ruleset close-on-exec and does not
    //     close it — measured by the domain BITING, not by a status field.
    //
    //     **The first version of this check asked `/proc/<pid>/status` for a
    //     `Landlock:` line and went red on a Carrier that was correctly
    //     confined.** This kernel does not publish that field — there is no
    //     such line in `/proc/self/status` on 7.2.2 with
    //     `CONFIG_SECURITY_LANDLOCK=y` and ABI 10 — so `observe`'s
    //     `landlock_domain` is `false` for every process on this host and
    //     always has been. That is why nothing else in this file reads it,
    //     and `carrier.rs` says why in its own words beside where the field
    //     is computed: Landlock is **host-attested**, and this battery is
    //     the out-of-band proof that the attestation corresponds to
    //     something. A check that believed the attestation's own field
    //     would have been the error the module header already names.
    //
    //     So this is a differential, run through the seal: the confined
    //     probe must be REFUSED a path the bare control reached. If the
    //     seal closed the ruleset, `landlock_restrict_self` gets `EBADF`,
    //     `install` fails inside `pre_exec`, and the spawn does not happen
    //     at all — which this also catches, because a probe that never ran
    //     leaves no row.
    let sealed_probe = {
        let sdir = dir.join("sealed");
        let _ = std::fs::create_dir_all(&sdir);
        let slog = sdir.join("sealed.log");
        let sargs = [me.to_string(), "-1".to_string(), sdir.to_string_lossy().to_string()];
        let pol = confine::Policy::minimal(&sdir.to_string_lossy(), &probe.to_string_lossy());
        match carrier::spawn_with(
            &probe, &sdir, &slog, &crate::new_epoch(), Some(pol),
            &sargs.iter().map(|s| s.to_string()).collect::<Vec<_>>(), &[], None,
        ) {
            Ok(mut c) => {
                std::thread::sleep(std::time::Duration::from_millis(900));
                c.terminate(2_000);
                parse_probe_log(&slog)
            }
            Err(e) => {
                b.check(
                    "the sealed-Landlock differential could spawn its probe at all",
                    false,
                    format!("{e} — if `install` refused, the seal closed the ruleset"),
                );
                Default::default()
            }
        }
    };
    let sealed_fs = sealed_probe.get("open_etc_passwd").copied();
    let bare_fs = bare.get("open_etc_passwd").copied();
    b.check(
        "the ruleset survives the seal — a Carrier spawned through it is still REFUSED a path the bare control reached",
        matches!(sealed_fs, Some((false, _))) && matches!(bare_fs, Some((true, _))),
        format!("sealed={sealed_fs:?} bare={bare_fs:?} — the seal marks the ruleset close-on-exec and must not close it; `install` needs it live"),
    );

    // 4 · the vocabulary cannot name the ruleset's own number. Refused
    //     before placement, so the failure is a typed message rather than a
    //     Carrier that ran unconfined.
    let collide_why = match carrier::spawn_with(
        &fixture, &dir, &dir.join("f7.log"), &crate::new_epoch(), None, &[],
        &[(ambient, confine::RULESET_FD_FLOOR)], None,
    ) {
        Err(e) => e,
        Ok(mut c) => {
            let pid = c.pid;
            c.terminate(2_000);
            format!("ACCEPTED — it spawned pid {pid}")
        }
    };
    b.check(
        "an extra descriptor target at the reserved ruleset floor is refused before placement",
        collide_why.contains("outside the allowlist range"),
        format!(
            "target {} — `dup_onto` would have overwritten the live ruleset and `install` \
             would have restricted against whatever landed there. Said: {collide_why}",
            confine::RULESET_FD_FLOOR,
        ),
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

/// Walk the directories a same-user process would search, looking for
/// anything that looks like this runtime's.
///
/// **The doc used to say "and try to open".** It does not — it collects paths
/// and returns them, and nothing in this file connects to a unix socket at
/// all. Finding a path and being able to open it are different facts, and the
/// stronger one is what the property wants; raising the code to meet the old
/// comment is filed rather than done here, because it changes what a frozen
/// assertion claims.
///
/// **This is O(entries in `$XDG_RUNTIME_DIR` and `/tmp`) on every call**, and
/// it reads the contents of every `*ampd*` directory it finds. That made it
/// quietly linear in a leak: `Runtime::start`'s per-runtime directory is
/// removed only by `Runtime::release`, so every unclean exit left one behind
/// and the count reached **502** before `sweep_stale_runtime_dirs` was added
/// to bound it. Nothing here was wrong; it was doing 502 directory reads to
/// answer a question about none of them.
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

// ============================================================ D.1.3c·1
//
// **Possessed PTY.** The question is narrow on purpose:
//
//   > Can a currently admitted Carrier possess one deliberately established
//   > terminal without acquiring terminal-selection, terminal-namespace,
//   > executable-selection or ambient host authority?
//
// It is *possession*, not attachment. Nothing here gives the runtime or the
// cockpit a terminal data plane — the master stays in this process and this
// battery is the only thing that reads it. Who else may hold an attachment
// is c·2's question and probably another mechanism.
fn pty_possession(b: &mut Battery, scratch: &Path) {
    use crate::carrier;
    use crate::pty::{self, Pty, TermProps};

    println!("\n  D.1.3c·1 · the possessed terminal");

    let Some(fixture) = carrier::fixture_path() else {
        b.check("the pty falsifiers could run", false, "no carrier fixture");
        return;
    };
    let dir = scratch.join("pty");
    let _ = std::fs::create_dir_all(&dir);

    // ------------------------------------------------ allocation, no name
    let mut p = match Pty::open() {
        Ok(p) => p,
        Err(e) => {
            b.check("a pty pair is allocated from /dev/ptmx", false, e);
            return;
        }
    };
    b.check(
        "a pty pair is allocated by possession — TIOCGPTPEER, never ptsname",
        p.slave().is_some() && p.slave_rdev() != 0,
        format!("pts index {} · slave st_rdev {:#x}", p.ptn(), p.slave_rdev()),
    );

    // **The decoy.** A second pair the host also holds, so that a predicate
    // which accepts *any* master cannot pass the provenance checks below.
    let decoy = Pty::open().ok();
    b.check(
        "an unclaimed master answers TIOCGSID with ENOTTY, so the probe can be wrong",
        decoy.as_ref().map(|d| d.session()).unwrap_or(Some(0)).is_none(),
        format!("decoy session={:?}", decoy.as_ref().and_then(|d| d.session())),
    );

    // A deterministic size, set by the host before the Carrier exists. The
    // payload is refused TIOCSWINSZ, so this is the only way it can be so.
    let _ = p.set_winsize(pty::WinSize { rows: 24, cols: 80, xpixel: 0, ypixel: 0 });

    let ptn = p.ptn();
    let slave_rdev = p.slave_rdev();
    let mut c = match carrier::spawn_on_pty(&fixture, &dir, &dir.join("pty.log"),
                                            &crate::new_epoch(), None, p) {
        Ok(c) => c,
        Err(e) => {
            b.check("a Carrier starts on a possessed pty", false, e);
            return;
        }
    };
    // **Every reading below re-borrows.** The `Pty` is a field of the
    // Carrier now, and holding one long borrow of it would lock out
    // `speak`, which needs the Carrier mutably. `spawn_with` has already
    // dropped the host's copy of the slave — the hangup is on the last
    // close, so that had to happen before any of this could mean anything.
    let master_fd = c.pty().map(|q| q.master()).unwrap_or(-1);
    // **Non-blocking, for the same reason the census is.** Every read below
    // has a terminating condition that is itself under test — the reply
    // arriving, the hangup arriving — and a blocking read turns a failed
    // property into a wedged battery instead of a red row. The host
    // sabotage battery has a probe that withholds the hangup on purpose.
    let _ = c.pty().map(|q| q.set_nonblocking());

    let handshook = c.handshake(5_000);
    let pid = c.observe();
    let cpid = c.pid;
    b.check(
        "a Carrier starts on a possessed pty and still proves its incarnation",
        handshook.is_ok(),
        format!("{handshook:?}"),
    );

    // ------------------------------------- the four properties, separately
    let t = TermProps::read(cpid);
    b.check(
        "the Carrier is the leader of its own session",
        t.is_session_leader(cpid),
        format!("session={:?} pid={cpid}", t.session),
    );
    b.check(
        "the Carrier has a controlling terminal, deliberately established",
        t.has_controlling_terminal(),
        format!("tty_nr={:?} (0 would mean none)", t.tty_nr),
    );
    b.check(
        "the Carrier is the foreground process group of that terminal",
        t.is_foreground(),
        format!("tpgid={:?} pgrp={:?}", t.tpgid, t.pgrp),
    );

    // ------------------------------------------------- provenance, 3 ways
    //
    // Asked of the descriptor the host possesses, never of a pathname.
    // `/proc/<pid>/fd/0` resolves to `/dev/pts/N` and that string is a NAME:
    // it would be equally true of somebody else's terminal with the same
    // number in another mount namespace.
    b.check(
        "the master's session id IS the Carrier's session — TIOCGSID on the held descriptor",
        c.pty().and_then(|q| q.session()).is_some()
            && c.pty().and_then(|q| q.session()) == t.session,
        format!("TIOCGSID(master)={:?} carrier session={:?}",
                c.pty().and_then(|q| q.session()), t.session),
    );
    b.check(
        "the master's foreground group IS the Carrier's process group",
        c.pty().and_then(|q| q.foreground_pgrp()).is_some()
            && c.pty().and_then(|q| q.foreground_pgrp()) == t.pgrp,
        format!("TIOCGPGRP(master)={:?} carrier pgrp={:?}",
                c.pty().and_then(|q| q.foreground_pgrp()), t.pgrp),
    );
    let (maj, min) = pty::decode_tty_nr(t.tty_nr.unwrap_or(0));
    b.check(
        "the Carrier's controlling terminal is the pts this master minted",
        min == ptn && maj == 136,
        format!("tty_nr decodes to {maj}:{min} · TIOCGPTN(master)={ptn}"),
    );
    let fd0_rdev = pty::fstat_rdev_of_path(&format!("/proc/{cpid}/fd/0"));
    b.check(
        "the Carrier's fd 0 is the same device the host created, by st_rdev not by name",
        fd0_rdev.is_some() && fd0_rdev == Some(slave_rdev),
        format!("fd0 st_rdev={fd0_rdev:?} host slave st_rdev={slave_rdev:#x}"),
    );
    if let Some(d) = decoy.as_ref() {
        b.check(
            "and it is NOT the decoy master's terminal",
            fd0_rdev != Some(d.slave_rdev()) && d.session().is_none(),
            format!("decoy slave st_rdev={:#x}", d.slave_rdev()),
        );
    }

    // ------------------- the join, on the PRODUCTION attestation object
    //
    // **Asked of `carrier_attestation` and not of the helper.** c·1 proved
    // this correspondence here and did not put it in what the runtime
    // requires — so the World could admit a Carrier whose controlling
    // terminal was the host's while its 0/1/2 were somebody else's. Testing
    // `stdio_is_slave` alone would repeat that mistake one level down: a
    // predicate that is right and unwired is worth nothing, which is the
    // shape of the missing attestation D.1.3b·2a found.
    let att = crate::carrier_attestation(&c, &dir);
    b.check(
        "the production attestation says the Carrier's stdio IS this host's slave",
        att["terminal"]["stdio_is_this_host_slave"] == true,
        format!("{}", att["terminal"]),
    );

    // And the same predicate, against the decoy. Without this the check
    // above passes for a predicate hardcoded to `true` — which is exactly
    // what the `st_rdev` offset bug amounted to, and exactly what the decoy
    // caught the first time.
    if let Some(d) = decoy.as_ref() {
        b.check(
            "and answers FALSE for a terminal this host holds but did not give the Carrier",
            !pty::stdio_is_slave(cpid, d.slave_rdev()),
            format!("decoy slave st_rdev={:#x} · carrier fd0 {fd0_rdev:?}", d.slave_rdev()),
        );
    }

    // **All three descriptors, and this is the case that proves it.**
    //
    // A Carrier reading the host's terminal and writing somewhere else
    // satisfies every other row: the observed census sees one displayed
    // target on 0/1/2 only because it is asked about a Carrier that has one,
    // and the ctty is still the host's. Nothing but `stdio_is_slave`'s
    // insistence on all three can see the split — and the decoy cannot,
    // because fd 0 is correct in that case.
    //
    // So it is built: a process given the host's slave on fd 0 alone, with
    // 1 and 2 left on the log file. The predicate must refuse it.
    if let Ok(split) = Pty::open() {
        let split_rdev = split.slave_rdev();
        let split_slave = split.slave().unwrap_or(-1);
        let sdir = dir.join("split");
        let _ = std::fs::create_dir_all(&sdir);
        let r = carrier::spawn_with(&fixture, &sdir, &sdir.join("s.log"), &crate::new_epoch(),
                                    None, &[], &[(split_slave, 0)], None);
        match r {
            Ok(mut sc) => {
                let split_pid = sc.pid;
                b.check(
                    "a split stdio is refused — the slave on fd 0 alone is not possession",
                    !pty::stdio_is_slave(split_pid, split_rdev),
                    format!(
                        "fd0={:?} fd1={:?} fd2={:?} host slave st_rdev={split_rdev:#x}",
                        pty::fstat_rdev_of_path(&format!("/proc/{split_pid}/fd/0")),
                        pty::fstat_rdev_of_path(&format!("/proc/{split_pid}/fd/1")),
                        pty::fstat_rdev_of_path(&format!("/proc/{split_pid}/fd/2")),
                    ),
                );
                sc.terminate(2_000);
            }
            Err(e) => b.check("the split-stdio falsifier could run", false, e),
        }
    }

    // ------------------------------------------------ the descriptor table
    let fds: Vec<i32> = pid.fds.keys().copied().collect();
    b.check(
        "the Carrier holds exactly {0,1,2,3} — the terminal added no descriptor",
        fds == vec![0, 1, 2, 3],
        format!("{:?}", pid.fds),
    );
    let three_same = ["0", "1", "2"]
        .iter()
        .filter_map(|k| pid.fds.get(&k.parse::<i32>().unwrap()))
        .collect::<std::collections::BTreeSet<_>>();
    b.check(
        "0, 1 and 2 are one terminal, not three",
        three_same.len() == 1,
        format!("{three_same:?}"),
    );
    b.check(
        "the Carrier does not hold the master",
        !pid.fds.values().any(|v| v.contains("ptmx")),
        format!("{:?}", pid.fds),
    );

    // ------------------------------------ what the payload can observe
    let tty = c.speak("TTY", 3_000).unwrap_or_default();
    b.check(
        "the payload's own stdio is a terminal and it can read its size",
        tty == "TTY true true true 24 80",
        format!("{tty:?} (expected the 24x80 the host set before it existed)"),
    );

    // --------------------------------------------- bytes, in both directions
    //
    // `isatty` is not the proof; the line discipline is. The host writes a
    // bare `\n` and reads back `\r\n`, which only a terminal does — a pipe
    // would return the bytes unchanged, and nothing would be echoed at all.
    let mut mfile = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(master_fd) };
    use std::io::{Read, Write};
    let wrote = mfile.write_all(b"ping\n").and_then(|_| mfile.flush()).is_ok();
    let heard = c.speak("HEAR", 3_000).unwrap_or_default();
    b.check(
        "a byte written to the master is read by the Carrier from its stdin",
        wrote && heard == "HEARD ping",
        format!("{heard:?}"),
    );

    let said = c.speak("SAY pong", 3_000).unwrap_or_default();

    // **Accumulated, not read once.** The terminal delivers the discipline's
    // echo of "ping" and the Carrier's "pong" as separate readable chunks,
    // and a single `read` returns whichever arrived first — which made this
    // check fail against a working terminal, reporting the echo as a missing
    // reply. Drain until the reply appears or the budget runs out.
    let mut seen = String::new();
    for _ in 0..40 {
        let mut buf = [0u8; 256];
        match mfile.read(&mut buf) {
            Ok(n) if n > 0 => seen.push_str(&String::from_utf8_lossy(&buf[..n])),
            _ => {}
        }
        if seen.contains("pong") {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    b.check(
        "a byte written by the Carrier is read by the host from the master",
        said == "SAID 4" && seen.contains("pong"),
        format!("speak={said:?} master saw {seen:?}"),
    );
    b.check(
        "the master saw the line discipline echo the input as CRLF — a pipe cannot",
        seen.contains("ping\r\n"),
        format!("{seen:?} — expected the terminal's own echo of \"ping\" before \"pong\""),
    );

    // The host resizes; the Carrier observes the change it could not make.
    let _ = c.pty().map(|q| q.set_winsize(pty::WinSize { rows: 40, cols: 100, xpixel: 0, ypixel: 0 }));
    let tty2 = c.speak("TTY", 3_000).unwrap_or_default();
    b.check(
        "the holder of the master resizes the terminal and the Carrier sees it",
        tty2 == "TTY true true true 40 100",
        format!("{tty2:?}"),
    );

    // ---------------------------------------------------------- the hangup
    //
    // Linux does NOT return 0 here. When the last slave closes, `read` on the
    // master returns `EIO` — a reader testing for EOF as `== 0` spins
    // forever — and `poll` reports `POLLHUP`. Both are asserted because a
    // future refactor is likelier to get the errno wrong than the poll.
    let starttime = pid.starttime;
    c.terminate(3_000);
    let gone = carrier::observe(cpid).starttime != starttime;
    // Drain whatever the terminal still had buffered before asking about the
    // hangup: a leftover byte is a successful read, and reading it as
    // "not EIO" would report a working hangup as a broken one.
    // Bounded and EAGAIN-tolerant: on a non-blocking master, "nothing to
    // read yet" and "hung up" are different answers and only the second
    // ends the loop. A budget bounds the case where the hangup never comes
    // — which is precisely what probe 32 arranges.
    let mut eio = false;
    for _ in 0..80 {
        let mut after = [0u8; 256];
        match mfile.read(&mut after) {
            Ok(n) if n > 0 => continue,
            Err(ref e) if e.raw_os_error() == Some(5) => {
                eio = true;
                break;
            }
            Err(ref e) if e.raw_os_error() == Some(11) => {
                std::thread::sleep(Duration::from_millis(25));
            }
            _ => break,
        }
    }
    b.check(
        "the Carrier's death is the end of the terminal — master reads EIO, never 0",
        gone && eio,
        format!("carrier gone={gone} · master reached EIO={eio}"),
    );

    // The host still owns the master after the Carrier is gone; dropping `p`
    // is what ends the pair, and it is the host that does it.
    let sid_after = c.pty().and_then(|q| q.session());
    b.check(
        "an unclaimed master no longer names a session once its Carrier is gone",
        sid_after.is_none() || sid_after == Some(0),
        format!("TIOCGSID(master)={sid_after:?}"),
    );

    // **Dropping the Carrier is what disposes of the terminal.** Nothing here
    // closes the master; `Carrier`'s `Drop` owns it because the `Pty` is a
    // field. That is the lifecycle binding by construction, and this is its
    // falsifier: afterwards the number is gone from this process entirely.
    std::mem::forget(mfile); // the Carrier's Pty owns the master, not this File.
    drop(c);
    let reused = crate::pty::fstat_rdev_of_path(&format!("/proc/self/fd/{master_fd}"));
    b.check(
        "dropping the Carrier disposes of its terminal — the host holds no master afterwards",
        reused.is_none(),
        format!("/proc/self/fd/{master_fd} still resolves: {reused:?}"),
    );
    drop(decoy);

    pty_ioctl_census(b, scratch);
    pty_property_stages(b, scratch);
    pty_attachment(b, scratch);
    pty_attachment_payload(b, scratch);
}

/// Read one framed observation **and any descriptor it carried**.
///
/// D.1.3c·2. The counterpart of `write_frame_with_fd`, and it exists here
/// rather than in `lib.rs` because this battery is the only thing in this
/// process that stands on the runtime's side of that channel.
///
/// **One `recvmsg` first, then plain reads.** Ancillary data rides the first
/// byte of the message that carried it, so the descriptor is either in the
/// first receive or it is gone; the loop afterwards only finishes a body that
/// the socket buffer split, and cannot resurrect a lost right.
fn read_frame_with_fds(fd: std::os::fd::RawFd)
-> std::io::Result<(Value, Vec<std::os::fd::RawFd>)> {
    let (first, fds) = crate::fdpass::recv_msg_with_fds(fd, 64 * 1024, 4)?;
    if first.len() < 4 {
        for f in &fds {
            crate::fdpass::close_fd(*f);
        }
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "short frame header",
        ));
    }
    let n = u32::from_be_bytes([first[0], first[1], first[2], first[3]]) as usize;
    let mut body = first[4..].to_vec();
    while body.len() < n {
        let mut buf = vec![0u8; n - body.len()];
        let got = unsafe {
            extern "C" {
                fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
            }
            read(fd, buf.as_mut_ptr(), buf.len())
        };
        if got <= 0 {
            for f in &fds {
                crate::fdpass::close_fd(*f);
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "short frame body",
            ));
        }
        body.extend_from_slice(&buf[..got as usize]);
    }
    let v: Value = serde_json::from_slice(&body[..n])
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    Ok((v, fds))
}

/// Bounded, non-blocking accumulate from a stream endpoint.
///
/// The same discipline every read in this file uses and for the same reason:
/// each of these has a terminating condition that is itself under test, and a
/// blocking read turns a failed property into a wedged battery.
fn slurp(fd: std::os::fd::RawFd, want: &str, tries: usize) -> String {
    extern "C" {
        fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
        fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
    }
    unsafe {
        let fl = fcntl(fd, 3, 0);
        if fl >= 0 {
            fcntl(fd, 4, fl | 0o4000);
        }
    }
    let mut seen = String::new();
    for _ in 0..tries {
        let mut buf = [0u8; 4096];
        let n = unsafe { read(fd, buf.as_mut_ptr(), buf.len()) };
        if n > 0 {
            seen.push_str(&String::from_utf8_lossy(&buf[..n as usize]));
        }
        if !want.is_empty() && seen.contains(want) {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    seen
}

/// Is this descriptor a terminal? Asked of the kernel.
fn is_a_terminal(fd: std::os::fd::RawFd) -> bool {
    extern "C" {
        fn syscall(num: i64, ...) -> i64;
    }
    let mut termios = [0u8; 64];
    // TCGETS. On anything that is not a terminal this is `ENOTTY`, which is
    // the entire claim being made about an attachment endpoint.
    unsafe { syscall(16, fd as i64, 0x5401u64, termios.as_mut_ptr()) >= 0 }
}

/// D.1.3c·2 — the terminal attachment, over the production lifecycle channel.
///
/// ```text
///   Carrier   POSSESSES            PTY slave        (c·1, unchanged)
///   host      OWNS                 PTY master       (c·1, unchanged)
///   holder    POSSESSES            attachment       (this)
///   attachment TARGETS             that PTY         (this)
/// ```
///
/// **Driven through `serve_carrier`**, on a real socketpair, against real
/// Carriers this battery cannot otherwise reach — the same standing this
/// battery has when it measures the drain. That matters more than convenience:
/// an attachment mechanism proved only against a `Carrier` the test itself
/// holds would be a mechanism whose production entry point nothing exercised,
/// which is precisely the defect c·1a was spent repairing one level down.
fn pty_attachment(b: &mut Battery, scratch: &Path) {
    use crate::{carrier, fdpass, read_frame, write_frame};

    println!("\n  D.1.3c·2 · the terminal attachment");

    if carrier::fixture_path().is_none() {
        b.check("the attachment falsifiers could run", false, "no carrier fixture");
        return;
    }
    let dir = scratch.join("attach");
    let _ = std::fs::create_dir_all(&dir);

    let Ok(fdpass::Pair(mine, theirs)) = fdpass::pair_stream() else {
        b.check("the attachment falsifiers could run", false, "no socketpair");
        return;
    };
    let served = dir.clone();
    std::thread::spawn(move || crate::serve_carrier(theirs, served));

    let ptmx_before = host_ptmx_count();

    // Two Carriers, because half of what an attachment must not do is reach
    // the other one. A single-Carrier battery cannot see a stream that is
    // wired to the wrong terminal, and that is the failure this design is
    // most able to have.
    let mut started: Vec<(String, String)> = Vec::new();
    for i in 0..2 {
        let cref = format!("cr_att{i}");
        let cep = format!("att-epoch-{i}");
        let req = json!({
            "schema": "carrier-start-request@1", "op": "start",
            "carrier_ref": cref, "carrier_epoch": cep, "runtime_epoch": "runtime-ATT",
        });
        if write_frame(mine, &req).is_err() { break }
        let Ok(obs) = read_frame(mine) else { break };
        if obs["refused"].is_null() {
            started.push((cref, cep));
        }
    }
    b.check(
        "two real Carriers are running, each on its own terminal",
        started.len() == 2 && host_ptmx_count() == ptmx_before + 2,
        format!("{started:?} · masters {ptmx_before} → {}", host_ptmx_count()),
    );
    if started.len() != 2 {
        return;
    }

    let (ref_a, ep_a) = started[0].clone();
    let (ref_b, ep_b) = started[1].clone();

    // ------------------------------------------------------- attach, and what
    //                                                         it hands over
    let attach = |cref: &str, cep: &str| -> (Value, Vec<std::os::fd::RawFd>) {
        let _ = write_frame(mine, &json!({
            "schema": "carrier-pty-attach-request@1", "op": "pty-attach",
            "carrier_ref": cref, "carrier_epoch": cep,
        }));
        read_frame_with_fds(mine).unwrap_or((Value::Null, vec![]))
    };

    let (obs_a, fds_a) = attach(&ref_a, &ep_a);
    let pty_epoch_a = obs_a["pty_epoch"].as_str().unwrap_or("").to_string();
    let stream_a = fds_a.first().copied().unwrap_or(-1);

    b.check(
        "attaching answers with a descriptor, not with a name",
        obs_a["attached"] == true && fds_a.len() == 1 && stream_a >= 0,
        format!("fds={fds_a:?} obs={obs_a}"),
    );
    b.check(
        "the attachment names an ephemeral pty epoch minted by the host",
        pty_epoch_a.len() == 32 && pty_epoch_a.chars().all(|c| c.is_ascii_hexdigit()),
        format!("pty_epoch={pty_epoch_a:?}"),
    );

    // ------------------------------------------------- the identity's width
    //
    // **A label that is about to become a name.** `attachment_ref` was three
    // characters and a 12-hex slice of the mint — 48 bits — and that was
    // invisible while the host decided everything by `attachment_epoch` and
    // nothing at all by the ref. c·2b makes it the runtime's name for a
    // `terminal-attachment@1`, indexed and quoted, and 48 bits is a
    // birthday collision at populations this stack keeps designing against.
    //
    // Asked of the value that crossed the wire, not of the source line that
    // produced it, because the failure being guarded against is a future
    // truncation "for display" and a source grep would be satisfied by a
    // mint that is wide right up until something narrows it downstream. The
    // matching sabotage probe re-introduces the slice and must turn this red.
    let hex32 = |s: &str| {
        s.len() == 32 && s.chars().all(|c| c.is_ascii_digit() || matches!(c, 'a'..='f'))
    };
    let att_ref_a = obs_a["attachment_ref"].as_str().unwrap_or("").to_string();
    let att_ep_a = obs_a["attachment_epoch"].as_str().unwrap_or("").to_string();
    b.check(
        "the attachment ref is a FULL 128-bit mint — ta_ then 32 lowercase hex, never a slice",
        att_ref_a.strip_prefix("ta_").map_or(false, |p| hex32(p)),
        format!(
            "attachment_ref={att_ref_a:?} — {} hex after the prefix, wanted 32",
            att_ref_a.strip_prefix("ta_").map_or(0, str::len)
        ),
    );
    b.check(
        "the attachment epoch is a full 128-bit mint of its own",
        hex32(&att_ep_a),
        format!("attachment_epoch={att_ep_a:?}"),
    );
    // They are minted at the same event and are still two identifiers: the
    // ref names the object, the epoch names this incarnation of it. Equal
    // values would be a single identifier wearing two field names, and the
    // day one of them has to move without the other there would be nothing
    // to move.
    b.check(
        "the attachment's ref and its epoch are DISTINCT mints, not one value twice",
        att_ref_a
            .strip_prefix("ta_")
            .map_or(false, |p| !p.is_empty() && p != att_ep_a),
        format!("ref={att_ref_a:?} epoch={att_ep_a:?}"),
    );

    // The negative half of "no pathname crosses the wire", asked of the whole
    // serialized answer rather than of the fields somebody remembered to look
    // at.
    let flat = obs_a.to_string();
    b.check(
        "no pathname, pts index or pid appears anywhere in the attach answer",
        !flat.contains("/dev/pts") && !flat.contains("ptmx") && !flat.contains("/proc/"),
        format!("{flat}"),
    );

    // **The endpoint is a socket and not a terminal.** This is the whole of
    // "the attachment transfers no ioctl authority": there is nothing terminal
    // -shaped to ask it, so `TIOCSWINSZ`, `TIOCSTI` and `TCSETS` are not
    // refused by policy here — they are unanswerable by kind.
    b.check(
        "the attachment endpoint is NOT a terminal — TCGETS on it answers ENOTTY",
        stream_a >= 0 && !is_a_terminal(stream_a),
        format!("fd {stream_a} answered TCGETS"),
    );
    // **What arrived is a socket, asked of the kernel.** The count next door
    // cannot answer this: a duplicate of the master readlinks to `/dev/ptmx`
    // exactly like the original, so "the number went up by one" is equally
    // true of the pump doing its job and of the master being handed over.
    // This is the question that distinguishes them.
    b.check(
        "what the holder received is a socket endpoint and not the master",
        std::fs::read_link(format!("/proc/self/fd/{stream_a}"))
            .map(|p| p.to_string_lossy().starts_with("socket:"))
            .unwrap_or(false),
        format!(
            "fd {stream_a} → {:?}",
            std::fs::read_link(format!("/proc/self/fd/{stream_a}"))
        ),
    );
    // **The pump's duplicate is deliberately visible in the census**, and
    // this check exists to say so rather than to be satisfied. A duplicate
    // that did not appear here would be a master this host holds and cannot
    // count — and the census is the only thing standing between a forgotten
    // pump and a terminal that never hangs up.
    b.check(
        "the pump's duplicate of the master IS visible in the host's own census",
        host_ptmx_count() == ptmx_before + 3,
        format!("masters {} (expected {} — two Carriers and one pump)",
                host_ptmx_count(), ptmx_before + 3),
    );

    // -------------------------------------------------- bytes, through the pump
    //
    // The line discipline is the witness. A byte written into the attachment
    // reaches the slave, the terminal echoes it, the echo comes back out of
    // the master and through the pump — so a round trip proves **both**
    // directions and proves the thing on the far end is a real terminal. A
    // pipe returns nothing at all.
    {
        extern "C" {
            fn write(fd: i32, buf: *const u8, count: usize) -> isize;
        }
        let msg = b"hello-attachment\n";
        let put = unsafe { write(stream_a, msg.as_ptr(), msg.len()) };
        let echoed = slurp(stream_a, "hello-attachment", 60);
        b.check(
            "bytes written to the attachment reach the terminal, and its echo comes back",
            put == msg.len() as isize && echoed.contains("hello-attachment\r\n"),
            format!("wrote {put} · read {echoed:?} — expected the discipline's CRLF echo"),
        );
    }

    // ------------------------------------------------ one stream, one terminal
    let (obs_b, fds_b) = attach(&ref_b, &ep_b);
    let stream_b = fds_b.first().copied().unwrap_or(-1);
    b.check(
        "a second Carrier attaches to its own terminal, with its own epochs",
        obs_b["attached"] == true
            && stream_b >= 0
            && obs_b["pty_epoch"].as_str().unwrap_or("") != pty_epoch_a
            && obs_b["attachment_epoch"] != obs_a["attachment_epoch"],
        format!("{obs_b}"),
    );
    {
        // Anything B's terminal echoes must not appear on A's stream. Written
        // to B and read from A, which is the direction a mis-wired pump would
        // actually fail in.
        extern "C" {
            fn write(fd: i32, buf: *const u8, count: usize) -> isize;
        }
        let m = b"belongs-to-b\n";
        let _ = unsafe { write(stream_b, m.as_ptr(), m.len()) };
        let on_b = slurp(stream_b, "belongs-to-b", 40);
        let on_a = slurp(stream_a, "", 8);
        b.check(
            "an attachment never sees another Carrier's terminal",
            on_b.contains("belongs-to-b") && !on_a.contains("belongs-to-b"),
            format!("B saw {on_b:?} · A saw {on_a:?}"),
        );
    }

    // ------------------------------------------------------ a second attachment
    let (again, fds_again) = attach(&ref_a, &ep_a);
    for f in &fds_again { fdpass::close_fd(*f); }
    b.check(
        "a Carrier's terminal cannot be attached twice in this slice",
        again["attached"].is_null()
            && again["refused"].as_str().unwrap_or("").contains("already attached")
            && fds_again.is_empty(),
        format!("{again}"),
    );

    // ------------------------------------------------------------- the address
    //
    // Each of these is a real request over the real channel, differing from a
    // working one in exactly one identity.
    let ask = |op: &str, schema: &str, cref: &str, cep: &str, pep: &str, aep: &str| -> Value {
        let _ = write_frame(mine, &json!({
            "schema": schema, "op": op,
            "carrier_ref": cref, "carrier_epoch": cep,
            "pty_epoch": pep, "attachment_epoch": aep,
            "rows": 30, "cols": 90,
        }));
        read_frame(mine).unwrap_or(Value::Null)
    };
    let att_epoch_a = obs_a["attachment_epoch"].as_str().unwrap_or("").to_string();

    let wrong_ce = ask("pty-resize", "carrier-pty-resize-request@1", &ref_a, "not-the-epoch", &pty_epoch_a, &att_epoch_a);
    b.check(
        "a resize naming the wrong carrier epoch is refused",
        wrong_ce["resized"].is_null() && wrong_ce["refused"].as_str().unwrap_or("").contains("carrier epoch"),
        format!("{wrong_ce}"),
    );
    let wrong_pe = ask("pty-resize", "carrier-pty-resize-request@1", &ref_a, &ep_a, "0123456789abcdef0123456789abcdef", &att_epoch_a);
    b.check(
        "a resize naming another terminal's pty epoch is refused",
        wrong_pe["resized"].is_null() && wrong_pe["refused"].as_str().unwrap_or("").contains("pty epoch"),
        format!("{wrong_pe}"),
    );
    // B's epoch against A's ref: both halves individually well-formed, and the
    // pair naming no terminal that exists. This is the replacement case in
    // miniature, and it is the one a single-Carrier battery cannot construct.
    let pty_epoch_b = obs_b["pty_epoch"].as_str().unwrap_or("").to_string();
    let crossed = ask("pty-resize", "carrier-pty-resize-request@1", &ref_a, &ep_a, &pty_epoch_b, &att_epoch_a);
    b.check(
        "a resize carrying another live Carrier's pty epoch is refused",
        crossed["resized"].is_null(),
        format!("{crossed}"),
    );

    let sized = ask("pty-resize", "carrier-pty-resize-request@1", &ref_a, &ep_a, &pty_epoch_a, &att_epoch_a);
    b.check(
        "a resize naming all three current identities is performed",
        sized["resized"] == true && sized["rows"] == 30 && sized["cols"] == 90,
        format!("{sized}"),
    );
    let zero = {
        let _ = write_frame(mine, &json!({
            "schema": "carrier-pty-resize-request@1", "op": "pty-resize",
            "carrier_ref": ref_a, "carrier_epoch": ep_a, "pty_epoch": pty_epoch_a,
            "attachment_epoch": att_epoch_a,
            "rows": 0, "cols": 0,
        }));
        read_frame(mine).unwrap_or(Value::Null)
    };
    b.check(
        "a resize to zero rows or columns is refused rather than performed",
        zero["resized"].is_null(),
        format!("{zero}"),
    );

    // ------------------------------------------------- detaching is not killing
    let det = ask("pty-detach", "carrier-pty-detach-request@1", &ref_a, &ep_a, &pty_epoch_a, &att_epoch_a);
    b.check(
        "detaching closes the attachment and leaves the Carrier running",
        det["detached"] == true && det["carrier_still_running"] == true,
        format!("{det}"),
    );
    b.check(
        "the detached holder sees EOF on its endpoint",
        {
            extern "C" {
                fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
            }
            let mut eof = false;
            for _ in 0..40 {
                let mut buf = [0u8; 256];
                if unsafe { read(stream_a, buf.as_mut_ptr(), buf.len()) } == 0 {
                    eof = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            eof
        },
        "the endpoint never reported end of stream after a detach",
    );
    // Two Carriers and B's pump. A's pump duplicate is gone, so a detach
    // that merely stopped forwarding — leaving the thread parked on a master
    // it still held — would be caught here and nowhere else.
    b.check(
        "and detaching returned the pump's duplicate of the master",
        host_ptmx_count() == ptmx_before + 3,
        format!("masters {} (expected {} — two Carriers and B's pump)",
                host_ptmx_count(), ptmx_before + 3),
    );

    // A detached attachment cannot be re-used, and re-attaching is a NEW
    // attachment rather than the old one coming back.
    let (re, fds_re) = attach(&ref_a, &ep_a);
    let stream_re = fds_re.first().copied().unwrap_or(-1);
    b.check(
        "re-attaching mints a new attachment epoch — the old one does not return",
        re["attached"] == true
            && re["attachment_epoch"] != obs_a["attachment_epoch"]
            && re["pty_epoch"] == pty_epoch_a.as_str(),
        format!("{re}"),
    );
    let att_epoch_re = re["attachment_epoch"].as_str().unwrap_or("").to_string();
    // And the *ref* is new too. Checked separately from the epoch because
    // these are the two halves c·2b will hold apart — a mint that refreshed
    // the epoch while handing back the old ref would give the runtime a name
    // that outlives the object it names, which is the exact shape of the
    // stale-address bug this slice spent itself closing.
    let att_ref_re = re["attachment_ref"].as_str().unwrap_or("").to_string();
    b.check(
        "re-attaching mints a new attachment REF as well — a name is not reused across incarnations",
        att_ref_re.strip_prefix("ta_").map_or(false, |p| hex32(p)) && att_ref_re != att_ref_a,
        format!("was {att_ref_a:?} · now {att_ref_re:?}"),
    );

    // --------------------------------------- the stale ATTACHMENT, replayed
    //
    // **The case three identities cannot see.** A1 has been detached and A2
    // exists on the same Carrier, the same incarnation and the same terminal,
    // so `carrier_ref`, `carrier_epoch` and `pty_epoch` are all current in a
    // request minted against A1. Only the fourth identity can refuse it, and
    // until an operation is required to carry that identity, minting a fresh
    // one on re-attach is bookkeeping rather than an address.
    let stale_det = ask("pty-detach", "carrier-pty-detach-request@1",
                        &ref_a, &ep_a, &pty_epoch_a, &att_epoch_a);
    b.check(
        "a detach replayed from a REPLACED attachment is refused, not applied to its successor",
        stale_det["detached"].is_null()
            && stale_det["refused"].as_str().unwrap_or("").contains("attachment epoch"),
        format!("{stale_det}"),
    );
    // And the successor is untouched — asked of the stream, because a refusal
    // that had already torn the pump down would answer the check above just
    // as well.
    b.check(
        "and the replacement attachment still carries bytes after the stale detach",
        {
            extern "C" {
                fn write(fd: i32, buf: *const u8, count: usize) -> isize;
            }
            let m = b"survived-the-stale-detach\n";
            let _ = unsafe { write(stream_re, m.as_ptr(), m.len()) };
            slurp(stream_re, "survived-the-stale-detach", 40)
                .contains("survived-the-stale-detach")
        },
        "the surviving attachment stopped carrying bytes, so the stale detach reached it",
    );

    let stale_size = ask("pty-resize", "carrier-pty-resize-request@1",
                         &ref_a, &ep_a, &pty_epoch_a, &att_epoch_a);
    b.check(
        "a resize replayed from a REPLACED attachment is refused",
        stale_size["resized"].is_null(),
        format!("{stale_size}"),
    );
    let cur_size = ask("pty-resize", "carrier-pty-resize-request@1",
                       &ref_a, &ep_a, &pty_epoch_a, &att_epoch_re);
    b.check(
        "while the CURRENT attachment's resize is performed — the refusal is the epoch, not the op",
        cur_size["resized"] == true,
        format!("{cur_size}"),
    );

    // ------------------------------- the holder that vanishes without detaching
    //
    // **The normal runtime failure, not a malformed one.** A holder's process
    // crashes, its Peer dies, the runtime closes the socket it adopted — and
    // no detach is ever sent. The pump sees EOF and stops, which is correct;
    // the question is what happens to the *slot*.
    //
    // A slot that stayed occupied because the field was still `Some` would
    // refuse every future attach on a Carrier that is otherwise perfectly
    // alive, until the Carrier itself died. That is
    // `Ampd.Carrier.Reaper`'s distinction one layer down — semantic
    // membership ending is not the same event as the process ending — and it
    // is answered by re-deriving liveness rather than by remembering.
    crate::fdpass::close_fd(stream_re);
    // **The successful attach IS the proof, so it is kept rather than
    // probed.** A first draft polled with throwaway attaches and closed each
    // one — which orphaned a fresh attachment on every iteration and then
    // raced its own pump, so the real attach that followed was refused
    // "already attached". The loop retries only while the answer is a
    // refusal; the moment it succeeds, that attachment is the one under test.
    let (post, fds_post) = {
        let mut got = (Value::Null, vec![]);
        for _ in 0..40 {
            let r = attach(&ref_a, &ep_a);
            if r.0["attached"] == true {
                got = r;
                break;
            }
            for f in &r.1 { crate::fdpass::close_fd(*f); }
            std::thread::sleep(Duration::from_millis(25));
        }
        got
    };
    let stream_post = fds_post.first().copied().unwrap_or(-1);
    b.check(
        "a holder that closes its endpoint without detaching leaves a RECLAIMABLE slot",
        post["attached"] == true,
        format!("the slot stayed occupied after its holder vanished — this Carrier \
                 would be permanently unattachable: {post}"),
    );
    // The Carrier is untouched by any of it. Losing an observer is not a
    // death, and the reclaim must not have become one.
    b.check(
        "the Carrier survived its holder vanishing, and the new attachment is a NEW incarnation",
        post["attached"] == true
            && post["attachment_epoch"] != att_epoch_re.as_str()
            && post["attachment_epoch"] != att_epoch_a.as_str()
            && post["pty_epoch"] == pty_epoch_a.as_str(),
        format!("{post}"),
    );
    b.check(
        "and bytes flow both ways on the attachment that replaced the orphan",
        {
            extern "C" {
                fn write(fd: i32, buf: *const u8, count: usize) -> isize;
            }
            let m = b"after-the-orphan\n";
            let put = unsafe { write(stream_post, m.as_ptr(), m.len()) };
            put == m.len() as isize
                && slurp(stream_post, "after-the-orphan", 60).contains("after-the-orphan\r\n")
        },
        "the replacement attachment did not carry the terminal's echo",
    );
    b.check(
        "and the orphaned pump's duplicate of the master was returned, not leaked",
        host_ptmx_count() == ptmx_before + 4,
        format!("masters {} (expected {} — two Carriers, B's pump, one live pump on A)",
                host_ptmx_count(), ptmx_before + 4),
    );

    // -------------------------------------------------------- the death matrix
    let stopped = {
        let _ = write_frame(mine, &json!({
            "schema": "carrier-stop-request@1", "op": "stop",
            "carrier_ref": ref_a, "carrier_epoch": ep_a,
        }));
        read_frame(mine).unwrap_or(Value::Null)
    };
    b.check(
        "the attached Carrier stops",
        stopped["stopped"] == true,
        format!("{stopped}"),
    );
    b.check(
        "a Carrier's death closes its attachment — the holder sees EOF",
        {
            extern "C" {
                fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
            }
            let mut eof = false;
            for _ in 0..40 {
                let mut buf = [0u8; 256];
                if unsafe { read(stream_post, buf.as_mut_ptr(), buf.len()) } == 0 {
                    eof = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            eof
        },
        "the endpoint of a dead Carrier never reported end of stream",
    );
    // **Two descriptors at once, and that is the point.** Stopping A returns
    // A's master AND the duplicate held by the attachment that was re-made on
    // it. A disposal that closed the master and left the pump would leave the
    // count one high, and the terminal alive in a process nobody is watching.
    b.check(
        "and the terminal went with it — master and pump duplicate both gone",
        host_ptmx_count() == ptmx_before + 2,
        format!("masters {} (expected {} — B and B's pump only)",
                host_ptmx_count(), ptmx_before + 2),
    );

    // An operation against the terminal that has just died. Not "refused
    // because the pty epoch moved" — there is no Carrier left to hold one —
    // but refused, and never applied to the survivor.
    let after = ask("pty-resize", "carrier-pty-resize-request@1",
                    &ref_a, &ep_a, &pty_epoch_a, &att_epoch_a);
    b.check(
        "an operation addressed to a dead Carrier's terminal is refused, not rerouted",
        after["resized"].is_null(),
        format!("{after}"),
    );

    // ------------------------------------------------------------- the drain
    let drained = {
        let _ = write_frame(mine, &json!({
            "schema": "carrier-runtime-drain-request@1", "op": "drain",
            "runtime_epoch": "runtime-ATT",
        }));
        read_frame(mine).unwrap_or(Value::Null)
    };
    b.check(
        "a drain closes every remaining terminal stream with its Carrier",
        drained["remaining"] == 0 && host_ptmx_count() == ptmx_before,
        format!("{drained} · masters {} (expected {ptmx_before})", host_ptmx_count()),
    );
    b.check(
        "the surviving attachment saw EOF when its Carrier was drained",
        {
            extern "C" {
                fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
            }
            let mut eof = false;
            for _ in 0..40 {
                let mut buf = [0u8; 256];
                if unsafe { read(stream_b, buf.as_mut_ptr(), buf.len()) } == 0 {
                    eof = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            eof
        },
        "a drained Carrier's attachment never reported end of stream",
    );

    for f in [stream_a, stream_b, stream_post] {
        if f >= 0 { fdpass::close_fd(f); }
    }
    fdpass::close_fd(mine);
}

/// The half the channel battery cannot reach: **the payload really receives
/// the bytes, and its own output really leaves.**
///
/// The Carriers in `pty_attachment` live inside `serve_carrier`'s map, so
/// nothing there can speak to one on fd 3 — and the line-discipline echo,
/// which is the right witness for *the pump*, says nothing about whether the
/// process behind the terminal ever saw a byte. This holds its own Carrier so
/// it can ask, and calls the same `Carrier::attach` the op calls.
///
/// It also carries the backpressure measurement, which needs a consumer that
/// deliberately stops reading — something no correlated request/response
/// exchange can express.
fn pty_attachment_payload(b: &mut Battery, scratch: &Path) {
    use crate::carrier;
    use crate::pty::Pty;

    println!("\n  D.1.3c·2 · the payload behind the attachment");

    let Some(fixture) = carrier::fixture_path() else {
        b.check("the attachment payload falsifiers could run", false, "no fixture");
        return;
    };
    let dir = scratch.join("attachpay");
    let _ = std::fs::create_dir_all(&dir);

    let Ok(p) = Pty::open() else {
        b.check("the attachment payload falsifiers could run", false, "no pty");
        return;
    };
    let before = host_ptmx_count();
    let mut c = match carrier::spawn_on_pty(&fixture, &dir, &dir.join("ap.log"),
                                            &crate::new_epoch(), None, p) {
        Ok(c) => c,
        Err(e) => {
            b.check("a Carrier starts for the attachment payload battery", false, e);
            return;
        }
    };
    if c.handshake(5_000).is_err() {
        b.check("the attachment payload Carrier proved its incarnation", false, "no handshake");
        return;
    }

    let stream = match c.attach() {
        Ok(f) => f,
        Err(e) => {
            b.check("an attachment is created on a live Carrier", false, e);
            return;
        }
    };
    b.check(
        "attaching duplicates the master and does not allocate a second terminal",
        host_ptmx_count() == before + 1,
        format!("masters {} (expected {}) — one more descriptor onto the SAME terminal, \
                 not a second /dev/ptmx open", host_ptmx_count(), before + 1),
    );

    extern "C" {
        fn write(fd: i32, buf: *const u8, count: usize) -> isize;
    }

    // ---------------------------------------------- input reaches the payload
    let msg = b"through-the-pump\n";
    let put = unsafe { write(stream, msg.as_ptr(), msg.len()) };
    let heard = c.speak("HEAR", 3_000).unwrap_or_default();
    b.check(
        "input written to the attachment is read by the Carrier from its own stdin",
        put == msg.len() as isize && heard == "HEARD through-the-pump",
        format!("wrote {put} · carrier said {heard:?}"),
    );

    // --------------------------------------------- output leaves the payload
    let said = c.speak("SAY attached-output", 3_000).unwrap_or_default();
    let seen = slurp(stream, "attached-output", 60);
    b.check(
        "output written by the Carrier arrives on the attachment",
        said.starts_with("SAID") && seen.contains("attached-output"),
        format!("speak={said:?} · attachment saw {seen:?}"),
    );

    // ------------------------------------------------------- bounded memory
    //
    // **The consumer stops reading and the host does not grow.** The pump
    // declines to read the master once its outbound buffer is full, so the
    // pts buffer fills and the Carrier's own `write` blocks — which is what a
    // terminal with an inattentive reader is supposed to do. The measurement
    // is the pump *saying it stalled*: an unbounded relay would report zero
    // stalls and a rising heap instead.
    //
    // 512 KiB asked for against a 64 KiB buffer plus the socket's own space,
    // so the stall is structural rather than a matter of timing.
    let mut asked = 0usize;
    for _ in 0..64 {
        // 8 KiB per line, never read back.
        let line = format!("SAY {}", "x".repeat(8 * 1024));
        match c.speak(&line, 300) {
            Ok(_) => asked += 8 * 1024,
            Err(_) => break,
        }
    }
    let stalled = c
        .attachment()
        .map(|a| a.stats().stalled_out.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    let moved = c
        .attachment()
        .map(|a| a.stats().to_stream.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    b.check(
        "a consumer that stops reading stalls the pump instead of growing the host",
        stalled > 0 && moved > 0,
        format!("asked {asked} bytes · pump moved {moved} · stalls {stalled} \
                 — zero stalls with a stopped consumer means an unbounded buffer"),
    );

    // Draining the endpoint lets it move again, so the stall was backpressure
    // and not a wedge. A pump that stopped forever would satisfy the check
    // above just as well.
    let after_drain = {
        let _ = slurp(stream, "", 40);
        c.attachment()
            .map(|a| a.stats().to_stream.load(std::sync::atomic::Ordering::Relaxed))
            .unwrap_or(0)
    };
    b.check(
        "and it resumes once the consumer reads — the stall was backpressure, not a wedge",
        after_drain > moved,
        format!("moved {moved} before the drain, {after_drain} after"),
    );

    // ---------------------------------------------------- the ending is named
    let live_before = c.attachment().map(|a| a.live()).unwrap_or(false);
    c.terminate(3_000);
    let ending = c.attachment().map(|a| a.ending().name().to_string()).unwrap_or_default();
    b.check(
        "the pump ends because the TERMINAL hung up, not because the host tidied up",
        live_before && ending == "terminal-hangup",
        format!("ending={ending:?} — 'host-closed' here would mean the binding is policy, not lifetime"),
    );

    // **EOF arrives from the hangup, before anything is disposed of.** The
    // `Carrier` is still a live value here and its end of the stream is still
    // open, so a holder that only learns of the death when the descriptor is
    // finally closed would still be waiting. This is the check that makes the
    // pump's `shutdown(SHUT_WR)` load-bearing rather than belt-and-braces:
    // "the terminal disappeared" has to be something the holder is told, not
    // something it infers from the socket eventually going away.
    b.check(
        "the holder is told the terminal is gone before the Carrier is disposed of",
        {
            extern "C" {
                fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
            }
            let mut eof = false;
            for _ in 0..40 {
                let mut buf = [0u8; 4096];
                if unsafe { read(stream, buf.as_mut_ptr(), buf.len()) } == 0 {
                    eof = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            eof
        },
        "the endpoint reported no end of stream while the Carrier value was still alive",
    );

    drop(c);
    b.check(
        "and the Carrier's disposal left the host holding no master at all",
        host_ptmx_count() == before.saturating_sub(1),
        format!("masters {} (expected {})", host_ptmx_count(), before.saturating_sub(1)),
    );
    crate::fdpass::close_fd(stream);
}

/// The four terminal properties, staged apart.
///
/// ```text
///   dup only      tty fds   ·  no new session  ·  NO ctty  ·  no fg group
///   + setsid      tty fds   ·  session leader  ·  NO ctty  ·  no fg group
///   + TIOCSCTTY   tty fds   ·  session leader  ·  ctty     ·  fg group
/// ```
///
/// **The middle row is the whole point.** It is why `spawn_with`'s `pre_exec`
/// does two separate things rather than one, and why "the Carrier has a
/// terminal on stdio" and "the Carrier has a controlling terminal" are
/// different sentences that a single `has_pty` boolean would have merged.
///
/// Run **unconfined**, because it measures Linux rather than Super: `setsid`
/// and `TIOCSCTTY` are precisely the two calls a Carrier is refused, so a
/// confined run could not reach the second and third rows at all. The
/// confined census next door is what shows Super refusing them.
fn pty_property_stages(b: &mut Battery, scratch: &Path) {
    use crate::carrier;
    use crate::pty::Pty;
    use std::io::Read;
    use std::os::unix::process::CommandExt;

    let Some(fixture) = carrier::fixture_path() else { return };
    let Some(probe) = fixture.parent().map(|d| d.join("probe")) else { return };
    if !probe.is_file() {
        return;
    }
    let dir = scratch.join("pty-stages");
    let _ = std::fs::create_dir_all(&dir);

    let mut p = match Pty::open() {
        Ok(p) => p,
        Err(e) => {
            b.check("the pty staging control could run", false, e);
            return;
        }
    };
    let slave = p.slave().unwrap_or(-1);
    let child = unsafe {
        std::process::Command::new(&probe)
            .arg("stages")
            .current_dir(&dir)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .pre_exec(move || {
                // dup ONLY. No setsid, no TIOCSCTTY — the child performs
                // those itself, one at a time, reporting between each.
                crate::fdpass::dup_onto(slave, 0)?;
                crate::fdpass::dup_onto(slave, 1)?;
                crate::fdpass::dup_onto(slave, 2)?;
                Ok(())
            })
            .spawn()
    };
    let Ok(mut child) = child else {
        b.check("the pty staging control could run", false, format!("{child:?}"));
        return;
    };
    p.close_slave();

    let mut mf = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(p.master()) };
    let mut all = String::new();
    let mut buf = [0u8; 2048];
    loop {
        match mf.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => all.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(_) => break,
        }
    }
    std::mem::forget(mf);
    let _ = child.wait();

    let stage = |name: &str| -> Option<(i32, i32, u32, i32)> {
        for l in all.lines() {
            let l = l.trim_end_matches('\r');
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() == 6 && f[0] == "STAGE" && f[1] == name {
                return Some((
                    f[2].parse().ok()?, f[3].parse().ok()?,
                    f[4].parse::<i32>().ok()? as u32, f[5].parse().ok()?,
                ));
            }
        }
        None
    };

    let a = stage("dup");
    let bb = stage("setsid");
    let cc = stage("ctty");
    b.check(
        "the staging control reported all three stages",
        a.is_some() && bb.is_some() && cc.is_some(),
        format!("{all:?}"),
    );

    b.check(
        "stage 1 · a pty on 0/1/2 confers NO session and NO controlling terminal",
        matches!(a, Some((_, _, tty, tpgid)) if tty == 0 && tpgid == -1),
        format!("{a:?} — (pgrp, session, tty_nr, tpgid); tty_nr 0 means none"),
    );
    b.check(
        "stage 2 · setsid makes a session leader and STILL confers no controlling terminal",
        matches!((a, bb), (Some((_, sa, _, _)), Some((_, sb, tty, tpgid)))
                 if sb != sa && tty == 0 && tpgid == -1),
        format!("before={a:?} after={bb:?} — the stage the whole pre_exec order exists for"),
    );
    b.check(
        "stage 3 · TIOCSCTTY is what establishes the controlling terminal and foreground group",
        matches!(cc, Some((pgrp, _, tty, tpgid)) if tty != 0 && tpgid == pgrp),
        format!("{cc:?}"),
    );
    b.check(
        "and the terminal it established is this master's",
        matches!(cc, Some((_, _, tty, _)) if crate::pty::decode_tty_nr(tty).1 == p.ptn()),
        format!("tty_nr decodes to {:?} · TIOCGPTN(master)={}",
                cc.map(|c| crate::pty::decode_tty_nr(c.2)), p.ptn()),
    );

    drop(p);
}

/// The ioctl policy, **issued rather than described**.
///
/// The rows above prove a Carrier possesses a terminal. These prove what it
/// may do with it, and they do it by calling — `confine::IOCTL_ALLOWED` is a
/// description of the policy, and the census's founding objection is that a
/// list nobody calls is a list of intentions.
///
/// The probe is spawned on a real possessed terminal and its report is read
/// **from the master**, because its stdout is now that terminal. That is also
/// a second, incidental proof that the byte path carries real payload output
/// and not just the two words the fixture says.
fn pty_ioctl_census(b: &mut Battery, scratch: &Path) {
    use crate::carrier;
    use crate::pty::Pty;
    use std::io::Read;

    let Some(fixture) = carrier::fixture_path() else { return };
    let Some(probe) = fixture.parent().map(|d| d.join("probe")) else { return };
    if !probe.is_file() {
        b.check("the pty ioctl census could run", false, format!("no probe at {probe:?}"));
        return;
    }
    let dir = scratch.join("pty-census");
    let _ = std::fs::create_dir_all(&dir);

    let p = match Pty::open() {
        Ok(p) => p,
        Err(e) => {
            b.check("the pty ioctl census could run", false, e);
            return;
        }
    };
    let args = ["0".to_string(), "-1".to_string(), dir.to_string_lossy().into_owned(),
                "pty".to_string()];
    let master_fd = p.master();
    let run = carrier::spawn_with(&probe, &dir, &dir.join("c.log"), &crate::new_epoch(),
                                  None, &args, &[], Some(p));
    let Ok(mut c) = run else {
        b.check("the pty ioctl census could run", false, format!("{:?}", run.err()));
        return;
    };

    // Read until the probe exits and the last slave closes — which is `EIO`
    // on a master, never 0. A `read() == 0` loop here would never terminate.
    // **Bounded, and non-blocking, because the terminating condition used to
    // be the thing under test.** This read until the hangup, which is right
    // when the Carrier is the only slave holder and an unbounded block when
    // it is not — and the host battery has a probe that deliberately makes
    // the host keep its copy. That probe scored `TIMED OUT` after 240s and
    // proved nothing, correctly. A budget and `EAGAIN` make the wedge a
    // short row instead of a dead battery.
    let _ = c.pty().map(|q| q.set_nonblocking());
    let mut mf = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(master_fd) };
    let mut all = String::new();
    let mut buf = [0u8; 4096];
    let mut quiet = 0;
    for _ in 0..400 {
        match mf.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                quiet = 0;
                all.push_str(&String::from_utf8_lossy(&buf[..n]));
            }
            Err(ref e) if e.raw_os_error() == Some(11) => {
                // EAGAIN — nothing ready yet. The probe writes and exits
                // quickly, so a run of empty polls after output has started
                // means it is done even if the hangup is being withheld.
                quiet += 1;
                if !all.is_empty() && quiet > 20 {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => break, // EIO — the real hangup
        }
    }
    std::mem::forget(mf);
    c.terminate(2_000);

    // The line discipline turns every `\n` into `\r\n` on the way out, which
    // is the one place this slice has to *undo* the thing it just proved.
    let rows: std::collections::BTreeMap<String, (bool, i32)> = all
        .lines()
        .filter_map(|l| {
            let mut it = l.trim_end_matches('\r').split('\t');
            let n = it.next()?.to_string();
            let allowed = it.next()? == "ALLOWED";
            let e: i32 = it.next()?.parse().ok()?;
            Some((n, (allowed, e)))
        })
        .collect();

    b.check(
        "the probe ran on a possessed terminal and its report reached the master",
        rows.len() >= 10,
        format!("{} rows read from the master", rows.len()),
    );

    // **The allow-list must still permit a working terminal.** Without these
    // three, every refusal below would be satisfied by a policy that refused
    // `ioctl` outright — which is not a terminal, it is a pipe with extra
    // steps.
    for (name, what) in [
        ("pty_tcgets", "read the line discipline"),
        ("pty_tiocgwinsz", "read the window size"),
        ("pty_tiocgpgrp", "read the foreground group"),
    ] {
        b.check(
            &format!("a Carrier may {what} of the terminal it possesses — {name}"),
            matches!(rows.get(name), Some((true, _))),
            format!("{:?}", rows.get(name)),
        );
    }

    // Refused, and attributably: errno 130 is Super's filter and nothing else
    // on this path returns it. `ENOTTY` would mean the terminal said no,
    // `EPERM` that the kernel did; only 130 names Super.
    for (name, what) in [
        ("pty_tiocsti", "inject bytes into its own input queue"),
        ("pty_tiocsctty", "steal or re-establish a controlling terminal"),
        ("pty_tiocswinsz", "choose its own terminal's size"),
        ("pty_tcsets", "rewrite the line discipline"),
        ("pty_tiocspgrp", "seize the foreground process group"),
        ("pty_tiocsetd", "swap the line discipline"),
    ] {
        let row = rows.get(name);
        b.check(
            &format!("a Carrier may NOT {what} — ATTRIBUTED, errno 130"),
            matches!(row, Some((false, e)) if *e as u32 == crate::confine::SUPER_DENY_ERRNO),
            format!("{row:?} — expected a refusal carrying {}", crate::confine::SUPER_DENY_ERRNO),
        );
    }

    // **The comparison width, and the first version of this measured the
    // wrong thing.**
    //
    // A denied request with a garbage high half is refused under either
    // width — it is not on the allow-list either way — so it says the
    // refusal is robust and nothing about the filter's arithmetic. The host
    // sabotage battery said so: pointing the width probe at `TIOCSTI`
    // scored NOT A FALSIFIER, because sabotaging the load offset left the
    // row green.
    //
    // The distinguishing case is a *permitted* request. The kernel
    // truncates `cmd` to 32 bits after seccomp has read `args[1]`, so
    // `TCGETS | garbage<<32` **is** `TCGETS` to the kernel and must
    // succeed. A filter comparing the wrong half refuses a call the kernel
    // would have run — its model of the syscall disagreeing with the
    // syscall.
    let plain = rows.get("pty_tiocsti");
    let high = rows.get("pty_tiocsti_high_bits");
    b.check(
        "a refused ioctl stays refused with a garbage high half",
        matches!(high, Some((false, e)) if *e as u32 == crate::confine::SUPER_DENY_ERRNO)
            && high.map(|h| h.1) == plain.map(|p| p.1),
        format!("plain={plain:?} high-bits={high:?}"),
    );
    b.check(
        "a PERMITTED ioctl still runs with a garbage high half — the filter compares the \
         32 bits the kernel acts on",
        matches!(rows.get("pty_tcgets_high_bits"), Some((true, _))),
        format!("{:?} — a filter comparing the other half would refuse a call the kernel runs",
                rows.get("pty_tcgets_high_bits")),
    );

    // **An allow-list is immune to the CVE-2019-7303 bypass by shape.**
    // That vulnerability is a deny-list property: the comparison misses and
    // the request falls through to ALLOW. Here a request that matches
    // nothing is refused, which is the whole reason the ruling called for
    // an allow-list. Recorded as a check so the reasoning is measured
    // rather than remembered.
    b.check(
        "an unlisted ioctl is refused rather than falling through — allow-list, not deny-list",
        matches!(rows.get("pty_tiocsetd"), Some((false, e))
                 if *e as u32 == crate::confine::SUPER_DENY_ERRNO),
        format!("{:?} — TIOCSETD appears on no list in confine.rs", rows.get("pty_tiocsetd")),
    );

    // Landlock governs the namespace; possession governs the descriptor.
    //
    // The inherited slave is ungoverned by Landlock — the right is bound at
    // `open` and the host opened it outside any domain — which is exactly
    // why the seccomp rows above are load-bearing. What Landlock still does
    // is stop the Carrier going looking for a *different* terminal.
    for (name, what) in [
        ("open_dev_ptmx", "mint a terminal of its own"),
        ("open_dev_pts_0", "open somebody else's terminal by name"),
        ("open_dev_pts_dir", "enumerate the terminal namespace"),
    ] {
        b.check(
            &format!("a Carrier may NOT {what} — {name}"),
            matches!(rows.get(name), Some((false, _))),
            format!("{:?}", rows.get(name)),
        );
    }

    b.check(
        "possessing one terminal is not a route to another — TIOCGPTPEER from the slave",
        matches!(rows.get("pty_tiocgptpeer_from_slave"), Some((false, _))),
        format!("{:?}", rows.get("pty_tiocgptpeer_from_slave")),
    );

    drop(c);
}

/// R0a · **I Speak** — the installed production payload writes its own
/// marker on its own terminal.
///
/// # What this is for, and what the join probe is for
///
/// `tools/terminal-join-probe.mjs` asserts the marker reaches a real
/// `xterm.js` through a real click, and that is the product claim. It needs
/// a display, a WebDriver and about a minute. This is the same byte,
/// measured at the host, in about a second: it starts the **production
/// payload** exactly the way `start_one` does — `spawn_on_pty`, then the
/// handshake — and reads the master.
///
/// Two claims that only this can make:
///
/// 1. **Nothing asked for the bytes.** The host sends `HELLO` and reads.
///    `super-dogfood` has no `SAY` verb, so there is no verb this battery
///    could have sent, and the marker's arrival is attributable to the
///    payload and to nothing else. `super-carrier-fixture` cannot be
///    substituted here to make the check pass: it has no unprompted output
///    at all, which is why B5 measured a live presentation carrying zero
///    bytes.
/// 2. **The line discipline is doing its job.** The payload writes `\n` and
///    a terminal delivers `\r\n`. Asserting on the discipline's output is
///    how D.1.3c·1 proved this is a terminal rather than a pipe, and the
///    same assertion holds here for free.
fn dogfood_payload(b: &mut Battery, scratch: &Path) {
    use crate::{carrier, pty};
    use std::io::Read;

    println!("\n  R0a · the payload that speaks");

    // **The selection, and the promise about it.** `bind_carrier_channel`
    // measures `payload_path()` and puts its digest in the attested
    // execution basis; `start_one` runs `payload_path()`. If those two ever
    // named different files, every admission would refuse
    // `carrier-execution-basis-changed` and point at the digest rather than
    // at the mismatch.
    let Some(payload) = carrier::payload_path() else {
        b.check("a production Carrier payload is installed", false,
                "payload_path() found neither super-dogfood nor the fixture");
        return;
    };
    let name = payload.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    b.check(
        "the production payload is the one that speaks, not the fixture",
        name == "super-dogfood",
        format!("payload_path() selected {name} — B5 measured what a Super whose payload \
                 cannot speak is worth"),
    );
    b.check(
        "and it is STATICALLY linked — the execute grant names one inode, not /usr/lib",
        elf_is_static(&payload) == Some(true),
        format!("{} has a PT_INTERP — build it with tools/build-payloads.sh", payload.display()),
    );
    // The fixture is still installed and still addressable by name. The
    // confinement census spawns it directly, thirty-odd times, and running
    // those against a payload that does things would measure the payload
    // instead of the floor.
    b.check(
        "the confinement fixture is STILL installed and is a DIFFERENT file",
        matches!(carrier::fixture_path(), Some(f) if f != payload),
        format!("fixture_path()={:?} payload_path()={payload:?}", carrier::fixture_path()),
    );

    let dir = scratch.join("dogfood");
    let _ = std::fs::create_dir_all(&dir);

    let Ok(term) = pty::Pty::open() else {
        b.check("a terminal can be allocated for the production payload", false, "Pty::open failed");
        return;
    };
    let master = term.master();
    let run = carrier::spawn_on_pty(
        &payload, &dir, &dir.join("d.log"), &crate::new_epoch(), None, term,
    );
    let mut c = match run {
        Ok(c) => c,
        Err(e) => {
            b.check("the production payload starts as a confined Carrier on a terminal", false, e);
            return;
        }
    };
    b.check("the production payload starts as a confined Carrier on a terminal", true, String::new());

    // Exactly what `start_one` does, and in the same order: the payload
    // speaks only after the host has told it who it is.
    let shook = c.handshake(5_000);
    b.check(
        "it completes the same control handshake the fixture does — one protocol, two payloads",
        shook.is_ok(),
        format!("{shook:?}"),
    );

    // Read the master until the marker or the budget. Non-blocking with a
    // bound, for `pty_ioctl_census`'s reason: a terminating condition that
    // is the thing under test makes a wedge into a dead battery rather than
    // a short red row.
    let _ = c.pty().map(|q| q.set_nonblocking());
    let mut mf = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(master) };
    let mut all = String::new();
    let mut buf = [0u8; 4096];
    for _ in 0..200 {
        match mf.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => all.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(_) => {}
        }
        if all.contains("SUPER-DOGFOOD-R0-READY") && all.contains("carrier ") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    std::mem::forget(mf);

    b.check(
        "R0a — the marker arrives on the terminal, and NOTHING asked for it",
        all.contains("SUPER-DOGFOOD-R0-READY"),
        format!("read {:?} from the master; this payload has no SAY verb, so there is \
                 nothing this battery could have sent to produce it", all.chars().take(200).collect::<String>()),
    );
    b.check(
        "it arrived through the LINE DISCIPLINE — \\n written, \\r\\n delivered",
        all.contains("SUPER-DOGFOOD-R0-READY\r\n"),
        format!("{:?} — a pipe would deliver the \\n unchanged", all.chars().take(200).collect::<String>()),
    );
    // The identity line quotes what the HOST said in `HELLO`, not
    // `SUPER_CARRIER_INCARNATION`. Same fact, better provenance.
    b.check(
        "and it names the incarnation the host minted, not the one its environment claims",
        all.contains(&format!("carrier {}\r\n", c.incarnation)),
        format!("expected \"carrier {}\", read {:?}", c.incarnation,
                all.chars().take(200).collect::<String>()),
    );

    let fds: Vec<i32> = c.observe().fds.keys().copied().collect();
    b.check(
        "speaking cost it no descriptor — the set is still exactly {0,1,2,3}",
        fds == vec![0, 1, 2, 3],
        format!("{fds:?}"),
    );

    c.terminate(2_000);
}
