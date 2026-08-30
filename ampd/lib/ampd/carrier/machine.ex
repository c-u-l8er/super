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

  Within this channel there is exactly one submitter, so `await`'s filter
  semantics remain sufficient and are not being relied on to do more than
  they do.
  """

  @type ticket :: map()
  @type observation :: map()

  @doc "Start a Carrier for an admitted ticket. Unbounded; not ordered."
  @callback start(ticket) :: {:ok, observation} | {:error, String.t()}

  @doc """
  Stop a Carrier.

  Takes the ticket-or-incarnation and the observation, because a stop may be
  needed for a process that never became an incarnation — the refused-commit
  path. Returns `:ok` even when there was nothing to stop: a reap that
  insisted on having something to kill would fail exactly in the
  INDETERMINATE case where it matters least and is understood least.
  """
  @callback terminate(map(), observation) :: :ok
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
      "carrier_epoch" => ticket["carrier_epoch"]
    })
  end

  @impl true
  def terminate(subject, obs) do
    _ =
      submit(%{
        "schema" => "carrier-stop-request@1",
        "op" => "stop",
        "carrier_ref" => subject["carrier_ref"],
        "carrier_epoch" => subject["carrier_epoch"],
        "host_process_ref" => obs["host_process_ref"]
      })

    :ok
  end

  defp submit(body) do
    case Bridge.carrier_endpoint() do
      nil ->
        {:error,
         "no host carrier channel is possessed — refusing to resolve and execute the host by name instead"}

      %{sock: sock, incarnation: inc} ->
        Ampd.Worktree.EffectChannel.request(sock, inc, body, @deadline_ms)
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

  def reset do
    clear_policy()
    :persistent_term.put({__MODULE__, :started}, [])
    :persistent_term.put({__MODULE__, :terminated}, [])
  end

  @impl true
  def start(ticket) do
    :persistent_term.put({__MODULE__, :started}, started() ++ [ticket["carrier_ref"]])
    policy().(ticket)
  end

  @impl true
  def terminate(subject, _obs) do
    :persistent_term.put({__MODULE__, :terminated}, terminated() ++ [subject["carrier_ref"]])
    :ok
  end

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
          "fds" => %{"0" => "/dev/null", "1" => "log", "2" => "log", "3" => "socket:[1]"}
        }
      },
      overrides
    )
  end
end
