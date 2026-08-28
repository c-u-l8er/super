defmodule Ampd.ViewClock do
  @moduledoc """
  **The view clock may never lag the view.**

  W.1.1 gave the cockpit a second clock, because authority revision cannot
  version everything a projection shows — `peers`, `channels` and
  `recent_refusals` are all in `operator-projection@2` and none of them is
  under the authority coordinator. That part was right. The *mechanism* was
  not:

      state changes in Ampd.Peer / Ampd.Bridge / Ampd.RefusalLog
              │
              └── GenServer.cast(AuthorityCoordinator, :touched)
                          │
                          └── eventually: view_revision + 1

  Mutable state in one process, an asynchronous *I changed* to a second,
  and the second's number claiming to version the first. That relationship
  cannot be made true by testing it harder. Measured, with `Ampd.Bridge`
  suspended to park a projection build inside
  `Ampd.AuthorityCoordinator.observe/1` while a refusal landed:

      frame cursor view_revision : 2
      frame CONTENT contains it  : true
      view_revision now          : 3

  A cursor naming view 2 beside content that belongs to view 3 — the exact
  defect the second clock was introduced to prevent, one layer down. The
  cast could not even be *processed*, because the coordinator was busy
  being the thing that made the frame coherent.

  So the clock is not a number a process holds and announces. It is a
  shared atomic counter that every projection-visible mutation advances
  **synchronously, inside its own handler**, and that any reader can sample
  without asking anyone:

      :counters, one slot, in :persistent_term

  ## The guarantee, stated exactly

      A frame's `view_revision` is sampled AFTER its content, so it is
      always greater than or equal to the version of everything in it.

  Never less. That direction is the one that matters: a client told
  `view_revision V` about content from `V+1` believes it has already seen
  the newer state and skips it. The reverse — a slightly conservative
  label on slightly older content — is corrected by the very next tick,
  because the tick is what causes the next push.

  `Ampd.AuthorityCoordinator.observe/1` additionally re-reads the clock
  either side of the build and rebuilds when it moved, so the common case
  is exact equality rather than merely safe. Exactness cannot be
  *guaranteed* for state spread across independent processes without a
  lock over all of them, and taking that lock to render a projection is a
  worse trade than a bounded rebuild. The guarantee above is what holds
  unconditionally.
  """

  @key {__MODULE__, :counter}

  @doc """
  Create the counter. Called once from `Ampd.Application.start/2`, before
  any child that can tick it.

  In `:persistent_term` rather than a GenServer state precisely because a
  GenServer is what made this lag: a reader must be able to sample it while
  every process that can move it is busy.
  """
  def init do
    case :persistent_term.get(@key, nil) do
      nil -> :persistent_term.put(@key, :counters.new(1, [:write_concurrency]))
      _ -> :ok
    end

    :ok
  end

  @doc """
  Advance the clock. **Call inside the handler that makes the change**, not
  after replying — a tick that lands after its own state is observable is a
  tick that can be missed by a reader between the two.
  """
  def tick do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      ref -> :counters.add(ref, 1, 1)
    end
  end

  @doc "Sample the clock. No process is asked, so nothing can be busy."
  def read do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end
end
