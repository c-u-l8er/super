defmodule Ampd.Carrier.Machine do
  @moduledoc """
  What actually starts and stops a Carrier process.

  Modelled on `Ampd.Worktree.Effector` and for the same reasons: one narrow
  behaviour, a production implementation that possesses a channel, and a
  reference/harness implementation that a test selects explicitly. The
  compiled default is the channel; `E12` asserts that so the harness cannot
  quietly become the rule.

  ## Why a channel of its own, and not the D.1.3a effect channel

  D.1.3a recorded this as the next thing that would break, verbatim:

      EffectChannel.await/4 **skips** a non-matching observation rather than
      routing it, so it is a filter and not a demultiplexer, and a concurrent
      reader could consume and discard another caller's frame.

  It was safe there only because `Worktree.create` is serialized by
  `@ordered_ops`. D.1.3b·2 makes it unsafe: the machine phase is deliberately
  *outside* the total order, so a Carrier start can be in flight while a
  worktree creation is submitted, and the two would be reading one stream.

  Of the three options — single owner plus demultiplexer, serialized
  submission, or a channel per operation — **this takes the third**, because
  it removes the hazard structurally instead of managing it. A demultiplexer
  would be a new supervised process whose whole job is to make a shared
  resource safe to share; serializing submissions would put Carrier latency
  back in front of worktree creation, which is most of what leaving the total
  order was for.

  The cost is one bridge command, and it reuses `bind_effect_channel`'s
  machinery exactly — the same socketpair, the same `SCM_RIGHTS`, the same
  adoption path, the same framing. **No new descriptor mechanism.**

  ## The half this originally got wrong

  A separate channel fixes concurrency **between** protocols and does nothing
  about concurrency **within** one. This moduledoc used to end:

      Within this channel there is exactly one submitter, so `await`'s filter
      semantics remain sufficient.

  That was an aspiration stated as a fact. `Bridge.carrier_endpoint/0` is one
  shared socket and the machine phase runs in the calling process, so two
  Peers starting Carriers at once both drove `send → recv(4) → recv(n)` on one
  stream — able to interleave *between the header and the body*, so a frame
  can be torn rather than merely misdelivered.

  `Ampd.Carrier.Machine.Gate` is what makes the sentence true: one process
  owns every submission, so there is one submitter by construction rather than
  by hope. Nothing calls `Channel.start/1` directly.
  """

  @type ticket :: map()
  @type observation :: map()

  @doc "Start a Carrier for an admitted ticket. Unbounded; not ordered."
  @callback start(ticket) :: {:ok, observation} | {:error, String.t()}

  @doc """
  The identity of the Carrier implementation this machine would launch.

  `carrier-execution-basis@1`. Bound into the ticket by Transaction A and
  compared against what actually ran by Transaction B.

  **This submits nothing and waits for nothing.** It reads metadata the host
  supplied when the channel was established, which is why it is safe to call
  from inside the total order and does not go through
  `Ampd.Carrier.Machine.Gate` — a basis question that took a machine round
  trip would put machine latency back inside the coordinator by the one route
  the whole admit/machine/commit shape exists to close.

  `{:error, why}` refuses the admission. A basis that cannot be established is
  not a basis that may be skipped: an admission with nothing bound is exactly
  the state this callback exists to make impossible.
  """
  @callback execution_basis() :: {:ok, map()} | {:error, String.t()}

  @doc """
  Make the machine's physical Carrier set empty, and answer only once it is.

  For one failure cut and no other: the runtime's `Ampd.Peer` incarnation
  itself is lost, taking every semantic membership and the pending-reap ledger
  with it, while the machine side goes on holding processes. There are no
  victims to name because the records that named them are gone — so this
  names none, and empties the set.

  ## Why this one may be retried when a start may not

      start    constructive     retrying it might make a second process
      drain    subtractive      retrying it cannot create or widen anything

  Every successful execution moves toward the same no-authority state, and
  the request carries no actor, Locus, Worker or grant because there is
  nothing here to authorize. So a lost confirmation is retried until absence
  is established, where a lost *start* confirmation is never retried and
  becomes `INDETERMINATE` instead.

  > Constructive effects are not silently replayed. Idempotent destructive
  > convergence may be retried, because every successful execution moves only
  > toward the same no-authority state.

  `{:ok, %{"remaining" => 0}}` is the only answer that ends a fence.
  """
  @callback drain(runtime_epoch :: String.t()) :: {:ok, map()} | {:error, String.t()}

  @doc """
  Stop a Carrier.

  Takes the ticket-or-incarnation and the observation, because a stop may be
  needed for a process that never became an incarnation — the refused-commit
  path.

  `:ok` means **the host confirmed the process is gone**, including the case
  where there was nothing to stop. `{:error, why}` means the outcome is
  unknown, and the caller must treat that the way an ambiguous start is
  treated: no replacement until absence is established. An earlier version
  returned `:ok` unconditionally, which made a lost confirmation
  indistinguishable from a confirmed reap — the same defect on the stop side
  that `unresolved/0` closes on the start side.
  """
  @callback terminate(map(), observation) :: :ok | {:error, String.t()}
end

defmodule Ampd.Carrier.Machine.Channel do
  @moduledoc """
  The production machine: a possessed Carrier channel to the real host.

  Holds no authority and decides nothing. It submits a request carrying the
  ticket's carrier ref and epoch, and returns whatever the host observed.
  `Ampd.Carrier.commit_start/2` decides whether that observation may join the
  World; nothing here can.

  As in D.1.3a, the request carries **no authorization field and there is no
  place in this path to add one** — that is the point of the shape, not a
  property of the current field list.
  """
  @behaviour Ampd.Carrier.Machine

  alias Ampd.Bridge

  @protocol "carrier-lifecycle"
  @protocol_version 1

  def protocol, do: @protocol
  def protocol_version, do: @protocol_version

  # Shorter than the effect channel's 10 s: starting a static fixture and
  # reading one handshake line is not a git operation. It is still a bound
  # and not an architecture — the machine phase is outside the total order,
  # so exceeding this produces INDETERMINATE rather than a raise inside it.
  @deadline_ms 8_000
  def deadline_ms, do: @deadline_ms

  @impl true
  def start(ticket) do
    submit(%{
      "schema" => "carrier-start-request@1",
      "op" => "start",
      "carrier_ref" => ticket["carrier_ref"],
      "carrier_epoch" => ticket["carrier_epoch"],
      # Stamped by `Ampd.Carrier.Machine.Gate`, which is the process that
      # knows which runtime incarnation the machine side is synchronized to.
      # The host refuses a start under an epoch other than the one its
      # physical set belongs to while that set is non-empty.
      "runtime_epoch" => ticket["runtime_epoch"]
    })
  end

  @impl true
  def drain(runtime_epoch) do
    case submit(%{
           "schema" => "carrier-runtime-drain-request@1",
           "op" => "drain",
           "runtime_epoch" => runtime_epoch
         }) do
      {:ok, %{"remaining" => 0} = o} -> {:ok, o}
      {:ok, other} -> {:error, "the host did not confirm an empty carrier set: #{inspect(other)}"}
      {:error, why} -> {:error, why}
    end
  end

  @basis_schema "carrier-execution-basis@1"
  def basis_schema, do: @basis_schema

  @doc """
  The Carrier execution basis the host measured when it established this
  channel.

  Read off the possessed endpoint's incarnation — no frame, no deadline, no
  ambient lookup. `Ampd.Bridge` accepted it at the boundary or refused the
  channel, so anything reaching here is already shaped; the guard is here
  anyway because a basis that is `nil` must refuse an admission rather than
  bind a `nil`, and that is a different failure from a malformed bind.
  """
  @impl true
  def execution_basis do
    case Bridge.carrier_endpoint() do
      nil ->
        {:error, "no host carrier channel is possessed, so no carrier implementation is admitted"}

      %{incarnation: inc} ->
        case inc["carrier_basis"] do
          %{"schema" => @basis_schema} = b -> {:ok, b}
          other -> {:error, "the carrier channel carries no execution basis: #{inspect(other)}"}
        end
    end
  end

  @impl true
  def terminate(subject, obs) do
    case submit(%{
           "schema" => "carrier-stop-request@1",
           "op" => "stop",
           "carrier_ref" => subject["carrier_ref"],
           "carrier_epoch" => subject["carrier_epoch"],
           "host_process_ref" => obs["host_process_ref"]
         }) do
      {:ok, %{"stopped" => true}} -> :ok
      {:ok, other} -> {:error, "the host did not confirm the stop: #{inspect(other)}"}
      {:error, why} -> {:error, why}
    end
  end

  defp submit(body) do
    case Bridge.carrier_endpoint() do
      nil ->
        {:error,
         "no host carrier channel is possessed — refusing to resolve and execute the host by name instead"}

      %{sock: sock, incarnation: inc} ->
        # The Carrier protocol's own observation schema. Passing it is what
        # makes the shared correlation machinery reusable rather than
        # worktree-specific — see `EffectChannel.match/6`.
        expect =
          case body["op"] do
            "stop" -> "carrier-stop-observation@1"
            "drain" -> "carrier-runtime-drain-observation@1"
            _ -> "carrier-start-observation@1"
          end

        Ampd.Worktree.EffectChannel.request(sock, inc, body, @deadline_ms, expect)
    end
  end
end

defmodule Ampd.Carrier.Machine.Harness do
  @moduledoc """
  A scriptable machine, for the fault matrix.

  **Not a mock of the host.** It answers the same shape the host answers and
  is selected explicitly by a test, exactly as `Effector.Host` is. Fault
  injection needs a machine that can be told to be slow, to die, or to return
  an observation belonging to a different start — which a real host is not,
  and which is why D.1.3a split the positive path and the fault matrix
  between the host and a harness in the first place.

  The policy is a 1-arity function over the request, so a test writes the
  fault it wants rather than selecting from an enum this module guessed at.
  """
  @behaviour Ampd.Carrier.Machine

  def put_policy(f) when is_function(f, 1), do: :persistent_term.put({__MODULE__, :policy}, f)
  def clear_policy, do: :persistent_term.erase({__MODULE__, :policy})
  def policy, do: :persistent_term.get({__MODULE__, :policy}, &default/1)

  def started, do: :persistent_term.get({__MODULE__, :started}, [])
  def terminated, do: :persistent_term.get({__MODULE__, :terminated}, [])

  @doc "Runtime epochs this harness was asked to drain, in order."
  def drained, do: :persistent_term.get({__MODULE__, :drained}, [])

  @doc """
  Make the next N drains report a lost confirmation.

  For the lost-acknowledgement fence test: the machine really emptied its set
  and the answer did not come back, which must leave the Gate fenced and
  retrying rather than believing itself converged.
  """
  def drain_fails(n), do: :persistent_term.put({__MODULE__, :drain_fails}, n)

  def reset do
    clear_policy()
    :persistent_term.erase({__MODULE__, :stop_result})
    :persistent_term.erase({__MODULE__, :basis})
    :persistent_term.erase({__MODULE__, :drain_fails})
    :persistent_term.put({__MODULE__, :started}, [])
    :persistent_term.put({__MODULE__, :terminated}, [])
    :persistent_term.put({__MODULE__, :drained}, [])
  end

  @impl true
  def drain(runtime_epoch) do
    :persistent_term.put({__MODULE__, :drained}, drained() ++ [runtime_epoch])

    case :persistent_term.get({__MODULE__, :drain_fails}, 0) do
      n when n > 0 ->
        # **The set really is emptied first.** A harness that skipped the work
        # when it was told to lose the reply would model a host that refused,
        # not a host whose answer went missing — and the fence's whole point
        # is that those two are indistinguishable from the runtime's side.
        :persistent_term.put({__MODULE__, :drain_fails}, n - 1)
        {:error, "the host did not answer the drain"}

      _ ->
        {:ok, %{"schema" => "carrier-runtime-drain-observation@1", "remaining" => 0, "reaped" => 0}}
    end
  end

  @doc """
  The basis a healthy harness installs.

  `payload_digest` is a fixed value rather than a random one so that
  `observation/2` and `execution_basis/0` agree by construction. A harness
  whose two halves minted independent identities would refuse every commit and
  the falsifiers would all pass for the wrong reason.
  """
  def default_basis do
    %{
      "schema" => Ampd.Carrier.Machine.Channel.basis_schema(),
      "payload_digest" => "sha256:" <> String.duplicate("ab", 32),
      "carrier_protocol" => "carrier-lifecycle",
      "carrier_protocol_version" => 1
    }
  end

  @doc "Script the admission-time basis, for the execution-identity falsifiers."
  def put_basis(b), do: :persistent_term.put({__MODULE__, :basis}, b)

  @impl true
  def execution_basis, do: :persistent_term.get({__MODULE__, :basis}, {:ok, default_basis()})

  @impl true
  def start(ticket) do
    :persistent_term.put({__MODULE__, :started}, started() ++ [ticket["carrier_ref"]])
    policy().(ticket)
  end

  @impl true
  def terminate(subject, _obs) do
    :persistent_term.put({__MODULE__, :terminated}, terminated() ++ [subject["carrier_ref"]])
    :persistent_term.get({__MODULE__, :stop_result}, :ok)
  end

  @doc "Make the next stop report an unknown outcome, for the ambiguity tests."
  def stop_returns(v), do: :persistent_term.put({__MODULE__, :stop_result}, v)

  @doc """
  What a healthy host returns: the ticket's own identity echoed back, and a
  confinement observation that satisfies the floor.
  """
  def default(ticket), do: {:ok, observation(ticket)}

  def observation(ticket, overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "carrier-start-observation@1",
        "carrier_ref" => ticket["carrier_ref"],
        "carrier_epoch" => ticket["carrier_epoch"],
        "host_process_ref" => "hp_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)),
        "observed" => %{
          "no_new_privs" => true,
          "seccomp_mode" => 2,
          "seccomp_filters" => 1,
          "fds" => %{"0" => "/dev/null", "1" => "log", "2" => "log", "3" => "socket:[4242]"},
          "env_keys" => ["SUPER_CARRIER_CONTROL_FD", "SUPER_CARRIER_INCARNATION"],
          "uid" => 1000,
          "cwd" => "/tmp/harness-carrier-workdir",
          "starttime" => 1
        },
        # The attestation the real host makes. Present here so the harness
        # exercises `Ampd.Carrier.Floor` rather than bypassing it — a fault
        # matrix that skipped the floor would be testing a different commit
        # path from the one production uses.
        "attested" => %{
          "schema" => "carrier-confinement-attested@1",
          "landlock_abi" => 9,
          "landlock_handled_fs" => "0x1ffff",
          "landlock_handled_net" => "0x3",
          "landlock_scoped" => "0x3",
          "landlock_grants" => [%{"path" => "/tmp/x", "access" => "0x41be"}],
          "seccomp_deny_errno" => 130,
          "pdeathsig" => "SIGKILL",
          "network" => "none",
          "attestor" => "super-host",
          # The correspondence rows compare observation against attestation,
          # so the harness has to supply both halves consistently — otherwise
          # it would exercise a shorter floor than production does, which is
          # exactly the divergence that let the real host ship with no
          # attestation at all.
          "expected_uid" => 1000,
          "control_inode" => 4242,
          # What the harness says actually ran. Equal to `default_basis/0` by
          # construction — a start whose execution basis matched nothing would
          # refuse every commit, and the fault matrix would then be measuring
          # this module rather than the runtime.
          "execution_basis" => default_basis(),
          "workdir_identity" =>
            :crypto.hash(:sha256, "/tmp/harness-carrier-workdir") |> Base.encode16(case: :lower)
        }
      },
      overrides
    )
  end
end


defmodule Ampd.Carrier.Machine.Gate do
  @moduledoc """
  One owner for the Carrier lifecycle channel.

  ## The claim this exists to make true

  `Ampd.Carrier.Machine.Channel` said, in a comment:

      Within this channel there is exactly one submitter, so `await`'s filter
      semantics remain sufficient.

  **That was not true, and review caught it.** The machine phase deliberately
  runs outside the total order, and `Bridge.carrier_endpoint/0` is one shared
  socket, so two Peers starting Carriers at the same time both executed

      :socket.send  →  :socket.recv(4)  →  :socket.recv(n)

  against one stream. Two readers can interleave *between the header and the
  body*, so it is not merely that a reply could go to the wrong caller — a
  frame can be torn in half. `EffectChannel.await/4` discards a non-matching
  observation rather than routing it, which is safe with one submitter and is
  not a demultiplexer.

  Giving the Carrier its own channel fixed cross-protocol concurrency and did
  nothing for concurrency *within* the protocol. This is the part that was
  missing.

  ## Why a serializer and not a demultiplexer

  A demultiplexer is the right answer when many starts must overlap. Nothing
  needs that yet: a Carrier start is a fixture spawn and a one-line handshake.
  A serializer is the smaller thing that makes the precondition true, and it
  makes it true *structurally* — there is one process, so there is one
  submitter, so the sentence in `Channel` stops being an aspiration.

  **Machine duration still leaves the global total order.** This serializes
  Carrier lifecycle submissions against each other and nothing else; worktree
  effects are on their own channel and are unaffected. The cost is that N
  concurrent starts take N times one start, which is recorded rather than
  hidden — if that ever matters, build the demultiplexer then.

  This is +1 supervised process and is counted as such in the census.

  ## A DECLARED SCALABILITY SEAM — read this before Motor startup

  Two numbers bound this, and they do not compose the way a reader expects:

  ```text
  machine request deadline    8 s     Ampd.Carrier.Machine.Channel
  gate caller timeout        20 s     here
  ```

  A caller queued behind two slow starts waits ~16 s before its own ~8 s
  begins, so with three or more concurrent slow starts a `GenServer.call`
  here can time out. That is caught and typed:

  ```text
  caller timeout  →  INDETERMINATE  →  replacement blocked  →  reconciliation
  ```

  which fails safe, and is why this is a seam and not a defect.

  **The part worth knowing is Erlang-specific.** A timed-out `GenServer.call`
  does not cancel the queued request. This process will still reach that
  message and still ask the host to start a Carrier, *after* the caller has
  already classified the attempt as indeterminate. So a physical process can
  come into existence for an attempt the runtime has given up on. Uniqueness
  survives — `INDETERMINATE` is in `Ampd.Carrier.unresolved/0`, so no
  replacement is admitted, and reconciliation establishes absence by asking
  the host to kill it — but the safety comes from the *ambiguity handling*,
  not from the queue.

  **A fixed caller timeout wrapped around an unbounded serializer queue is
  not the architecture for concurrent Motor or model startup**, where a start
  is expensive rather than a fixture spawn and a one-line handshake. Before
  that boundary, one of:

    * queued asynchronous lifecycle requests with durable correlation, so a
      caller that stops waiting is a caller that can still be answered; or
    * the real single-reader demultiplexer, so starts overlap instead of
      queueing.

  Not built here. The first PTY slice does not materially raise Carrier-start
  concurrency, so this holds for it; it does not hold for Motor.

  ## The incarnation fence — D.1.3b·2d

  `Ampd.Peer` can die and be restarted by the supervisor while this process,
  `Ampd.Bridge`, the Carrier channel and the host all go on existing. Its
  replacement starts with empty `carriers` and empty `pending_reaps`, so:

  ```text
  World / Worker / Locus     still exist
  the new Peer knows         no Carrier
  the host knows             the old Carrier is still running
  ```

  which is the split-brain the whole D.1.x sequence exists to remove. The
  Reaper's `pending_reaps` cannot reach it: that ledger lives in the process
  that died, along with every record of which Carriers existed.

  **This process is where it is closed, and the reason is structural**: it
  already survives `Ampd.Peer` under `:one_for_one`, it is already the single
  owner of Carrier lifecycle submissions, and it holds no product authority.
  It gains one responsibility and no authority:

  ```text
  Peer incarnation P1                     Gate READY, bound to P1
        ↓ dies
  Gate :DOWN                              Gate FENCED
        ↓
  drain: make the physical set empty      retried until it answers empty
        ↓
  replacement Peer P2 observed            Gate binds P2
        ↓
  Gate READY                              starts admitted again
  ```

  **Not `:rest_for_one`.** Coupling the physical Carrier lifetime to the Peer
  incarnation by restarting the fourteen children after `Ampd.Peer` would
  restart authority coordinators, durable registries, Loci, Worktree and the
  Bridge — a World reboot to express one relationship. The distinction being
  preserved is exactly:

  ```text
  Peer restart  ≠  World restart
  Peer incarnation death  →  Carrier physical death
  ```

  **No victims are named.** `Ampd.Peer` dying loses every semantic membership
  at once, so `terminate_all` is not a blunt instrument here — it is the only
  correct one. Reconstructing victim IDs from records that deliberately no
  longer exist is the thing that cannot be done.

  This is distinct from `pending_reaps`, which remains correct for a Reaper
  restart, an individual session loss, `detach`, `close_worker` and ordinary
  membership convergence. Two different failure cuts, two mechanisms; merging
  them into one vague "cleanup" would lose which one protects what.
  """
  use GenServer

  require Logger

  # Longer than the machine's own deadline, and by more than one machine
  # wait, because a caller may be queued behind one other start. A caller
  # whose timeout is shorter than the work it is waiting for produces a
  # `GenServer.call` exit rather than the typed refusal the machine returns.
  @call_timeout_ms 20_000
  def call_timeout_ms, do: @call_timeout_ms

  # How long to wait before retrying an unresolved drain. A drain is
  # idempotent and subtractive, so retrying is safe; see the `drain/1`
  # callback docs for why that is not true of `start`.
  @refence_ms 250

  @readiness {__MODULE__, :readiness}

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Is the machine side synchronized to this runtime incarnation?

  **Local, bounded, and no message to this process.** `Ampd.Carrier.admit/2`
  calls it from inside `AuthorityCoordinator.transact/1`, and this process may
  be in the middle of an 8-second drain — a `GenServer.call` here would put
  machine latency inside the total order by the one route the whole
  admit/machine/commit shape exists to close.

  It reads a term this process publishes on every transition. That also makes
  it correct while this process is *down*: the published epoch is the one the
  machine side was last synchronized to, so a Peer that has since been
  replaced fails the comparison whoever is or is not alive.
  """
  def ready_for?(peer_epoch) do
    :persistent_term.get(@readiness, {:fenced, nil}) == {:ready, peer_epoch}
  end

  @doc "The fence state, for falsifiers and the operator projection."
  def readiness, do: :persistent_term.get(@readiness, {:fenced, nil})

  @doc """
  The peer registry's incarnation changed without the process dying.

  `Ampd.Peer.reset/0` mints a fresh epoch in place — a world reset, a lineage
  advance — so no `:DOWN` fires and the monitor cannot see it. Without this
  the Gate would stay bound to an epoch nobody is using and `ready_for?/1`
  would refuse every admission until something else nudged it.

  A cast: `Peer.reset/0` runs inside the `Ampd.Peer` GenServer, and nothing
  about re-establishing identity may wait on a machine deadline. That is the
  same rule the orphan announcement two lines above it follows.
  """
  def peer_incarnation_changed, do: GenServer.cast(__MODULE__, :peer_incarnation_changed)

  @doc """
  Force convergence and report the fence state. **Not a production path.**

  The recovery above is asynchronous by design, so a test or a battery that
  wants to observe the state *after* it settles needs a barrier — the same
  role `Ampd.Carrier.Reaper.drain/1` plays for the reaper.
  """
  def sync(timeout \\ @call_timeout_ms), do: GenServer.call(__MODULE__, :sync, timeout)

  @impl true
  def init(:ok) do
    # Fenced until proven otherwise. The alternative — assume ready and let
    # the first start find out — is the direction that starts a process.
    #
    # **Nothing about witnessing lives here.** A fresh Gate has witnessed
    # nothing and must not manufacture a discontinuity out of its own restart
    # — that is the boot regression recorded in `converge/1`. The record of a
    # transition lives in the published term, which outlives this process
    # precisely so that a Gate arriving here after one still finds it.
    {:ok, %{peer_pid: nil, peer_epoch: nil, lifecycle: :fenced}, {:continue, :bind_peer}}
  end

  @impl true
  def handle_continue(:bind_peer, st), do: {:noreply, converge(st)}

  def start(ticket), do: call({:start, ticket})
  def terminate_carrier(subject, obs), do: call({:terminate, subject, obs})

  # A gate that is not running must refuse by name rather than crash its
  # caller, for the reason `Ampd.Embodiment` gives: a crash masks a probe.
  defp call(msg) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, msg, @call_timeout_ms)
      catch
        :exit, _ -> {:error, "the carrier machine gate did not answer in time"}
      end
    else
      {:error, "the carrier machine gate is not running"}
    end
  end

  @impl true
  def handle_call({:start, _ticket}, _f, %{lifecycle: :fenced} = st) do
    # Belt to `Ampd.Carrier.admit/2`'s braces. Admission refuses before it
    # writes a ticket, so this should be unreachable — but "should be
    # unreachable" is how a start reaches a machine that is not synchronized
    # with the runtime that is asking.
    {:reply,
     {:error,
      "the carrier machine is fenced: the physical carrier set has not been " <>
        "established empty since the runtime incarnation changed"}, st}
  end

  def handle_call({:start, ticket}, _f, st) do
    # The runtime epoch is stamped here and nowhere else, because this is the
    # process that knows which incarnation the machine side is synchronized
    # to. A ticket carrying its own would be a ticket asserting something the
    # admission had no way to check.
    ticket = Map.put(ticket, "runtime_epoch", st.peer_epoch)
    {:reply, Ampd.Carrier.machine().start(ticket), st}
  end

  # **Reachable while fenced, deliberately.** A stop only subtracts physical
  # execution, and refusing it during a fence would strand exactly the
  # processes the fence exists to remove.
  def handle_call({:terminate, subject, obs}, _f, st),
    do: {:reply, Ampd.Carrier.machine().terminate(subject, obs), st}

  def handle_call(:sync, _f, st) do
    st = converge(st)
    {:reply, {st.lifecycle, st.peer_epoch}, st}
  end

  @impl true
  def handle_cast(:peer_incarnation_changed, st), do: {:noreply, converge(witness(st))}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{peer_pid: pid} = st) do
    Logger.warning(
      "ampd: the peer registry incarnation died (#{inspect(reason)}) — fencing carrier " <>
        "lifecycle and draining the physical carrier set before any replacement may start"
    )

    {:noreply, converge(witness(%{st | peer_pid: nil}))}
  end

  def handle_info(:refence, st), do: {:noreply, converge(st)}
  def handle_info(_, st), do: {:noreply, st}

  # ------------------------------------------------------------- the fence
  #
  # **An observed transition outranks a compared token.**
  #
  # Both ways of learning that the incarnation changed — the monitor's
  # `:DOWN` and `Ampd.Peer.reset/0`'s cast — are themselves the proof that a
  # discontinuity happened. Until this existed, `converge/1` threw that
  # evidence away and re-derived the same conclusion from epoch *inequality*,
  # which is a strictly weaker source: if the replacement minted the value
  # that died, the identifier said `P1 == P2` while the event said
  # `P1 ≠ P2`, and the fence the whole slice exists for did not go up.
  # Widening the epoch to 128 bits (`Ampd.Peer.new_epoch/0`) makes that
  # collision negligible; it does not make deducing a fact we were *told*
  # from the accidental inequality of a random number the right shape.
  #
  # **One line, and it was written as two.** The first draft carried a
  # `witnessed` flag in this process's state *as well as* this publish, on
  # the theory that two mechanisms are safer than one. They are not, and the
  # sabotage battery is what says so: with both present neither can be
  # deleted and observed, because each silently does the other's job. A pair
  # of mechanisms that cannot be falsified apart is one mechanism and one
  # piece of decoration, and there is no way to tell from the source which is
  # which.
  #
  # The publish is the one that survives on its own merits:
  #
  #   · it decides the drain — `{:fenced, nil}` cannot match `{_, ^epoch}`
  #     for any epoch, so `converge/1` below reaches the drain branch no
  #     matter what the replacement minted;
  #   · it outlives *this process*, where a state field does not. A Gate that
  #     dies between witnessing and draining leaves the record behind in the
  #     `:persistent_term`, and the replacement Gate re-derives the fence
  #     from it rather than from a memory it never had;
  #   · it fences admission *immediately*. `drain/1` may block for the
  #     machine's whole deadline, and `Ampd.Carrier.admit/2` reads this term
  #     rather than messaging this process — so without this line an
  #     admission whose epoch happened to equal the published one is let
  #     through during the drain window and writes a durable
  #     `START_ADMITTED` ticket into an incarnation that is being left.
  #
  # Deleting it restores the defect exactly: the fence goes back to being
  # decided by comparing two random numbers.
  defp witness(st) do
    publish(:fenced, nil)
    %{st | lifecycle: :fenced}
  end

  # One function for every way of arriving here — boot, a `:DOWN`, a retry
  # after a lost confirmation. A convergence with one entry point per cause
  # is a convergence with one chance per cause of being got wrong.
  defp converge(st) do
    case Process.whereis(Ampd.Peer) do
      nil ->
        # No registry to be synchronized *to*. Stay fenced and look again;
        # this is the boot ordering and the middle of a supervisor restart,
        # and neither is a state to start a process in.
        publish(:fenced, nil)
        Process.send_after(self(), :refence, @refence_ms)
        %{st | lifecycle: :fenced, peer_pid: nil, peer_epoch: nil}

      pid ->
        case peer_epoch() do
          nil ->
            publish(:fenced, nil)
            Process.send_after(self(), :refence, @refence_ms)
            %{st | lifecycle: :fenced, peer_pid: nil, peer_epoch: nil}

          epoch ->
            # **The fence is a transition, not a starting state**, and getting
            # that wrong cost a whole verify run. The first version fenced
            # until a drain succeeded, including at boot — where this process
            # starts *before* `Ampd.Bridge`, so no Carrier channel is
            # possessed, so no drain can succeed, so the runtime spent its
            # startup refusing Carrier starts for a discontinuity that had not
            # happened. `super-host verify` failed the production World join
            # on `carrier-runtime-incarnation-unready`.
            #
            # What must be drained is a physical set belonging to an
            # incarnation we are *leaving*. The published term is what we were
            # last synchronized to; if there is none, this runtime has never
            # started a Carrier and there is nothing of its making to empty.
            #
            # Safe because the host holds the same invariant independently: it
            # refuses a start whose `runtime_epoch` differs from the one its
            # non-empty set belongs to. This process makes the convergence
            # prompt; the host is what makes it true.
            case :persistent_term.get(@readiness, nil) do
              {_, ^epoch} ->
                # Same incarnation and nothing witnessed: this is a restart of
                # *this* process, not of the Peer. Re-monitor and carry on.
                #
                # **Reachable after a witnessed transition only by collision
                # of a 128-bit token**, because `witness/1` above sets the
                # term to `{:fenced, nil}`, which never matches this. That is
                # the arithmetic the epoch's width is now sized for: the fence
                # rests on an *event* that was published, and the token only
                # has to distinguish incarnations for a Gate that restarted
                # with no memory of the event at all.
                publish(:ready, epoch)
                %{st | lifecycle: :ready, peer_pid: monitor(pid, st), peer_epoch: epoch}

              nil ->
                publish(:ready, epoch)
                %{st | lifecycle: :ready, peer_pid: monitor(pid, st), peer_epoch: epoch}

              {_, _left_behind} ->
                drain_then_ready(st, pid, epoch)
            end
        end
    end
  end

  defp drain_then_ready(st, pid, epoch) do
    case Ampd.Carrier.machine().drain(epoch) do
      {:ok, %{"remaining" => 0}} ->
        publish(:ready, epoch)

        Logger.info(
          "ampd: the physical carrier set is empty; carrier lifecycle is unfenced for " <>
            "runtime incarnation #{epoch}"
        )

        # **The witness is discharged here and nowhere else** — by the thing
        # it was demanding, an established empty physical set. Not by time,
        # not by a retry, and not by the replacement happening to be spelled
        # like the incarnation that died. The failure branch below republishes
        # `{:fenced, nil}`, so the demand outlives every unconfirmed attempt.
        %{st | lifecycle: :ready, peer_pid: monitor(pid, st), peer_epoch: epoch}

      other ->
        # **Retried, and this is the one lifecycle operation that may be.**
        # A drain carries no actor, Locus, Worker or grant and can only
        # subtract, so a second execution cannot make a process or widen an
        # authority — where a second *start* against an unknown first one is
        # exactly how you get two. Stay fenced until absence is established.
        Logger.warning(
          "ampd: the carrier drain did not confirm an empty set (#{inspect(other)}) — " <>
            "staying fenced and retrying; no carrier will start under #{epoch} until it does"
        )

        publish(:fenced, nil)
        Process.send_after(self(), :refence, @refence_ms)
        %{st | lifecycle: :fenced, peer_pid: monitor(pid, st), peer_epoch: nil}
    end
  end

  defp monitor(pid, %{peer_pid: pid}), do: pid

  defp monitor(pid, _st) do
    Process.monitor(pid)
    pid
  end

  # A `GenServer.call` to a process that may be mid-restart. Its absence is a
  # fence, not a crash — the `Ampd.Embodiment` rule again.
  defp peer_epoch do
    Ampd.Peer.epoch()
  catch
    :exit, _ -> nil
  end

  defp publish(state, epoch), do: :persistent_term.put(@readiness, {state, epoch})
end
