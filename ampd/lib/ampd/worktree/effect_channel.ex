defmodule Ampd.Worktree.EffectChannel do
  @moduledoc """
  The host effect, reached by **possessing a descriptor** instead of by
  **naming an executable**.

  ## The question D.1.3a asks

  D.1.1 and D.1.2 established that the authority decision and the machine
  mechanism are different things. They did not change how the mechanism is
  *reached*: `Ampd.Worktree.Effector.Host` resolves the string
  `super-host` — from `SUPER_HOST_BIN`, from config, or from a compiled-in
  path — and executes it. That is ambient addressing. Anything that can
  arrange for that name to resolve differently has changed what the effect
  means, and nothing in the request had to be forged to do it.

      name        →  ambient reachability
      descriptor  →  possessed reachability

  So: can the trusted mechanism be reachable only through possession of a
  private channel, **without moving any authorization into it**?

  ## What this channel is called, and what it is not called

  **Possession-addressed and namespace-unaddressable** — not *unforgeable*.
  The word matters because the two claims have different threat models and
  only one of them is proved here:

      knowing an executable, path or name
          ≠  possessing the production mechanism endpoint      PROVED

      a hostile same-UID process
          cannot steal the endpoint                            NOT PROVED

  Nothing here defends against `ptrace`, `pidfd_getfd`, `memfd` execution,
  loader bypass, or arbitrary code already running inside the BEAM. Those
  are D.1.3b threat-model items, and calling this channel "unforgeable"
  would quietly borrow their conclusion.

  ## What did not move, and this is the load-bearing half

  Nothing about the decision. The request submitted here carries no actor,
  no Worker, no Lane, no grant and no capability, exactly as the one-shot
  request did. The host does not decide whether an operation was
  authorized; it receives one that already was.

      World/Locus/grant/capability
              ↓
      ampd admission
              ↓
      typed mechanism request        ← this module starts here
              ↓
      host effect
              ↓
      typed observation
              ↓
      ampd verification/evidence/commit

  A channel is *mechanism possession*, not *product authority*. The two
  correlation fields this adds — `request_id` and `channel_epoch` — are
  about **which request this is**, never about whether it is allowed.

  ## The incarnation, and why an ephemeral identity is needed at all

  A channel can die and be replaced. Without an incarnation identity, an
  observation written by the endpoint that existed *before* the
  replacement could be read by the endpoint that exists *after* it and be
  accepted as the answer to a request it never saw.

      effect-channel@1
        channel_epoch      minted per incarnation, by whoever made the pair
        protocol           "worktree-effect"
        protocol_version   the ampd ↔ effector contract version
        host_identity      host-identity@1, as the host reports itself

  **This is not a durable authority store and nothing durable references
  it.** It dies with the channel. `Ampd.Bridge` holds it beside the
  descriptors it already holds, which is why D.1.3a adds no store, no
  supervised process and no second descriptor owner.

      channel identity  ≠  authority identity

  ## Channel replacement never implies effect replay

  The rule this module exists to keep, and the one a persistent channel
  makes newly dangerous. The one-shot subprocess could not get this wrong
  because a dead process was an unambiguous answer; a reconnectable
  channel invites the runtime to "try again" and thereby perform a second
  machine effect for one admitted decision.

      ampd submits E
            ↓
      host may or may not perform E
            ↓
      channel dies before a trustworthy observation
            ↓
      ampd DOES NOT resend

  The lifecycle vocabulary for this already exists — D.1.1 built it.
  Submitted, observation missing, channel lost is **INDETERMINATE**, which
  `Ampd.Worktree.create/1` reaches by way of an `{:error, _}` return, and a
  person reconciles it. Recovery may later prove what happened; a restart
  is not evidence that the effect failed.

  **This module contains no retry, no reconnect-and-resubmit, and no
  queue.** That is not an omission to be tidied up later. `C7` is the
  falsifier.

  ## Not solved here, stated so it is not later assumed

  D.1.3a is an addressing property, not a sandbox. Untouched: same-UID
  hostile process isolation, `ptrace`, `pidfd_getfd`, `memfd` execution,
  loader bypass, Landlock/seccomp, git's transitive execution, PTY and
  Worker confinement, and hostile-host attestation. The Worker is handed
  no endpoint at all — see `Ampd.Bridge.effect_endpoint/0` for what *is*
  and is not claimed about in-BEAM reachability.
  """

  alias Ampd.{Bridge, Core}

  @channel_schema "effect-channel@1"
  @request_schema "worktree-effect-request@1"
  @observation_schema "worktree-effect-observation@1"
  @protocol "worktree-effect"

  @doc "The channel incarnation schema name."
  def channel_schema, do: @channel_schema

  @doc "The protocol this channel carries. One, and it is not a transport name."
  def protocol, do: @protocol

  @doc """
  Build an `effect-channel@1` for a new incarnation.

  `epoch` must be unguessable and must not repeat across incarnations —
  it is the only thing distinguishing an observation written by the
  endpoint that has been replaced from one written by the endpoint that
  replaced it.
  """
  def incarnation(epoch, host_identity) when is_binary(epoch) and is_map(host_identity) do
    %{
      "schema" => @channel_schema,
      "channel_epoch" => epoch,
      "protocol" => @protocol,
      "protocol_version" => Ampd.Worktree.Effector.protocol_version(),
      "host_identity" => host_identity
    }
  end

  @doc "A fresh epoch. 16 bytes of CSPRNG, hex."
  def new_epoch, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  The current incarnation, or `nil` when no endpoint is possessed.

  `nil` is a real answer and the caller must treat it as one: **no
  endpoint means no effect**, never a fallback to executing something by
  name. Falling back would restore exactly the ambient path this slice
  removes, and would do it on the failure path where nobody is looking.
  """
  def current_incarnation do
    case Bridge.effect_endpoint() do
      %{incarnation: inc} -> inc
      _ -> nil
    end
  end

  @doc "The bound this channel gives the mechanism. See `submit/2`."
  def deadline_ms, do: 10_000

  @doc """
  Submit one already-admitted mechanism request and return its observation.

  `body` is the effect request without correlation — `op`, `repo_path`,
  `target`, `revision`. This function adds `request_id` and
  `channel_epoch` and nothing else; there is no place in this path for an
  authorization field to be added, which is the point.

  Returns `{:ok, observation}` or `{:error, reason}`. **Every error is a
  terminal answer for this submission.** Nothing here retries.

  ## The deadline is below the transaction budget, and that is not a tuning choice

  This effect runs inside `Ampd.AuthorityCoordinator.transact/3`, whose
  budget is 15 s. A submission allowed to wait longer than its enclosing
  transaction does not produce an indeterminate *record* — it makes the
  **caller time out and raise inside the total order**, which leaves the
  transaction dead and the lifecycle state unwritten. That is the same
  scar `Ampd.Bridge.reset/0` carries in its own comment: a client deadline
  shorter than the server's budget is a wedged peer being able to kill a
  world operation.

  It is newly reachable here. The one-shot effector could only be slow if
  the *host* was slow; a persistent channel can be made to hold the line
  by an endpoint that answers promptly and wrongly — a mismatched
  `request_id` is skipped, correctly, and skipping costs time. So the
  deadline has to be the thing that ends it, and it has to end before the
  transaction does.

      mechanism wait  <  enclosing call deadline  <  transaction budget
          10 s                    12 s                      15 s

  **`Ampd.Worktree.Effector.Host` had the same shape and has been brought
  under the same bound** — its `collect/2` waited 30 s, inside a call that
  waited 30 s, inside a 15 s budget. It is a deadline rather than a
  semantic, so the frozen effector still does exactly what it did and the
  parity check is unaffected. `C14` asserts the whole chain is strictly
  decreasing by reading the four numbers off the modules that own them,
  so it cannot drift back.

  **This is the bounded fix and not the architectural one.** The right
  shape is ordered-admit → unordered-mechanism → ordered-commit, so machine
  latency is never inside the total order at all. `Ampd.Worktree.create/1`
  records why that is a separate slice.
  """
  def submit(body, timeout \\ deadline_ms()) when is_map(body) do
    case Bridge.effect_endpoint() do
      %{sock: sock, incarnation: %{"channel_epoch" => epoch}} ->
        request_id = new_epoch()

        req =
          body
          |> Map.put("schema", @request_schema)
          |> Map.put("request_id", request_id)
          |> Map.put("channel_epoch", epoch)

        send_and_await(sock, req, request_id, epoch, timeout, @observation_schema)

      _ ->
        # Named, and not a silent fallback to `Port.open`. The whole
        # slice is that the mechanism is reached by possession; a
        # graceful degradation to reaching it by name would be the
        # architecture quietly undoing itself.
        {:error,
         "no host effect channel is possessed — refusing to resolve and execute the host by name instead"}
    end
  end

  @doc """
  Submit one request on a **caller-supplied** channel and await its answer.

  `submit/2` is the worktree effect path and always uses the bridge's effect
  endpoint. This is the same wire, correlation and deadline discipline made
  reusable, so that `Ampd.Carrier.Machine.Channel` can possess a channel of
  its own rather than sharing this one.

  The sharing is what had to be avoided: `await/4` **skips** a non-matching
  observation rather than routing it, which is safe with one submitter and
  is not a demultiplexer. D.1.3a recorded that as the thing that would break
  when mechanism duration left the total order — which is exactly what
  D.1.3b·2's machine phase does. A second channel keeps the one-submitter
  precondition true by construction instead of asking a filter to be
  something it is not.
  """
  def request(sock, incarnation, body, timeout, expect \\ @observation_schema)

  def request(sock, %{"channel_epoch" => epoch}, body, timeout, expect) when is_map(body) do
    request_id = new_epoch()

    req =
      body
      |> Map.put("request_id", request_id)
      |> Map.put("channel_epoch", epoch)

    send_and_await(sock, req, request_id, epoch, timeout, expect)
  end

  @doc """
  As `request/5`, for the one operation whose answer carries a **descriptor**.

  ## Why this is a second path and not a flag

  `recv_frame/2` is `:socket.recv/3`, and a plain `recv` on a message
  carrying `SCM_RIGHTS` **silently destroys the descriptor** — the kernel
  drops it, sets `MSG_CTRUNC`, and the body arrives looking complete.
  Measured on this VM: the open-descriptor count is unchanged across such a
  call.

  That makes "teach the shared reader about ancillary data" the wrong shape
  twice over. `Ampd.Carrier.Machine.Channel` and the worktree effect path
  both call `recv_frame/2`, and **the worktree path must never grow an
  fd-receive** — an effect that could return a descriptor is a different
  mechanism wearing this one's name. So the ancillary path is separate, and
  the two readers stay two.

  ## The receive contract, and the three things that falsify a naive one

  1. **The first receive must be `recvmsg`.** Ancillary data rides the first
     bytes of the message that carried it: it is in the first receive or it
     is gone.

  2. **It asks for exactly the four-byte length prefix.** `BufSz` is a
     ceiling, not a demand, so a generous one would happily read *past* this
     frame into a following one and leave the shared endpoint unaligned for
     the next reader. Four bytes is the smallest read that still collects
     the rights.

  3. **`ctrunc` is checked first, unconditionally, and sinks whatever
     arrived.** Truncation is destructive *and partial* — measured: three
     descriptors sent into an undersized control buffer produced `ctrunc`
     **and two of the three installed**. So a truncated receive can present
     a plausible descriptor count, and "fail on ctrunc" alone leaks the ones
     that landed. The count is only ever evaluated on a receive that did not
     truncate.

  Also measured, and the reason `flags != []` is not the test: Linux echoes
  `MSG_CMSG_CLOEXEC` back into `msg_flags`, so a perfectly successful
  receive returns `flags: [:cmsg_cloexec]`. Only `:ctrunc` means anything.

  ## What the caller gets

  `{:ok, observation, fds}` — and **the caller owes every descriptor in
  `fds` to `Ampd.NativeFd`**, on every path out. This function sinks the
  ones it decides about; it cannot sink the ones it hands over.

  Returns `{:error, reason}` with **no descriptors outstanding**.
  """
  def request_with_fd(sock, %{"channel_epoch" => epoch}, body, timeout, expect)
      when is_map(body) do
    request_id = new_epoch()

    req =
      body
      |> Map.put("request_id", request_id)
      |> Map.put("channel_epoch", epoch)

    canon = Core.canon(req)

    case :socket.send(sock, <<byte_size(canon)::big-32>> <> canon) do
      :ok ->
        await_with_fd(sock, request_id, epoch, deadline(timeout), expect)

      {:error, e} ->
        {:error, "the carrier channel could not be written: #{inspect(e)}"}
    end
  end

  # The correlation discipline of `await/5`, with one addition that is the
  # whole reason it could not simply be reused: **a skipped frame's
  # descriptors must be sunk before the skip.** `match/6` drops an
  # observation that names another request or another incarnation and loops,
  # which is correct — and if that observation carried a descriptor, looping
  # past it would leak one per skip, for as long as the deadline allows.
  defp await_with_fd(sock, request_id, epoch, deadline, expect) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, "the carrier channel did not answer the attach in time"}
    else
      case recv_frame_with_fd(sock, left) do
        {:ok, obs, fds} ->
          cond do
            obs["channel_epoch"] != epoch or obs["request_id"] != request_id ->
              Enum.each(fds, &Ampd.NativeFd.discard/1)
              await_with_fd(sock, request_id, epoch, deadline, expect)

            obs["schema"] != expect ->
              Enum.each(fds, &Ampd.NativeFd.discard/1)
              {:error, "the host returned an unknown observation schema: #{inspect(obs["schema"])}"}

            true ->
              {:ok, obs, fds}
          end

        {:error, :closed} ->
          {:error,
           "the carrier channel closed before the attach was answered — " <>
             "whether a terminal attachment exists is unknown and it will not be resubmitted"}

        # Named apart from a channel fault because it is not one. A
        # truncated control message means the host attached more
        # descriptors than this contract permits, or the control buffer is
        # undersized — both are protocol defects with a specific repair,
        # and both are indistinguishable from a broken socket once the
        # reason has been flattened into a sentence. The count is the
        # measured half: truncation is partial, and this is how many
        # actually landed before being sunk.
        {:error, {:ctrunc, n}} ->
          {:error,
           "the carrier channel truncated the attach's ancillary data — " <>
             "#{n} descriptor(s) arrived and were closed, and no attachment was taken"}

        {:error, e} ->
          {:error, "the carrier channel failed during an attach: #{inspect(e)}"}
      end
    end
  end

  # --------------------------------------------------------------- wire
  #
  # **The frozen framing and the frozen canonicalizer, both reused.**
  # Four-byte big-endian length then the body, which is what every channel
  # in this runtime already speaks (`Ampd.Transport`), and `Ampd.Core.canon/1`,
  # which is already the effect wire encoder and the digest input
  # everywhere else. A second framing or a second canonicalizer would be a
  # new privileged mechanism for a problem that has none — the same
  # refusal `Ampd.Locus` records about a second canonicalizer.
  #
  # `Ampd.Frame` is deliberately *not* used: it validates `command@1` /
  # `reply@1`, which are the channel-protocol schemas. An effect request is
  # not a command and must not be able to become one.
  defp send_and_await(sock, req, request_id, epoch, timeout, expect) do
    body = Core.canon(req)

    case :socket.send(sock, <<byte_size(body)::big-32>> <> body) do
      :ok ->
        # **Past this line the effect may have happened.** Every failure
        # below is therefore indeterminate rather than failed, and none of
        # them may resubmit.
        await(sock, request_id, epoch, deadline(timeout), expect)

      {:error, e} ->
        # Nothing left this runtime. `Ampd.Worktree` still treats this as
        # INDETERMINATE, which is conservative rather than precise — see
        # the note on the fault matrix in `Ampd.Worktree.Effector.Channel`.
        {:error, "the effect channel could not be written: #{inspect(e)}"}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp await(sock, request_id, epoch, deadline, expect) do
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      left <= 0 ->
        {:error, "the host effect channel did not answer in time"}

      true ->
        case recv_frame(sock, left) do
          {:ok, obs} ->
            match(sock, obs, request_id, epoch, deadline, expect)

          {:error, :closed} ->
            # **The C7 shape.** Submitted, no trustworthy observation, the
            # channel is gone. This is the answer; it is not a prompt to
            # open a new channel and send it again.
            {:error,
             "the host effect channel closed before an observation arrived — " <>
               "whether the effect happened is unknown and it will not be resubmitted"}

          {:error, e} ->
            {:error, "the host effect channel failed: #{inspect(e)}"}
        end
    end
  end

  # An observation satisfies a request only if it names **both** the
  # request and the incarnation. Either alone is insufficient:
  #
  #   right request_id, wrong epoch   an endpoint that has been replaced,
  #                                   answering a request it never saw
  #   right epoch, wrong request_id   this endpoint, answering a different
  #                                   request — C5's swap
  #
  # A mismatch is skipped rather than accepted, and skipping is safe
  # because the deadline still governs: a channel that only ever produces
  # mismatches times out into the indeterminate answer rather than
  # blocking forever or accepting the wrong reply.
  # **`expect` is a parameter, not a constant, and that is not cosmetic.**
  #
  # This module's wire and correlation discipline is reused by
  # `Ampd.Carrier.Machine.Channel` on its own channel — but the schema check
  # was hard-coded to the *worktree* observation, so every Carrier reply was
  # rejected as "an unknown observation schema" and every production start
  # became INDETERMINATE. Found by the first test that drove the real host
  # end to end; nothing in 53 harness falsifiers could see it, because the
  # harness never crosses this function.
  defp match(sock, obs, request_id, epoch, deadline, expect) do
    cond do
      obs["channel_epoch"] != epoch ->
        await(sock, request_id, epoch, deadline, expect)

      obs["request_id"] != request_id ->
        await(sock, request_id, epoch, deadline, expect)

      obs["schema"] != expect ->
        {:error, "the host returned an unknown observation schema: #{inspect(obs["schema"])}"}

      true ->
        {:ok, obs}
    end
  end

  defp recv_frame(sock, timeout) do
    case :socket.recv(sock, 4, timeout) do
      {:ok, <<n::big-32>>} ->
        cond do
          # The same bound every other framed reader in this runtime
          # holds, and for the same reason: four bytes said it will not
          # fit, and reading it to prove that would make the limit an
          # amplifier. The stream is unaligned afterwards, so this ends.
          n > Ampd.Frame.max_bytes() ->
            {:error, {:oversize, n}}

          n == 0 ->
            {:error, :empty_frame}

          true ->
            case :socket.recv(sock, n, timeout) do
              {:ok, body} -> decode(body)
              {:error, e} -> {:error, e}
            end
        end

      {:error, e} ->
        {:error, e}
    end
  end

  # Comfortably above the cliff, which is `CMSG_LEN(sizeof(int))` — 20 bytes
  # for one descriptor, measured: 17 truncates, 20 does not. Sized for a
  # handful rather than for one, because a control buffer that is exactly
  # big enough for the expected case turns "the host sent two" from a
  # refusal into a truncation, and a truncation loses the evidence of what
  # went wrong along with the descriptors.
  @ctrl_bytes 128

  defp recv_frame_with_fd(sock, timeout) do
    # `recvmsg/5` and not `/4`: the fourth argument of the four-arity form is
    # the **timeout**, not the flags, and passing a flag list there raises
    # `{:invalid, {:timeout, [...]}}`. This is the only arity that takes
    # both.
    case :socket.recvmsg(sock, 4, @ctrl_bytes, [:cmsg_cloexec], timeout) do
      {:ok, %{iov: iov, ctrl: ctrl, flags: flags}} ->
        fds = rights(ctrl)

        # First, and before anything reads the body. A truncated control
        # message may still have installed descriptors, so this sinks
        # whatever arrived rather than assuming truncation means none.
        if :ctrunc in flags do
          Enum.each(fds, &Ampd.NativeFd.discard/1)
          {:error, {:ctrunc, length(fds)}}
        else
          complete_frame(sock, IO.iodata_to_binary(iov), timeout, fds)
        end

      {:error, e} ->
        {:error, e}
    end
  end

  # OTP hands `SCM_RIGHTS` over undecoded — one control message whose `data`
  # is N packed native-endian 32-bit descriptors — so this unpacks rather
  # than pattern-matching a list OTP does not build.
  defp rights(ctrl) when is_list(ctrl) do
    for %{level: :socket, type: :rights, data: d} <- ctrl,
        <<fd::native-integer-size(32) <- d>>,
        do: fd
  end

  defp rights(_), do: []

  # The first receive asked for four bytes and may have returned fewer:
  # `recvmsg` on a stream socket returns short without saying so. Everything
  # from here is plain `recv`, because the rights are already collected and
  # nothing later in the frame carries any.
  #
  # Every failure below sinks the descriptors first. They are this function's
  # to lose once the receive succeeded, and an error return that left one
  # outstanding would be a leak with a reason attached.
  defp complete_frame(sock, prefix, timeout, fds) do
    with {:ok, <<n::big-32>>} <- fill(sock, prefix, 4, timeout),
         :ok <- bounded(n),
         {:ok, body} <- :socket.recv(sock, n, timeout),
         {:ok, obs} <- decode(body) do
      {:ok, obs, fds}
    else
      {:error, e} ->
        Enum.each(fds, &Ampd.NativeFd.discard/1)
        {:error, e}

      other ->
        Enum.each(fds, &Ampd.NativeFd.discard/1)
        {:error, {:unreadable_frame, other}}
    end
  end

  defp bounded(n) when n == 0, do: {:error, :empty_frame}
  defp bounded(n), do: if(n > Ampd.Frame.max_bytes(), do: {:error, {:oversize, n}}, else: :ok)

  defp fill(_sock, have, want, _timeout) when byte_size(have) == want, do: {:ok, have}

  defp fill(sock, have, want, timeout) do
    case :socket.recv(sock, want - byte_size(have), timeout) do
      {:ok, more} -> fill(sock, have <> more, want, timeout)
      {:error, e} -> {:error, e}
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      m when is_map(m) -> {:ok, m}
      other -> {:error, {:not_an_object, other}}
    end
  rescue
    _ -> {:error, :malformed_json}
  end
end

defmodule Ampd.Worktree.Effector.Channel do
  @moduledoc """
  The effector that reaches the host through a **possessed channel**.

  Same contract, same request, same observation, same verification above
  it. What changed is one thing:

  ```text
      Ampd.Worktree.Effector.Host      resolves "super-host", execs it,
                                       one process per effect

      Ampd.Worktree.Effector.Channel   writes to a descriptor it was
                                       handed, and can write to no other
  ```

  ## Identity comes off the channel, not off an exec

  `Ampd.Worktree.Effector.Host.identity/0` runs `super-host identity` —
  a second resolution of the same ambient name, on the path that decides
  what a capability *means*. Here the host states its identity once, when
  the channel is established, and it is carried in the incarnation. So
  the embodiment basis is a property of **the endpoint that will perform
  the effect** rather than of a pathname looked up beforehand.

  A channel that is not possessed yields an unresolved identity rather
  than an error, for the reason `Host` does the same: a capability
  established while the host was reachable must stop being exercisable
  once it is not, and that is a refusal with a name rather than a crash.

  ## The probe is the epoch

  `identity_probe/0` must be cheap and must move whenever `identity/0`
  would. The incarnation epoch changes on every channel replacement and
  cannot change without one, so it is exactly the right probe — and it is
  a map lookup rather than the `stat` pair `Host` needs.

  ## The fault matrix, and what it does not distinguish

  | fault | lifecycle | replay |
  |---|---|---|
  | no channel possessed | `{:error, _}` → INDETERMINATE | never |
  | write failed, nothing sent | `{:error, _}` → INDETERMINATE | never |
  | sent, channel died before observation | `{:error, _}` → INDETERMINATE | never |
  | sent, deadline passed | `{:error, _}` → INDETERMINATE | never |
  | observation from a prior incarnation | ignored, then times out | never |
  | observation for another request | ignored, then times out | never |

  **The imprecision is declared rather than hidden.** A write that failed
  before any byte left is genuinely a different world-state from a write
  that succeeded and was never answered, and this module maps both to
  INDETERMINATE. Distinguishing them would mean claiming that a
  `:socket.send` error implies no bytes were delivered, which is not true
  of a stream socket. The conservative direction is the safe one: it
  over-reports uncertainty, and the cost of that is a human reconciling a
  worktree that was never created. The opposite error creates a second
  worktree for one decision.
  """

  @behaviour Ampd.Worktree.Effector

  alias Ampd.Worktree.EffectChannel

  @identity_schema "host-identity@1"

  @impl true
  def create(%{repo_path: repo, target: target, revision: revision}) do
    req = %{
      "op" => "create",
      "repo_path" => repo,
      "target" => target,
      "revision" => revision || "HEAD"
    }

    case EffectChannel.submit(req) do
      {:ok, obs} ->
        cond do
          obs["ok"] != true ->
            {:error, "host: #{obs["reason"]}"}

          not is_binary(obs["head"]) or obs["head"] == "" ->
            {:error, "host reported success with no head"}

          true ->
            {:ok,
             %{
               head: obs["head"],
               confinement: obs["confinement"],
               identity: obs["identity"]
             }}
        end

      {:error, why} ->
        {:error, why}
    end
  end

  @impl true
  def identity do
    case EffectChannel.current_incarnation() do
      %{"host_identity" => %{"schema" => @identity_schema} = id} ->
        id

      %{"host_identity" => other} ->
        unresolved("the channel carries an unknown identity schema: #{inspect(other["schema"])}")

      nil ->
        unresolved("no host effect channel is possessed")
    end
  end

  @impl true
  def identity_probe do
    case EffectChannel.current_incarnation() do
      %{"channel_epoch" => e} -> {:channel, e}
      nil -> {:channel, :none}
    end
  end

  # No pathname in the reason — this object reaches a receipt.
  defp unresolved(reason) do
    %{
      "schema" => @identity_schema,
      "resolved" => false,
      "reason" => reason,
      "effect_protocol_version" => Ampd.Worktree.Effector.protocol_version()
    }
  end
end
