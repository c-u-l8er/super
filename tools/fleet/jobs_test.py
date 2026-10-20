# STAND-IN (R147) for plan dt_0243 (t-task-t75, superlane/t75/TASK.md revision 2): the file Super's bot (bt_0034) writes
# through Super. It exists only so the bot can propose into a file open in the Editor; the install merges the bot's bytes
# over it, and if the plan is cancelled a commit on main removes it. Its one test is skipped, so every profile stays green.
import unittest


class StandIn(unittest.TestCase):
    @unittest.skip("T75 stand-in (R147): Super's bot writes this file through Super")
    def test_stand_in(self):
        self.fail("a stand-in, not a test")


if __name__ == "__main__":
    unittest.main()
