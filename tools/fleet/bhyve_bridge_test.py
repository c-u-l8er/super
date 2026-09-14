import importlib.util,json,unittest
from types import SimpleNamespace
from pathlib import Path
spec=importlib.util.spec_from_file_location('bridge',Path(__file__).with_name('bhyve-bridge.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
class BridgeTests(unittest.TestCase):
 def test_only_fixed_guest_command_is_executed(self):
  raw=json.dumps({'operation':'status','id':'fc-'+'a'*32}).encode()
  def run(command,**kw):
   self.assertEqual(command,b.COMMAND);self.assertEqual(command[-2:],['fleet@127.0.0.1','super-fleet-check']);self.assertEqual(kw['input'],raw)
   return SimpleNamespace(returncode=0,stdout=b'{"state":"unknown"}')
  self.assertEqual(b.forward(raw,run),{'state':'unknown'})
 def test_invalid_envelopes_never_reach_ssh(self):
  def run(*a,**kw):self.fail('SSH must not run')
  for raw in [b'x'*196609,b'{"operation":"shell"}',b'{"operation":"status","id":"x","command":"id"}']:
   with self.assertRaises((AssertionError,ValueError)):b.forward(raw,run)
 def test_failed_or_oversized_responses_are_not_receipts(self):
  for p in [SimpleNamespace(returncode=1,stdout=b'{}'),SimpleNamespace(returncode=0,stdout=b'x'*98305)]:
   with self.assertRaises(AssertionError):b.forward(b'{"operation":"status","id":"x"}',lambda *a,**kw:p)
if __name__=='__main__':unittest.main()
