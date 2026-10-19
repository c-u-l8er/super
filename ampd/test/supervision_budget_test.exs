# STAND-IN (R147) for plan dt_0237 (t-task-t73, superlane/t73/TASK.md revision 2): the file Super's bot (bt_0034) writes
# through Super. It exists only so the bot can propose into a file open in the Editor; the install merges the bot's bytes
# over it, and if the plan is cancelled a commit on main removes it. Its one test is skipped, so every profile stays green.
defmodule Ampd.SupervisionBudgetTest do
  use ExUnit.Case, async: false

  @tag :skip
  test "T73 stand-in (R147): Super's bot writes this file through Super" do
    flunk("a stand-in, not a test")
  end
end
