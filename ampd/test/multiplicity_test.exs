defmodule Ampd.MultiplicityTest do
  @moduledoc """
  **Execution multiplicity is an effect property, and it is meaningless
  unless every layer that can re-execute the computation receives it.**

  `Ampd.CommandSpec` declares `retry: :safe | :once` beside `kind:`, because
  `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it constructs — so
  a read that can refuse is a read that writes as it decides. `Ampd.Control`
  routes a `retry: :once` read to `Ampd.Projection.framed_once/2`, whose
  docstring says *"one execution, inside the total order."*

  It was three. `framed_once` skipped the optimistic loop in `Projection`
  and handed the function to `AuthorityCoordinator.observe/1`, which held a
  second, identical speculation — `coherent(fun, st, 3)`. The outer loop was
  removed and the inner one left, one abstraction boundary down, where
  nobody was looking.

  ## Why these witnesses are deterministic, and the old one was not

  The defect surfaced as a **flake**: `cockpit_test.exs`'s churn probe
  failed about three runs in twenty, always recording two refusals where the
  law says one. That probe races a 20,000-iteration churn process against
  one command and hopes the clock moves in the window.

  A probe that fails 15% of the time cannot demonstrate a fix. Twenty green
  runs afterwards is not evidence at that rate — it is the outcome you would
  expect from doing nothing.

  These force the condition instead of racing it: **the function under test
  moves the clock itself**, so `coherent/3`'s retry predicate is guaranteed
  true on every execution and the loop runs to its bound every time.
  Measured against the unfixed coordinator: exactly 3. No churn, no
  scheduling luck, no probability.
  """
  use ExUnit.Case, async: false

  alias Ampd.{AuthorityCoordinator, CommandSpec, Projection, ViewClock}

  setup do
    Ampd.reset_demo()
    :ok
  end

  defp counting_fun do
    runs = :counters.new(1, [])

    fun = fn ->
      :counters.add(runs, 1, 1)
      ViewClock.tick()
      %{"answer" => "once"}
    end

    {runs, fun}
  end

  defp count(runs), do: :counters.get(runs, 1)

  # ---------------------------------------------------- the flagship law
  test "framed_once executes its function exactly once, even when the clock moves" do
    {runs, fun} = counting_fun()

    frame = Projection.framed_once(nil, fun)

    assert count(runs) == 1,
           "framed_once ran the function #{count(runs)} times. It is documented as " <>
             "'one execution, inside the total order', and `retry: :once` exists because " <>
             "Refusal.new/2 writes as it constructs. Every layer that can re-execute a " <>
             "computation must receive its multiplicity constraint or discharge it."

    # At-most-once must not be bought by returning something the cockpit
    # cannot read.
    assert frame["answer"] == "once"
    assert is_integer(frame["view_revision"])
  end

  test "observe_once executes its function exactly once" do
    {runs, fun} = counting_fun()

    {cursor, content} = AuthorityCoordinator.observe_once(fun)

    assert count(runs) == 1
    assert content == %{"answer" => "once"}
    assert is_integer(cursor["view_revision"])
  end

  # ---------------------------------------------------- and NOT the other
  #
  # The fix must not become "nothing ever retries". `observe/1` keeps its
  # bounded rebuild, because that is a real optimisation for a read with no
  # side effect. A fix that removed speculation everywhere would make the
  # test above pass by making the distinction disappear, which is the
  # cheapest way to satisfy a law and the least honest.
  test "observe still speculates for a retry-safe observation" do
    {runs, fun} = counting_fun()

    AuthorityCoordinator.observe(fun)

    assert count(runs) > 1,
           "observe/1 ran the function #{count(runs)} time(s) — the bounded rebuild is " <>
             "deliberate for retry-SAFE reads, and removing it everywhere is a different " <>
             "fix from this one"
  end

  test "framed still speculates for a retry-safe read" do
    {runs, fun} = counting_fun()

    Projection.framed(nil, fun)

    assert count(runs) > 1
  end

  # ---------------------------------------------------- the cursor bound
  #
  # THE GUARANTEE THAT HAD TO SURVIVE. The unconditional property is that
  # the cursor is never older than the state the content represents; the
  # retry only converted the common case from conservative to exact. For an
  # `:once` operation at-most-once outranks cursor exactness — so this pins
  # that what remains is still sound, not merely weaker.
  test "observe_once's cursor is never older than the content beside it" do
    before = ViewClock.read()

    {cursor, content} =
      AuthorityCoordinator.observe_once(fn ->
        ViewClock.tick()
        ViewClock.tick()
        %{"read_at" => ViewClock.read()}
      end)

    assert cursor["view_revision"] >= content["read_at"],
           "the cursor was sampled before the content it labels — a client told V about " <>
             "content from V+1 believes it has already seen the newer state"

    assert cursor["view_revision"] >= before + 2
  end

  # ---------------------------------------------------- the routing half
  #
  # The end-to-end property is a composition of two measured facts, and it
  # is stated that way rather than implied: `framed_once` runs its function
  # once (above, deterministically), and these commands reach `framed_once`
  # (here). The churn probe in `cockpit_test.exs` remains as stress evidence
  # over the whole path; it no longer carries the proof.
  test "the reads that write are the ones routed to the once path" do
    once = CommandSpec.retry_once()
    reads = CommandSpec.reads()

    assert :preflight in once
    assert :inspect_refusal in once
    assert Enum.all?(once, &(&1 in reads)), "a non-read cannot be a retry-class read"

    # **THE ANTI-VACUITY CHECK, AND THE FIRST DRAFT OF THIS TEST NEEDED ONE.**
    #
    # It was written as `for {_wire, spec} <- CommandSpec.commands()` — but
    # `commands/0` returns Map.keys, a list of wire-name STRINGS. A tuple
    # pattern that does not match is silently skipped by a comprehension, so
    # the body never ran and the assertion inside it passed by never being
    # evaluated. Green, and measuring nothing. (The property it pretended to
    # check — every read declares a retry class — is enforced at COMPILE
    # time in `CommandSpec` by `@missing_retry`, which raises. It never
    # needed a test.)
    #
    # So what is worth asserting is that the classification does work: if
    # every read were `:once` the distinction would be decorative, and this
    # file's other tests would still pass.
    assert once != [], "no read is classified :once — the distinction is doing nothing"
    assert length(once) < length(reads),
           "every read is classified :once, so the classification separates nothing — " <>
             "`observe/1`'s rebuild would be dead code and this suite would not notice"
  end
end
