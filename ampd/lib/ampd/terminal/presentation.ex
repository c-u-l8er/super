defmodule Ampd.Terminal.Presentation do
  @moduledoc """
  D.1.3c·2c·1a — **who may look at a Worker's terminal, and how that is
  resolved from the one thing the page is allowed to name.**

  ## The relation, and what it is not

  D.1.3c·2c·0 measured that no existing relation lets the human-control Peer
  reach an agent Peer's terminal, and why one can never be derived from
  possession: the human-control Peer holds no actor (`Ampd.Peer`), so
  `Ampd.Worker.occupancy_of/3` refuses it, so it has no attachment. The
  predicate the original 2c design would have evaluated — *does the
  requesting Peer possess this attachment* — is structurally false for the
  operator and always will be.

  What is ruled instead is an **operator disclosure policy**, stated in the
  form the runtime can actually enforce:

  > The unique `:human_control` role for the current World may observe
  > terminal output belonging to a current Worker in the operator-visible
  > World.

  **It is deliberately NOT "the Peer that opened this Worker may observe
  it".** That proposition is unprovable here and a test claiming to prove it
  would be fiction: the human-control Peer has no actor, `worker@1` carries
  no opener identity, there is one control channel at a time, and a Worker
  outlives the control-channel incarnation that opened it. Nothing in the
  runtime records *which* person opened a position, so nothing can check it.

  ## The assumption this rests on, stated because it will expire

  **There is exactly one `:human_control` role at a time.** `Ampd.Peer`
  refuses a second claim while one is held, so "the human-control role" and
  "this human" are the same thing today. **If Super ever gains multiple human
  users or human identities, this policy must be revisited rather than
  silently inherited** — it would then read "any human may watch any Worker",
  which is a different and much larger claim than the one being made.

  `Ampd.TerminalPresentationTest`'s `T.10` reads that refusal off `Ampd.Peer`
  and fails if a second control channel ever becomes claimable, so the
  assumption cannot expire quietly.

  ## What the page designates

      worker_ref                    which position
      expected_worker_generation    which incarnation of it

  and nothing else. **`expected_worker_generation` is not authority.** It
  carries no permission and grants nothing; it is a freshness witness that
  says which Worker incarnation the page actually saw. Without it the two
  properties this slice must have are incompatible: a request naming only
  `worker_ref` cannot be refused for staleness, because the runtime has no
  way to know whether the page meant generation 3 or the generation 4 that
  replaced it. `close_worker` advances the generation
  (`Ampd.Worker.transition/3`), so a reopened position is a different
  incarnation with the same name, and silently following it is precisely the
  confused designation this refuses.

  Everything below `worker_ref` is **derived here, never supplied**:

      worker_ref + expected_worker_generation + the bound control connection
              │
      ┌───────┴──────────────────────────────── SEMANTIC · World only ──┐
      │       ▼  Loci.worker/1               worker-unknown             │
      │       ▼  generation == expected      worker-generation-stale    │
      │       ▼  status == "open"            worker-not-open            │
      │       ▼  occupancy                   worker-not-occupied        │
      │       ▼  occupying agent Peer                                   │
      │       ▼  Peer.carrier/1              carrier-not-present        │
      │       ▼  Peer.terminal_attachment/1  terminal-not-attached      │
      │       ▼  status == "ACTIVE"          terminal-not-possessed     │
      └───────┬──────────────────────────────────────────────────────────┘
      ┌───────┴──────────────────── STREAM OWNER · asks the byte process ┐
      │       ▼  stream owner phase          terminal-stream-not-active  │
      └──────────────────────────────────────────────────────────────────┘

  ## The split is a cost boundary, and it was measured after it was wrong

  The two halves are drawn where they are because **only the lower one can
  block**. Everything semantic is a question for `Ampd.Loci` and `Ampd.Peer`,
  registries that answer from state. The lower link asks
  `Ampd.Carrier.Terminal.stream_phase/1`, which asks the process that owns
  the terminal's bytes — and that process runs `:socket.recv/3` synchronously
  inside itself, so an owner with output flowing can take arbitrarily long to
  answer. `stream_phase/1` bounds the wait at one second and reads a timeout
  as `:active`, because a busy owner *is* an active owner.

  That is correct for **opening one presentation** and was wrong under
  `status_of/1`, which `Ampd.Worker.projected/1` calls **once per Worker** on
  every operator projection, inside an ordered observation. Sixteen Workers
  with busy terminals bought a badge with up to sixteen seconds of the total
  order. Measured in `probes/projection_latency.exs`.

  So the rule is:

      status_of/1     a hint      semantic only, non-blocking, "PRESENT"
      resolve/3       a decision  the whole chain, may refuse at the owner

  A control projection may be built as often as the world changes. Opening
  the data plane happens when a person asks for it. Those must not cost the
  same, and the word `"ACTIVE"` in a projection was what made them.

  The page never receives or supplies `peer_ref`, `attachment_ref`,
  `attachment_epoch`, `pty_epoch`, `carrier_ref`, `carrier_epoch`, a pid, a
  descriptor, or a `/dev/pts` path. `presentable/1` is what may cross to a
  page, and it carries the two identifiers the page already had.

  ## Refusing by distinct name at every link

  Every broken relation gets its own code rather than a shared "not
  available". A single code would make *the Worker closed* and *the terminal
  died* the same event to an operator, and they call for opposite responses.

  ## Read-only, and the reason that is a scope and not a stage

  This resolves **OBSERVE** and nothing else. Two neighbouring powers are
  deliberately absent and are not dormant here:

      OBSERVE   terminal output → human      this slice
      SHAPE     rows/cols → PTY, SIGWINCH    a later ruling
      DRIVE     input → terminal             a later ruling

  Resize is not passive: changing geometry raises `SIGWINCH` in the agent's
  processes and can change what they do. Input is larger still — it acts at
  the agent's position while the human-control Peer has no actor for those
  effects to be attributed to. Neither has an entry point in this module, so
  neither can be reached by supplying a different argument.
  """

  alias Ampd.{Loci, Peer, Refusal, Worker}

  @schema "terminal-presentation@1"

  @doc "The schema every presentation record carries."
  def schema, do: @schema

  @doc """
  Resolve a presentation for `peer`, or refuse by name.

  `peer` is the **bound connection's** peer record, supplied by
  `Ampd.Control` from the channel binding — never a caller argument. That is
  the whole of the identity check: an argument the caller chooses is not an
  identity.
  """
  def resolve(peer, worker_ref, expected_generation)
      when is_binary(worker_ref) and is_integer(expected_generation) do
    with :ok <- human_control(peer),
         {:ok, p} <- derive(worker_ref, expected_generation) do
      # **The control-channel incarnation is part of the basis, and it is
      # added HERE rather than in the chain because the chain has no peer.**
      # A presentation is opened by a person over a bound connection; when
      # that connection ends the person watching is gone, and a data plane
      # that outlived it would be output with nobody entitled to it on the
      # other end. `Ampd.Peer.owner_pid/1` is the process holding the socket,
      # so its death IS the channel closing — which is why the field is a
      # pid and not an id: an id would have to be looked up later, and by
      # then the answer is `nil` for both "closed" and "never existed".
      {:ok,
       Map.merge(p, %{
         "control_peer_ref" => peer["id"],
         "control_owner" => Peer.owner_pid(peer["id"])
       })}
    end
  end

  def resolve(_peer, _worker_ref, _expected),
    do: {:refused, refuse("terminal-presentation-malformed", %{})}

  # ------------------------------------------------------ the two chains

  # **The chain without the role check, and the split is not a convenience.**
  # `current?/1` and `status_of/1` re-derive a relation that has already been
  # authorised; making them call `resolve/3` meant handing it a synthetic
  # `%{"channel" => :human_control}` — constructing the very thing the check
  # looks for in order to get past it. A check you can satisfy by building
  # its argument is not a check, and leaving that pattern in the module
  # would teach the next caller to do it on a path where it matters.
  #
  # **Private, and `@doc false` was not enough.** For one commit this was a
  # public function carrying `@doc false`, immediately after the repair
  # above. Documentation is not confinement: `@doc false` hides a name from
  # `h Ampd.Terminal.Presentation` and changes nothing about who may call
  # it. The unauthorised half of a resolver that has just had a bypass
  # removed from it is the last thing that should be reachable from outside
  # the module, so it is `defp` and `tools/check-presentation-authority.mjs`
  # fails if it stops being.
  defp derive(worker_ref, expected_generation) do
    with {:ok, p} <- derive_semantic(worker_ref, expected_generation),
         :ok <- streaming(p) do
      {:ok, p}
    end
  end

  # **The semantic chain — every link the World can answer by itself.**
  #
  # Everything here is a question for `Ampd.Loci` and `Ampd.Peer`: registries
  # that hold records and answer from state. None of them is the process that
  # owns the terminal's bytes, so none of them can be blocked by a terminal
  # that is busy printing. That is the property this split exists to protect,
  # and it is a property of *which processes are asked*, not of how long the
  # asking is given.
  defp derive_semantic(worker_ref, expected_generation)
       when is_binary(worker_ref) and is_integer(expected_generation) do
    with {:ok, w} <- worker(worker_ref),
         :ok <- fresh(w, expected_generation),
         :ok <- open(w),
         {:ok, att, occupant} <- occupancy(w),
         :ok <- carrier(w, occupant),
         {:ok, record} <- terminal(w, occupant) do
      {:ok, presentation(w, att, occupant, record)}
    end
  end

  # ------------------------------------------------------------- the chain

  # **Enforced here as well as in `Ampd.Control`, and not as belt-and-braces.**
  # `Ampd.Control` refuses a `:human_control` command on the wrong channel at
  # the wire; this module is callable from anywhere inside the BEAM, and the
  # rule "only the human-control role may observe a terminal" is a property
  # of the relation rather than of the wire that happens to carry it. Same
  # reasoning as `Ampd.Ordered.from_coordinator?/1`: a rule that only one
  # layer enforces is a rule the next caller can forget.
  defp human_control(%{"channel" => :human_control}), do: :ok

  defp human_control(peer) do
    {:refused,
     refuse("terminal-presentation-not-human-control", %{
       "channel" => peer && peer["channel"],
       "hint" =>
         "observing a Worker's terminal is an operator disclosure, and the operator " <>
           "is the human control role — an agent may not observe another position"
     })}
  end

  defp worker(ref) do
    case Loci.worker(ref) do
      nil -> {:refused, refuse("worker-unknown", %{"worker_ref" => ref})}
      w -> {:ok, w}
    end
  end

  # **The freshness witness, and the only place it is compared.** A page that
  # saw generation 3 and asks after `close_worker`/`reopen_worker` have made
  # it 4 is designating a position that no longer exists under that name.
  # Following the replacement would silently show the operator a different
  # assignment — possibly a different actor's — under the row they clicked.
  defp fresh(w, expected) do
    current = generation(w)

    if current == expected do
      :ok
    else
      {:refused,
       refuse("worker-generation-stale", %{
         "worker_ref" => w["id"],
         "expected" => expected,
         "current" => current,
         "hint" =>
           "this Worker has been closed or reopened since the view that named it — " <>
             "re-read the projection and designate the current incarnation"
       })}
    end
  end

  defp open(%{"status" => "open"}), do: :ok

  defp open(w),
    do: {:refused, refuse("worker-not-open", %{"worker_ref" => w["id"], "status" => w["status"]})}

  # The occupant is found the way `Ampd.Worker.status_of/1` finds it — by
  # asking `occupancy_of/3` rather than by trusting the attachment table,
  # because an attachment row is a claim and occupancy is a derivation over
  # peer epoch, world lineage, Worker status and Worker generation.
  defp occupancy(w) do
    lane = Loci.lane(w["locus_ref"])

    found =
      if lane == nil do
        nil
      else
        Enum.find_value(Peer.attachments(), fn att ->
          with true <- att["worker_ref"] == w["id"],
               occupant when is_map(occupant) <- Peer.resolve(att["peer_ref"]),
               :ok <- Worker.occupancy_of(att, occupant, lane) do
            {att, occupant}
          else
            _ -> nil
          end
        end)
      end

    case found do
      {att, occupant} ->
        {:ok, att, occupant}

      nil ->
        {:refused,
         refuse("worker-not-occupied", %{
           "worker_ref" => w["id"],
           "hint" =>
             "this Worker is open and nothing stands at it, so there is no execution " <>
               "to observe — an unoccupied position has no terminal"
         })}
    end
  end

  # **The Worker is passed in because the refusal names it.** This read
  # `"worker_ref" => nil` for one commit — a field whose whole purpose is to
  # tell an operator *which row* went wrong, filled with a null while the
  # Worker was sitting in the caller's scope. A diagnostic that omits the
  # one fact it was added to carry is worse than no field: it reads as "the
  # runtime does not know", which was not true.
  defp carrier(w, occupant) do
    case Peer.carrier(occupant["id"]) do
      nil ->
        {:refused,
         refuse("carrier-not-present", %{
           "worker_ref" => w["id"],
           "hint" => "the occupant holds no Carrier, so nothing is embodying this position"
         })}

      _ ->
        :ok
    end
  end

  defp terminal(w, occupant) do
    case Peer.terminal_attachment(occupant["id"]) do
      nil ->
        {:refused,
         refuse("terminal-not-attached", %{
           "worker_ref" => w["id"],
           "hint" => "this Carrier possesses no terminal, so there is no output to observe"
         })}

      %{"status" => "ACTIVE"} = record ->
        {:ok, record}

      record ->
        {:refused,
         refuse("terminal-not-possessed", %{
           "worker_ref" => w["id"],
           "status" => record["status"],
           "hint" =>
             "the terminal relation is not finished becoming one — a record that is not " <>
               "ACTIVE refuses every byte, and presenting it would show an empty stream " <>
               "as though it were a quiet one"
         })}
    end
  end

  # **The last link, and it is about the process rather than the record.**
  # The World can say ACTIVE over a stream owner that is gone or not yet
  # finalised — `Ampd.Carrier.Terminal.finalise_stream/4` states that as the
  # worst case it tolerates. A presentation must not be opened over one.
  # **Reached from `resolve/3` and from nothing else, and that is the whole
  # of the A2 repair.** `stream_phase/1` asks the process that owns the
  # bytes, with a one-second bound that it reads as `:active` on timeout
  # because a busy owner is an active owner. That is the right answer when
  # something is opening one presentation. It was the wrong thing to put
  # under `status_of/1`, which the operator projection calls once per Worker
  # inside an ordered observation: sixteen Workers with busy terminals was
  # up to sixteen seconds of the total order, spent to render a badge.
  defp streaming(p) do
    case Ampd.Carrier.Terminal.stream_phase(p["peer_ref"]) do
      :active ->
        :ok

      phase ->
        {:refused,
         refuse("terminal-stream-not-active", %{
           "worker_ref" => p["worker_ref"],
           "phase" => to_string(phase),
           "hint" =>
             "the World holds this terminal as possessed and its stream owner does not " <>
               "yet (or no longer) agree"
         })}
    end
  end

  # ------------------------------------------------------------ the record

  # **Everything the page must never see is in here, and `presentable/1` is
  # the only thing that leaves.** Keeping both in one record rather than
  # building two would make the page-facing shape a projection of the
  # internal one, which is how a `peer_ref` reaches a wire by being added to
  # the wrong struct.
  defp presentation(w, att, occupant, record) do
    %{
      "schema" => @schema,
      # designated by the page
      "worker_ref" => w["id"],
      "worker_generation" => generation(w),
      # derived, and never disclosed
      "locus_ref" => w["locus_ref"],
      "peer_ref" => occupant["id"],
      "peer_epoch" => att["peer_epoch"],
      "attachment_ref" => record["attachment_ref"],
      "attachment_epoch" => record["attachment_epoch"],
      "carrier_ref" => record["carrier_ref"],
      "carrier_epoch" => record["carrier_epoch"],
      "pty_epoch" => record["pty_epoch"]
    }
  end

  @doc """
  The part of a presentation a page may be told, and it is two fields.

  Both are ones the page already had — it named them. Nothing derived is
  added, because a derived identifier crossing to the page is exactly how an
  unguessable name becomes a bearer token: the page would then be able to
  designate an attachment rather than a position, and the position is the
  object the authority is about.
  """
  def presentable(%{"schema" => @schema} = p),
    do: %{
      "schema" => @schema,
      "worker_ref" => p["worker_ref"],
      "worker_generation" => p["worker_generation"]
    }

  @doc """
  Is this presentation still describing the same thing it was resolved from?

  Re-derived rather than remembered. A presentation is a binding to one
  Worker incarnation occupied by one Peer holding one attachment incarnation;
  when any of those moves the presentation is over, and it does not follow
  the replacement. The falsifiers name each of those four ways separately
  because they are four different events to an operator.

  **Semantic, and the stream owner's phase is deliberately not one of the
  four identities.** It was checked at `resolve/3` and it is not an identity
  — a terminal that is busy printing has moved nothing. Making revalidation
  ask the byte owner would mean a presentation whose validity depends on
  whether its own output happens to be flowing, and would put the one-second
  probe on whatever path revalidates. The owner's *death* is a different
  fact and is delivered by monitor rather than by asking.
  """
  def current?(%{"schema" => @schema} = p) do
    case derive_semantic(p["worker_ref"], p["worker_generation"]) do
      {:ok, now} ->
        now["peer_ref"] == p["peer_ref"] and
          now["attachment_ref"] == p["attachment_ref"] and
          now["attachment_epoch"] == p["attachment_epoch"] and
          now["carrier_epoch"] == p["carrier_epoch"]

      _ ->
        false
    end
  end

  @doc """
  Whether a Worker has a terminal that could be presented — the one thing
  the control plane discloses.

  `"PRESENT"` or `"NONE"`, and deliberately nothing else: not an
  `attachment_ref`, not a `peer_ref`, not an epoch. A status is a fact about
  a position the operator can already see; an identifier is a handle, and a
  handle in a projection is the beginning of a bearer credential.

  **It said `"ACTIVE"` for one commit, and the word was the defect.** To say
  ACTIVE is to assert that the process owning the bytes agrees it is
  streaming, and the only way to learn that is to ask it — which is what the
  old `status_of/1` did, once per Worker, on every operator projection, with
  a one-second bound each. The word was paid for in the total order. What is
  honestly derivable from the World alone is *possession*: this Worker is
  open, occupied, its occupant holds a Carrier, and that Carrier's terminal
  record says ACTIVE. `"PRESENT"` says exactly that and no more.

  So a `"PRESENT"` badge is a hint and `resolve/3` is the decision.
  Opening a presentation runs the whole chain including the stream owner and
  may still refuse `terminal-stream-not-active`. A status row and an
  authority decision should not cost the same, and before this they did.

  Derived on read rather than stored, so it cannot be stale.
  """
  def status_of(worker) when is_map(worker) do
    case derive_semantic(worker["id"], generation(worker)) do
      {:ok, _} -> "PRESENT"
      _ -> "NONE"
    end
  end

  defp generation(w), do: w["generation"] || 1

  defp refuse(code, detail),
    do:
      Refusal.new(code,
        component: "Ampd.Terminal.Presentation",
        retryable: false,
        requires_human: false,
        operator_detail: detail
      )
end
