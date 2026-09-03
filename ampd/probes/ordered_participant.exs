# C1.0b·2 — what OTP 28 actually does when an ordered participant fails.
#
# A clean-room measurement, run with `elixir`, not under the app. The question
# is NOT "does send_request exist" — the docs say it does. It is two questions
# that the documentation deliberately does not conflate and that a design must
# not either:
#
#   1  can the caller SURVIVE a participant that dies, is absent, or times out
#   2  can the caller learn WHETHER THE MUTATION HAPPENED
#
# The second is the one this slice turns on. A participant that applied its
# mutation and then died before replying is indistinguishable, from the reply
# alone, from one that died before applying it.

defmodule Victim do
  use GenServer

  def start(tab), do: GenServer.start(__MODULE__, tab, name: :victim)
  def init(tab), do: {:ok, tab}

  def handle_call(:reply_ok, _f, tab), do: {:reply, :fine, tab}

  def handle_call(:slow, _f, tab) do
    Process.sleep(4_000)
    {:reply, :fine, tab}
  end

  # Dies with NO mutation. The world is provably untouched.
  def handle_call(:die_clean, _f, _tab), do: exit(:boom)

  # **The case the whole slice is about.** The mutation is applied to state
  # that survives this process — the same shape as a dets write or another
  # registry's table — and then the reply is lost.
  def handle_call(:mutate_then_die, _f, tab) do
    :ets.insert(tab, {:mutated, true})
    exit(:boom)
  end

  def handle_call(:mutate_then_reply, _f, tab) do
    :ets.insert(tab, {:mutated, true})
    {:reply, :fine, tab}
  end
end

tab = :ets.new(:witness, [:public, :set])
reset = fn -> :ets.delete_all_objects(tab) end
mutated? = fn -> :ets.lookup(tab, :mutated) != [] end

up = fn ->
  if p = Process.whereis(:victim) do
    Process.exit(p, :kill)
    Process.sleep(30)
  end

  {:ok, p} = Victim.start(tab)
  p
end

line = fn a, b, c -> IO.puts(String.pad_trailing(a, 34) <> String.pad_trailing(b, 46) <> c) end
head = fn t -> IO.puts("\n" <> t <> "\n" <> String.duplicate("-", 110)) end

# How a bare GenServer.call ends, measured from a proxy so this script lives.
call_outcome = fn fun ->
  me = self()
  pid = spawn(fn -> send(me, {:done, fun.()}) end)
  ref = Process.monitor(pid)

  receive do
    {:done, v} -> {:returned, v}
    {:DOWN, ^ref, :process, _, reason} -> {:caller_exited, reason}
  after
    9_000 -> :hung
  end
end

short = fn
  {:caller_exited, {r, _}} when is_tuple(r) -> "caller EXITED #{inspect(elem(r, 0))}"
  {:caller_exited, {r, _}} -> "caller EXITED #{inspect(r)}"
  {:caller_exited, r} -> "caller EXITED #{inspect(r)}"
  {:returned, v} -> "returned #{inspect(v)}"
  other -> inspect(other)
end

head.("A · GenServer.call — the baseline, and why the coordinator is at risk")
line.("case", "outcome", "mutated?")

reset.()
up.()
line.("normal reply", short.(call_outcome.(fn -> GenServer.call(:victim, :reply_ok) end)), "#{mutated?.()}")

reset.()
if p = Process.whereis(:victim), do: (Process.exit(p, :kill); Process.sleep(30))
line.("participant absent", short.(call_outcome.(fn -> GenServer.call(:victim, :reply_ok) end)), "#{mutated?.()}")

reset.()
up.()
line.("dies during, no mutation", short.(call_outcome.(fn -> GenServer.call(:victim, :die_clean) end)), "#{mutated?.()}")

reset.()
up.()
line.("timeout", short.(call_outcome.(fn -> GenServer.call(:victim, :slow, 500) end)), "#{mutated?.()}")

reset.()
up.()
line.("MUTATES then dies", short.(call_outcome.(fn -> GenServer.call(:victim, :mutate_then_die) end)), "#{mutated?.()}")

head.("B · :gen_server.send_request / receive_response — does the caller survive?")
line.("case", "outcome (this process never spawned a proxy)", "mutated?")

req = fn msg -> :gen_server.send_request(:victim, msg) end
resp = fn r, t ->
  try do
    :gen_server.receive_response(r, t)
  catch
    kind, why -> {:THREW, kind, why}
  end
end

reset.()
up.()
line.("normal reply", inspect(resp.(req.(:reply_ok), 2_000)), "#{mutated?.()}")

reset.()
if p = Process.whereis(:victim), do: (Process.exit(p, :kill); Process.sleep(30))
absent =
  try do
    resp.(req.(:reply_ok), 2_000)
  catch
    kind, why -> {:THREW_AT_SEND, kind, why}
  end
line.("participant absent", inspect(absent), "#{mutated?.()}")

reset.()
up.()
line.("dies during, no mutation", inspect(resp.(req.(:die_clean), 2_000)), "#{mutated?.()}")

reset.()
up.()
line.("timeout", inspect(resp.(req.(:slow), 500)), "#{mutated?.()}")

reset.()
up.()
r6 = req.(:mutate_then_die)
o6 = resp.(r6, 2_000)
line.("MUTATES then dies", inspect(o6), "#{mutated?.()}")

reset.()
up.()
r7 = req.(:mutate_then_reply)
o7 = resp.(r7, 2_000)
line.("MUTATES then replies", inspect(o7), "#{mutated?.()}")

head.("C · the question the API cannot answer")

IO.puts("""
    A participant that mutated and then died and one that died before mutating
    are reported IDENTICALLY:

        mutate_then_die   #{inspect(o6)}
        die_clean         (same shape, measured above)

    The difference is only visible in state that OUTLIVED the participant —
    the ETS witness above. `receive_response` reports that no reply arrived.
    It does not, and cannot, report whether the work was done.

    So the modern request API solves PROCESS ISOLATION and leaves OUTCOME
    AMBIGUITY exactly where it was. Those are two questions and a design that
    treats the first as the second is the defect this slice exists to avoid.
""")

head.("D · a timeout ABANDONS the request, and the mutation can still land")

# The first version of this probe asserted that the same request id answers on
# a later receive. **Its own measurement falsified that**, and the OTP 28
# documentation says why: `receive_response/2` abandons the request on
# timeout — "no response will be received after a time-out" — whereas
# `wait_response/2` does no cleanup and may be retried. Two primitives, and
# the difference is load-bearing for a transaction with a budget.
reset.()
up.()
rid = req.(:slow)
first = resp.(rid, 200)
second = resp.(rid, 6_000)
line.("receive_response, short then long", "#{inspect(first)} then #{inspect(second)}", "#{mutated?.()}")

wresp = fn r, t ->
  try do
    :gen_server.wait_response(r, t)
  catch
    kind, why -> {:THREW, kind, why}
  end
end

reset.()
up.()
wid = req.(:slow)
w1 = wresp.(wid, 200)
w2 = wresp.(wid, 6_000)
line.("wait_response, short then long", "#{inspect(w1)} then #{inspect(w2)}", "#{mutated?.()}")

head.("E · the sharpest case — the mutation lands AFTER the caller gave up")

# A mutating request, abandoned by a timeout, and then the witness read again
# once the participant has had time to finish. This is not "we do not know
# whether it happened". It is "we do not know whether it is ABOUT to happen",
# which is strictly worse: a transaction can refuse, release the order, and
# have its own mutation applied behind it.
defmodule Slowpoke do
  use GenServer
  def start(tab), do: GenServer.start(__MODULE__, tab, name: :slowpoke)
  def init(tab), do: {:ok, tab}

  def handle_call(:slow_mutate, _f, tab) do
    Process.sleep(1_500)
    :ets.insert(tab, {:mutated, true})
    {:reply, :fine, tab}
  end
end

reset.()
if p = Process.whereis(:slowpoke), do: (Process.exit(p, :kill); Process.sleep(30))
{:ok, _} = Slowpoke.start(tab)

slow_id = :gen_server.send_request(:slowpoke, :slow_mutate)
gave_up = resp.(slow_id, 300)
at_give_up = mutated?.()
Process.sleep(2_500)
after_wait = mutated?.()

line.("mutating request, 300ms patience", inspect(gave_up), "#{at_give_up}")
line.("  ...and 2.5s later", "(nothing further was sent)", "#{after_wait}")

IO.puts("""
    The caller saw `#{inspect(gave_up)}` and the mutation was #{at_give_up} at that
    instant — and #{after_wait} afterwards. The request was abandoned; the WORK was
    not. A transaction that reads a timeout as a refusal releases the total
    order and is then overtaken by its own mutation.

    So the failure classes are not two but three, and the third has a
    direction:

        NOT APPLIED        evidence establishes the mutation point was never crossed
        APPLIED            confirmed by a reply, or re-established from surviving state
        INDETERMINATE      it may have happened, or may be about to

    A retry of the third is a second execution, not a repeat of the first.
""")

if p = Process.whereis(:victim), do: Process.exit(p, :kill)
if p = Process.whereis(:slowpoke), do: Process.exit(p, :kill)
