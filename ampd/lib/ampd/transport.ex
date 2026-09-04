defmodule Ampd.Transport do
  @moduledoc """
  The socket, and why there is no longer a path to one.

  ## What C1.1 got wrong the first time

  The first transport created a Unix socket per identity in a `0700`
  directory, handed the path to the process it was about to spawn, and
  accepted once. That is a real improvement over a loopback port, and it is
  still not the trust model this system claims, because the code itself had
  to admit:

      every process here runs as the same OS user and can readdir the
      runtime directory

  So the identity law degraded from

      whoever connects is Kestrel, because the listener was for Kestrel

  to

      **first connector wins**

  and those are different sentences. A same-user process that noticed the
  socket before Kestrel did *became* Kestrel. The same race against
  `bridge.sock` was worse: whoever won it could ask for the human control
  channel, and for an agent channel named anything at all. A random path
  plus `0700` is not a defence against the same UID.

  ## What it is now: possession of a descriptor

  There is **no socket file and no path.** Channels are `socketpair(2)`
  endpoints, and a channel is held rather than found:

      Rust host
        ├─ socketpair()            → keeps A, spawns ampd with B as fd 3
        │                            ampd adopts fd 3: THE BRIDGE
        │
        └─ per engine:
             socketpair()          → D goes to ampd over the bridge in an
             │                       SCM_RIGHTS message labelled "kestrel"
             └─ C is inherited by the engine at spawn, and the host
                closes its own copy

  Nothing exists in the filesystem to notice, race, or open. **Possession
  of the descriptor is the identity capability**, and a descriptor cannot
  be guessed, enumerated, or opened by name — it can only be given.

  That also makes the privileged bridge a capability rather than a
  rendezvous: it is a descriptor the host was born holding, so there is no
  window in which anything else could have taken it.

  ## Framing

  Four-byte big-endian length, then the body. The length is read and
  checked **before the body is read at all**, so an oversized frame costs
  four bytes and never enters the VM. `packet_size` did that implicitly;
  this does it in one visible place, which is better for the same reason
  the rest of this system prefers a named refusal to an inherited default.

  The bridge is `SOCK_SEQPACKET`, not `SOCK_STREAM`: it carries file
  descriptors, and a descriptor belongs to exactly one message. Sequenced
  packets keep that true without a framing layer that could ever associate
  a descriptor with the wrong command.
  """

  @doc """
  A connected pair of local sockets, and no lasting name.

  Erlang exposes no `socketpair(2)`, so this binds a listener, connects,
  accepts, and unlinks — the path exists for the microseconds between
  `bind` and `unlink`, inside a `0700` directory, and is gone before either
  end carries anything.

  **This is not how the runtime obtains channels.** The runtime never
  creates one; it adopts descriptors the host passes it, and the host uses
  a real `socketpair(2)`. This exists so tests can construct the same shape
  without a Rust process, and it is deliberately the only place left in the
  tree that touches a socket path.
  """
  def socketpair(type \\ :stream) do
    dir = Path.join(System.tmp_dir!(), "ampd-pair-" <> rand(6))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, rand(8) <> ".sock")

    {:ok, l} = :socket.open(:local, type, :default)
    :ok = :socket.bind(l, %{family: :local, path: path})
    :ok = :socket.listen(l)

    {:ok, c} = :socket.open(:local, type, :default)
    me = self()
    spawn(fn -> send(me, {:connected, :socket.connect(c, %{family: :local, path: path})}) end)

    {:ok, s} = :socket.accept(l)

    receive do
      {:connected, :ok} -> :ok
    after
      2_000 -> raise "socketpair: the connect never landed"
    end

    :socket.close(l)
    File.rm(path)
    # `rm_rf`, not `rmdir`: a directory that survives because one unlink
    # failed is a directory something can still be created inside.
    File.rm_rf(dir)
    {s, c}
  end

  defp rand(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)

  @doc "The raw descriptor behind a `:socket` handle, or nil."
  def fd_of(sock) do
    case :socket.getopt(sock, {:otp, :fd}) do
      {:ok, fd} -> fd
      _ -> nil
    end
  end

  # ===================================================================
  defmodule Wire do
    @moduledoc """
    Length-prefixed frames over a `:socket` handle, in both directions.

    The reader is its own process because `:socket.recv/2` blocks, and the
    connection has to stay able to receive a pushed projection while it is
    waiting for the next command. One blocking reader; one process that
    owns the identity and the state.
    """

    @doc "Send one frame."
    def send_frame(sock, map) do
      body = Ampd.Frame.encode!(map)
      :socket.send(sock, <<byte_size(body)::big-32>> <> body)
    end

    @doc false
    def reader(sock, owner) do
      case :socket.recv(sock, 4) do
        {:ok, <<n::big-32>>} ->
          cond do
            n == 0 ->
              reader(sock, owner)

            # **The body is never read.** Four bytes said it will not fit,
            # and reading five megabytes to prove it would make the limit
            # an amplifier rather than a bound. The stream is unaligned
            # afterwards, so the connection ends.
            n > Ampd.Frame.max_bytes() ->
              send(owner, {:oversize, n})

            true ->
              case :socket.recv(sock, n) do
                {:ok, body} ->
                  send(owner, {:frame, body})
                  reader(sock, owner)

                _ ->
                  send(owner, :closed)
              end
          end

        _ ->
          send(owner, :closed)
      end
    end
  end

  # ===================================================================
  defmodule Connection do
    @moduledoc """
    One descriptor, bound to one identity for its whole life.

    The identity is a closure argument — the label the host attached when
    it passed the descriptor — and there is no code path here in which
    anything read off the socket decides who the other end is.
    """
    alias Ampd.Transport.Wire

    # **A channel handoff is a transaction.**
    #
    #     A channel is either committed to one live connection, or rolled
    #     back completely. There is no timed-out-but-still-starting state.
    #
    # F.8.2.1 said ownership moved to this process when `start/3` returned.
    # It did not, and OTP is explicit about what does: the socket's owner
    # is its `{otp, controlling_process}`, which stayed `Ampd.Bridge`. So
    # this was `spawn` with no monitor, racing a `receive after 5_000`
    # against a `GenServer.call` whose own default deadline is also 5_000 —
    # and every abnormal exit fell through the gap. Measured, all three:
    #
    #     Peer suspended  → host told `channel-bind-failed` at 5001 ms,
    #                       then a live `kestrel` binding appeared anyway
    #     killed bound    → socket open, bridge still listing the channel,
    #                       peer still resolving
    #     killed control  → `control-channel-already-claimed`, forever;
    #                       the person is locked out of their own world
    #
    # The last one is not a leak. It is a crash taking the human's
    # authority away and never giving it back.
    #
    # Two deadlines, ordered rather than equal. The child's own bind
    # deadline must fire *first*, so this one is a backstop for a child
    # that is stuck rather than a competitor with a child that is slow.
    @bind_deadline 5_000
    @startup_deadline @bind_deadline + 3_000

    @doc """
    Adopt `sock` as a channel for `kind`/`actor`.

    Returns `{:ok, pid, peer_id, monitor_ref}` — the ref is the caller's,
    because the caller owns the socket and is the only thing that can free
    it when this process dies. Or `{:refused, refusal@1}`, by which point
    the socket is closed and any identity this startup created is detached.
    """
    def start(sock, kind, actor) do
      parent = self()
      {pid, ref} = spawn_monitor(fn -> run(sock, kind, actor, parent) end)
      await(pid, ref, sock, nil, System.monotonic_time(:millisecond) + @startup_deadline)
    end

    # `peer_id` is threaded because a startup that is rolled back must undo
    # the identity it created, and the only process that knows the identity
    # exists is the one that created it. So the child reports it the moment
    # `bind` returns — *before* anything else that can block — and this
    # waits with that in hand.
    defp await(pid, ref, sock, peer_id, deadline) do
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:binding, ^pid, id} ->
          await(pid, ref, sock, id, deadline)

        {:bound, ^pid, {:ok, p, id}} ->
          {:ok, p, id, ref}

        {:bound, ^pid, {:refused, r}} ->
          settle(pid, ref, sock, peer_id, deadline)
          {:refused, r}

        {:DOWN, ^ref, :process, ^pid, reason} ->
          rollback(sock, peer_id)
          {:refused, crash_refusal(reason)}
      after
        left ->
          settle(pid, ref, sock, peer_id, deadline)
          {:refused, timeout_refusal()}
      end
    end

    # **Nothing leaves this function while the channel still exists.**
    #
    # F.8.2.2 had two copies of this and one of them was an escape: the
    # refusal branch waited a flat second for `DOWN`, then demonitored and
    # returned `{:refused, _}` **without rolling back**. Measured — a bind
    # refused into a socket whose send buffer was full came back after
    # 1003 ms with the socket still open, and still open a second and a
    # half later. That is precisely the timed-out-but-still-starting state
    # the round said it had removed, reached by a peer that simply does not
    # read.
    #
    # Two changes, and the order of them matters. The rollback is now
    # unconditional, so even a `DOWN` that never arrives cannot take the
    # channel with it; and the wait shares the startup deadline instead of
    # inventing a second one. A kill is what makes the first wait
    # terminate: `:kill` cannot be trapped, so the process is gone and the
    # `DOWN` is on its way. The bound wait after it is a belt, not a
    # mechanism — and it no longer matters if it expires, because the
    # rollback happens either way.
    defp settle(pid, ref, sock, peer_id, deadline) do
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        left ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1_000 -> :ok
          end
      end

      Process.demonitor(ref, [:flush])
      rollback(sock, peer_id)
    end

    @doc """
    Undo a channel: close the socket, drop the subscription, detach the
    identity.

    Total and idempotent, because it runs from two places that cannot
    coordinate — a startup that never completed, and `Ampd.Bridge` finding
    out that a connection died.
    """
    def rollback(sock, peer_id) do
      if sock, do: :socket.close(sock)

      if peer_id do
        try do
          Ampd.Subscriptions.unsubscribe(peer_id)
          Ampd.Peer.detach(peer_id)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    defp run(sock, kind, actor, parent) do
      case bind(kind, actor) do
        {:ok, peer_id} ->
          # Before `resolve`, before the hello, before anything that can
          # block: an identity now exists, and whoever is waiting has to be
          # able to undo it even if this process never speaks again.
          send(parent, {:binding, self(), peer_id})

          # This connection does not outlive the table that named it. A
          # binding lives in `Ampd.Peer`; if that process dies the binding
          # is gone, and a socket still holding an identity it can no
          # longer prove is exactly what fail-closed reattachment is for.
          ref = Process.monitor(Ampd.Peer)
          peer = Ampd.Peer.resolve(peer_id)
          send(parent, {:bound, self(), {:ok, self(), peer_id}})
          Wire.send_frame(sock, hello(peer, kind, actor))

          me = self()
          reader = spawn_link(fn -> Wire.reader(sock, me) end)
          loop(sock, peer_id, ref, reader)

        # **No frame, and no close.** A channel that was refused never
        # became a channel: there is nothing on the other end that has
        # agreed to read it, and the refusal reaches whoever asked by the
        # route they asked on — a `bridge-reply@1` for the host, the return
        # value of `adopt_channel/3` for anything in the BEAM.
        #
        # Writing it here was the stall. `socket:send/2` is the
        # infinity-timeout form, so a peer that never reads is a peer that
        # holds this process open indefinitely, and `Ampd.Bridge` — which
        # owns this socket, and is waiting — had a one-second escape hatch
        # for exactly that. Disposal belongs to the owner; this process's
        # last act is to say so.
        {:refused, r} ->
          send(parent, {:bound, self(), {:refused, r}})
      end
    end

    defp bind(:agent, actor),
      do: Ampd.Peer.attach_agent(actor, [engine: "transport"], @bind_deadline)

    defp bind(:human_control, _),
      do: Ampd.Peer.claim_control_channel([engine: "host"], @bind_deadline)

    defp loop(sock, peer_id, ref, reader) do
      receive do
        {:frame, body} ->
          Wire.send_frame(sock, answer(body, peer_id))
          loop(sock, peer_id, ref, reader)

        # The client did not ask for this frame; it asked, once, to be told
        # when the world moved.
        {:ampd_push, snapshot} ->
          Wire.send_frame(sock, snapshot)
          loop(sock, peer_id, ref, reader)

        {:oversize, n} ->
          Wire.send_frame(sock, %{
            "schema" => "reply@1",
            "client_request_id" => nil,
            "result" => %{
              "allow" => false,
              "reason" => "That frame is larger than this protocol accepts.",
              "refusal" =>
                Ampd.Refusal.new("frame-too-large",
                  component: "Ampd.Transport",
                  retryable: false,
                  requires_human: false,
                  public_message: "That frame is larger than this protocol accepts.",
                  operator_detail: %{"announced" => n, "max" => Ampd.Frame.max_bytes()}
                )
            }
          })

          shutdown(sock, peer_id, reader)

        # `Ampd.Peer` died, so this channel's identity died with it. There
        # is nothing to reattach to; the host must ask for a new channel.
        {:DOWN, ^ref, :process, _pid, _reason} ->
          shutdown(sock, peer_id, reader)

        # **Any other watched process, which today means
        # `Ampd.Subscriptions`.** A subscribed channel does not outlive the
        # process that promised to push to it: its `subs` table is in
        # memory, the supervisor is `:one_for_one`, and a restart therefore
        # silently unsubscribes everyone while every socket stays up.
        # Measured — a real authority mutation afterwards produced zero
        # pushes and the connection was still alive, so the host held LIVE
        # LOCAL with nothing left to tell it otherwise.
        #
        # Closing is the honest signal and it costs nothing new: the host's
        # EOF path already reacquires and resubscribes. `Ampd.Peer` is the
        # only other process this connection monitors, and it is matched
        # above, so this clause is precise rather than a catch-all.
        {:DOWN, _other, :process, _pid, _reason} ->
          shutdown(sock, peer_id, reader)

        :closed ->
          shutdown(sock, peer_id, reader)

        :stop ->
          shutdown(sock, peer_id, reader)
      end
    end

    # **Close the descriptor first.** The bookkeeping below talks to
    # processes that may be the very ones that just died — `Ampd.Peer` is
    # the usual reason this runs — and a `GenServer.call` into a restarting
    # process exits the caller. That used to leave the socket open, held by
    # a dead connection process: the channel invalid and still connected,
    # which is the exact half-state this whole path exists to prevent.
    #
    # So: the close is unconditional and first, and everything after it is
    # best-effort.
    defp shutdown(sock, peer_id, reader) do
      # **The reader dies first, then the socket closes.**
      #
      # `:socket.close/1` on a socket another process is blocked reading
      # defers until that operation aborts, so closing first left the
      # descriptor open — measured against `/proc/<ampd>/fd`: ten channels
      # bound, ten closed, nineteen sockets still held. Killing the reader
      # is the thing that cannot fail, so it can go first without
      # reintroducing the hazard that put the close here: the bookkeeping
      # below talks to processes that may have just died, and that is what
      # must not be able to strand the descriptor.
      Process.unlink(reader)
      Process.exit(reader, :kill)
      :socket.close(sock)

      try do
        Ampd.Subscriptions.unsubscribe(peer_id)
        Ampd.Peer.detach(peer_id)
      catch
        :exit, _ -> :ok
      end

      if Process.whereis(Ampd.Bridge), do: Ampd.Bridge.channel_closed(self())
      :ok
    end

    # A startup that died is not a startup that timed out, and saying so
    # costs one field. `channel-bind-failed` either way: what a peer is
    # allowed to know is that its channel did not bind.
    defp crash_refusal(reason) do
      Ampd.Refusal.new("channel-bind-failed",
        component: "Ampd.Transport.Connection",
        retryable: true,
        requires_human: false,
        public_message: "The runtime could not bind that channel.",
        operator_detail: %{
          "reason" => "the connection died during startup",
          "exit" => inspect(reason) |> String.slice(0, 200)
        }
      )
    end

    defp timeout_refusal do
      Ampd.Refusal.new("channel-bind-failed",
        component: "Ampd.Transport.Connection",
        retryable: true,
        requires_human: false,
        public_message: "The runtime could not bind that channel.",
        operator_detail: %{"reason" => "the binding did not complete"}
      )
    end

    defp hello(peer, kind, actor) do
      %{
        "schema" => "hello@1",
        "protocol" => Ampd.CommandSpec.version(),
        "command_spec" => Ampd.CommandSpec.schema(),
        "channel" => to_string(kind),
        # An agent is told its own name. Not a disclosure: it is the actor
        # its own projection is already filtered to.
        "actor" => actor,
        "peer_seq" => peer && peer["seq"],
        "max_frame_bytes" => Ampd.Frame.max_bytes(),
        "commands" =>
          kind |> Ampd.CommandSpec.commands_for() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
        "runtime" => Ampd.Projection.runtime_status()
      }
      |> Map.merge(Ampd.Projection.continuity())
    end

    # Bytes to an answer, and it cannot raise: an undecodable frame is a
    # refusal, an unknown command is a refusal, a badly shaped argument is
    # a refusal. A connection handler that dies on input is a denial of
    # service with extra steps.
    defp answer(body, peer_id) do
      base =
        case Ampd.Frame.decode(body) do
          {:ok, f} ->
            %{
              "client_request_id" => f["client_request_id"],
              "result" => Ampd.Wire.command(peer_id, f["command"], f["args"])
            }

          {:error, code, detail} ->
            r =
              Ampd.Refusal.new(code,
                component: "Ampd.Frame",
                retryable: false,
                requires_human: false,
                public_message: frame_message(code),
                operator_detail: detail
              )

            %{
              "client_request_id" => nil,
              "result" => %{
                "allow" => false,
                "reason" => r["public_message"],
                "refusal" => project(r, peer_id)
              }
            }
        end

      base
      |> Map.put("schema", "reply@1")
      |> Map.merge(Ampd.Projection.continuity())
    end

    defp project(r, peer_id) do
      case Ampd.Peer.resolve(peer_id) do
        %{"channel" => :human_control} -> Ampd.Refusal.project(r, :human_control)
        _ -> Ampd.Refusal.project(r, :general)
      end
    end

    defp frame_message("identity-not-claimable"),
      do: "Identity comes from the connection, not from the command."

    defp frame_message("frame-too-large"), do: "That frame is larger than this protocol accepts."
    defp frame_message("unknown-command"), do: "No such command."

    defp frame_message("invalid-command-arguments"),
      do: "The command arguments were not the shape this command takes."

    defp frame_message(_), do: "That is not a frame this protocol accepts."
  end

  # ===================================================================
  defmodule HostBridge do
    @moduledoc """
    `bridge-command@1` — the host handing the runtime descriptors.

    **A different protocol from `command@1`, on purpose.** `command@1` is
    the authority surface: things a peer with an identity may ask about its
    own world. Nothing on it can create a channel or name an actor, and
    that has to stay true, so the host's own needs cannot live there.

    This runs on the descriptor the host was born holding, so "the
    privileged connection" is a fact established at `fork` rather than a
    race anything can enter. A command that binds a channel carries that
    channel's descriptor in its `SCM_RIGHTS` control message; the actor is
    the label beside it, and the runtime is what associates the two.

    **A bind with no descriptor attached is refused.** There is no way to
    name an identity without also handing over the channel it names, which
    is what makes "possession is the capability" hold on this side too.
    """

    def start(sock) do
      pid = spawn_link(fn -> loop(sock) end)
      {:ok, pid}
    end

    def stop(pid) when is_pid(pid), do: Process.exit(pid, :normal)
    def stop(_), do: :ok

    # **`cmsg_cloexec`, explicitly.** `recvmsg/1` is `recvmsg` with an empty
    # flag list, so a descriptor arriving over `SCM_RIGHTS` would land
    # inheritable — the mirror image of the `SOCK_CLOEXEC` defect the host
    # had, on the receiving side of the same handoff.
    #
    # Measured honestly: a BEAM-spawned OS child sees no sockets at all on
    # this OTP, because `erl_child_setup` closes descriptors above 2 before
    # `exec`. So this is not currently the vulnerability its Rust
    # counterpart was — it is the same *rule*, applied where the runtime
    # controls it rather than relying on a property of the VM's spawn path
    # that nothing here asserts.
    defp loop(sock) do
      case :socket.recvmsg(sock, [:cmsg_cloexec]) do
        {:ok, msg} ->
          reply = answer(iov(msg), rights(msg))
          :socket.send(sock, JSON.encode!(reply))
          loop(sock)

        {:error, _} ->
          :ok
      end
    end

    defp iov(%{iov: parts}), do: IO.iodata_to_binary(parts)
    defp iov(_), do: ""

    # A control message may carry several descriptors; a bind takes one and
    # closes the rest rather than leaking them into the runtime.
    defp rights(%{ctrl: ctrl}) when is_list(ctrl) do
      ctrl
      |> Enum.filter(&(&1[:type] == :rights and &1[:level] == :socket))
      |> Enum.flat_map(fn %{data: d} -> for <<fd::native-32 <- d>>, do: fd end)
    end

    defp rights(_), do: []

    defp answer(bytes, fds) do
      case safe_decode(bytes) do
        {:ok, %{"schema" => "bridge-command@1", "command" => cmd} = f} when is_binary(cmd) ->
          run(cmd, f, fds)

        _ ->
          Enum.each(fds, &close_fd/1)
          err("unknown-bridge-command", %{"reason" => "not a bridge-command@1 frame"})
      end
    end

    defp safe_decode(bytes) do
      case JSON.decode(bytes) do
        {:ok, %{} = f} -> {:ok, f}
        _ -> :error
      end
    rescue
      _ -> :error
    end

    defp run("bind_control_channel", _f, [fd | rest]) do
      Enum.each(rest, &close_fd/1)

      case Ampd.Bridge.adopt_channel(fd, :human_control, nil) do
        {:ok, _pid, _peer} -> ok(%{"channel" => "human_control"})
        {:refused, r} -> %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}
      end
    end

    defp run("bind_agent_channel", %{"actor" => actor}, [fd | rest]) when is_binary(actor) do
      Enum.each(rest, &close_fd/1)

      if byte_size(actor) > 0 and byte_size(actor) <= 128 do
        case Ampd.Bridge.adopt_channel(fd, :agent, actor) do
          {:ok, _pid, _peer} -> ok(%{"channel" => "agent", "actor" => actor})
          {:refused, r} -> %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}
        end
      else
        close_fd(fd)
        err("invalid-actor", %{"reason" => "actor must be 1..128 bytes"})
      end
    end

    # **The mechanism endpoint, adopted exactly as an identity channel is.**
    #
    # Same bridge, same `SCM_RIGHTS` transfer, same single-consumption law:
    # the descriptor is adopted or it is sunk, on every exit. What differs
    # is only the direction of use — the runtime is the *client* on this
    # one, and the host is the server that performs what was admitted.
    #
    # The incarnation is checked before it is bound. It comes from the
    # trusted host, so this is not a defence against a forged one; it is
    # the same reason `bind_agent_channel` bounds an actor it also trusts —
    # a malformed value that reaches storage becomes a malformed value in
    # every projection that reads it, and refusing at the boundary is one
    # place instead of many.
    defp run("bind_effect_channel", %{"incarnation" => inc}, [fd | rest]) when is_map(inc) do
      Enum.each(rest, &close_fd/1)

      epoch = inc["channel_epoch"]

      cond do
        inc["schema"] != Ampd.Worktree.EffectChannel.channel_schema() ->
          close_fd(fd)
          err("invalid-effect-channel", %{"reason" => "not an effect-channel@1 incarnation"})

        not is_binary(epoch) or byte_size(epoch) < 16 or byte_size(epoch) > 128 ->
          close_fd(fd)

          err("invalid-effect-channel", %{
            "reason" => "channel_epoch must be 16..128 bytes",
            "hint" =>
              "an epoch short enough to guess is an epoch a replaced endpoint's observation " <>
                "can be stamped with"
          })

        inc["protocol"] != Ampd.Worktree.EffectChannel.protocol() ->
          close_fd(fd)
          err("invalid-effect-channel", %{"reason" => "unknown effect protocol"})

        true ->
          case Ampd.Bridge.bind_effect_endpoint(fd, inc) do
            {:ok, _} -> ok(%{"channel" => "effect", "channel_epoch" => epoch})
            {:refused, r} -> %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}
          end
      end
    end

    # The Carrier lifecycle channel. Same validation, same disposal, same
    # closed-enum discipline — deliberately a copy rather than a shared
    # helper parameterised by a protocol string, because the thing that
    # differs between these two clauses is *which endpoint a descriptor is
    # bound to*, and a helper that took that as an argument would be a place
    # where passing the wrong one binds a Carrier channel as the effect
    # channel. Two explicit clauses cannot be called with the wrong key.
    defp run("bind_carrier_channel", %{"incarnation" => inc}, [fd | rest]) when is_map(inc) do
      Enum.each(rest, &close_fd/1)

      epoch = inc["channel_epoch"]

      cond do
        inc["schema"] != Ampd.Worktree.EffectChannel.channel_schema() ->
          close_fd(fd)
          err("invalid-carrier-channel", %{"reason" => "not an effect-channel@1 incarnation"})

        not is_binary(epoch) or byte_size(epoch) < 16 or byte_size(epoch) > 128 ->
          close_fd(fd)
          err("invalid-carrier-channel", %{"reason" => "channel_epoch must be 16..128 bytes"})

        inc["protocol"] != Ampd.Carrier.Machine.Channel.protocol() ->
          close_fd(fd)
          err("invalid-carrier-channel", %{"reason" => "unknown carrier protocol"})

        # **The execution basis is checked here or it is never checked.**
        #
        # It is what every later admission binds, and the same argument the
        # clause above makes applies with more force: a malformed value that
        # reaches storage becomes a malformed value in every ticket minted
        # against this channel, and a basis nobody can compare is worse than
        # no channel — it would refuse every commit for a reason that reads
        # like a payload swap.
        not carrier_basis?(inc["carrier_basis"]) ->
          close_fd(fd)

          err("invalid-carrier-channel", %{
            "reason" => "no well-formed carrier-execution-basis@1 accompanies the channel",
            "hint" =>
              "the host measures the installed Carrier payload when it establishes this " <>
                "channel; without it an admission binds nothing and cannot refuse a swap"
          })

        true ->
          case Ampd.Bridge.bind_carrier_endpoint(fd, inc) do
            {:ok, _} -> ok(%{"channel" => "carrier", "channel_epoch" => epoch})
            {:refused, r} -> %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}
          end
      end
    end

    # **Registering a repository is a host-level trust decision, and until
    # now the host had no way to make it.**
    #
    # `Ampd.Worktree.register_repository!/1` says in its own docs that this
    # is host-level, and `Ampd.CommandSpec` says the same where `open_lane`
    # declines to take a path. Both were right about where the decision
    # belongs and neither put a door there: `open_lane` requires an `rp_`
    # ref, the only thing that mints one is an in-process function call, and
    # `cockpit.js` sends `repository_ref` for a value nothing could produce.
    # **So no deployed Super could open a Lane at all.** The D.1.3a
    # production end-to-end test is what surfaced it — the first thing that
    # tried to drive the whole chain from outside the BEAM.
    #
    # It goes on the bridge rather than the human control channel because
    # that is what "host-level" means here: the bridge is reachable only by
    # the process the runtime was born holding a descriptor to. A person
    # naming a path to trust is a decision the host makes on their behalf,
    # not a command an agent channel could ever carry.
    defp run("register_repository", %{"path" => path}, fds) when is_binary(path) do
      Enum.each(fds, &close_fd/1)

      if byte_size(path) > 0 and byte_size(path) <= 4096 do
        case Ampd.Authority.register_repository(path) do
          {:ok, repo} -> ok(%{"repository" => repo})
          {:refused, r} -> %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}
          other -> err("repository-not-registered", %{"reason" => inspect(other)})
        end
      else
        err("invalid-repository-path", %{"reason" => "path must be 1..4096 bytes"})
      end
    end

    # **The other half of the same gap.** `register_repository` had no door
    # from outside the BEAM; neither does installing a capability pack, and
    # without one no world can reach a state where *any* worktree is
    # establishable — `request_grant` refuses `capability-undeclared`
    # forever. Both were found the same way, by the first thing that tried
    # to drive the whole chain from outside.
    #
    # **A closed enum, not a module name.** Taking a string and resolving it
    # to a function would make the bridge a place where naming something
    # runs it, which is the exact property D.1.3a spent itself removing one
    # layer up. Two packs exist; both are listed.
    defp run("install_pack", %{"pack" => pack}, fds) when is_binary(pack) do
      Enum.each(fds, &close_fd/1)

      case pack do
        "worktree" -> installed(Ampd.Authority.install_worktree(), pack)
        "postgres" -> installed(Ampd.Authority.install_postgres(), pack)
        _ -> err("unknown-pack", %{"pack" => pack, "known" => ["worktree", "postgres"]})
      end
    end

    # **D.1.3c·2c·1b — a descriptor, and deliberately nothing else.**
    #
    # This arm is the narrowest one on the bridge and that is its whole
    # design. It takes no Worker, no generation, no actor, no incarnation: it
    # adopts a socket and returns an opaque reference to it. There is no
    # argument a caller could supply here that would make it a presentation,
    # so there is nothing here to get wrong.
    #
    # The authority arrives later and on a different socket. `terminal_bind`
    # is a `:human_control` mutation, so `Ampd.Control` has already resolved
    # the bound connection before it dispatches, and
    # `Ampd.Terminal.Presentation.resolve/3` runs the chain against that
    # peer. Only then is this endpoint claimed.
    #
    # The reverse ordering — authorise first, then present a ticket here with
    # the descriptor — puts an identifier that must never reach a page onto
    # `Ampd.Control`'s reply, which is the one wire that ends in JavaScript.
    defp run("bind_terminal_endpoint", _f, [fd | rest]) do
      Enum.each(rest, &close_fd/1)

      case Ampd.NativeFd.adopt_socket(fd) do
        :error ->
          close_fd(fd)
          err("invalid-terminal-endpoint", %{"reason" => "the descriptor could not be adopted"})

        {:ok, sock} ->
          case Ampd.Terminal.Presentations.park(sock) do
            {:ok, ref} ->
              ok(%{
                "endpoint_ref" => ref,
                "expires_in_ms" => Ampd.Terminal.Presentations.ttl_ms()
              })

            other ->
              _ = :socket.close(sock)

              err("invalid-terminal-endpoint", %{
                "reason" => "the endpoint could not be parked",
                "detail" => inspect(other)
              })
          end
      end
    end

    defp run("list_channels", _f, fds) do
      Enum.each(fds, &close_fd/1)
      ok(%{"channels" => Ampd.Bridge.list()})
    end

    defp run("runtime_status", _f, fds) do
      Enum.each(fds, &close_fd/1)
      ok(%{"runtime" => Ampd.Projection.runtime_status()})
    end

    # Every remaining shape, including a bind with no descriptor attached.
    defp run(cmd, _f, fds) do
      Enum.each(fds, &close_fd/1)

      err(
        "invalid-bridge-command",
        %{
          "command" => cmd,
          "hint" =>
            "binding a channel requires the channel: pass its descriptor in an SCM_RIGHTS " <>
              "control message on the same sequenced packet"
        }
      )
    end

    # **This is where the leak was worse than the brief said.**
    #
    # It opened the descriptor `dup: false` and closed the handle, on the
    # reasoning that a `dup: true` copy would close the copy and leave the
    # original. The first half was right and the conclusion did not follow:
    # OTP will not close a descriptor it did not create either, so this
    # closed *nothing* — and unlike the bind path it runs on every rejected
    # command, every surplus descriptor, every unparseable frame. F.8.1's
    # "bounded by channels ever opened, not by traffic" was measured only
    # against successful binds, and this function is the counterexample.
    #
    # One sink for every descriptor out of ancillary data.
    defp close_fd(fd), do: Ampd.NativeFd.discard(fd)

    defp installed({:refused, r}, _),
      do: %{"schema" => "bridge-reply@1", "ok" => false, "refusal" => r}

    defp installed(_, pack), do: ok(%{"pack" => pack})

    # The shape only. Whether the basis is *the right one* is a question with
    # no answer at bind time — there is nothing yet to compare it to, and the
    # comparison belongs to `Ampd.Carrier.commit_start/2`, which has a ticket.
    defp carrier_basis?(%{"schema" => "carrier-execution-basis@1"} = b) do
      is_binary(b["payload_digest"]) and b["payload_digest"] != "" and
        b["carrier_protocol"] == Ampd.Carrier.Machine.Channel.protocol() and
        is_integer(b["carrier_protocol_version"])
    end

    defp carrier_basis?(_), do: false

    defp ok(map), do: Map.merge(%{"schema" => "bridge-reply@1", "ok" => true}, map)

    defp err(code, detail) do
      %{
        "schema" => "bridge-reply@1",
        "ok" => false,
        "refusal" =>
          Ampd.Refusal.new(code,
            component: "Ampd.Transport.HostBridge",
            retryable: false,
            requires_human: false,
            public_message: "That is not a bridge command.",
            operator_detail: detail
          )
      }
    end
  end
end
