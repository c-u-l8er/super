import importlib.util, tempfile, unittest, base64, json
from pathlib import Path
spec=importlib.util.spec_from_file_location('worker',Path(__file__).with_name('worker.py'));w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
def request():
 files=[{'path':p,'body':base64.b64encode(b'// test').decode(),'sha256':w.digest(b'// test')} for p in w.FILES]
 return {'schema':'super-fleet-request@1','id':'fc-'+'a'*32,'binding':{'world':['world',1],'task':'dt_1','revision':2,'head':'b'*40,'host':'locuchest','guest':'100','profile':w.PROFILE},'files':files,'snapshot':w.digest(w.canonical([[f['path'],f['sha256']] for f in files]))}
class Tests(unittest.TestCase):
 def setUp(self): self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.calls=0
 def tearDown(self): self.tmp.cleanup()
 def runner(self,source): self.calls+=1;return {'state':'completed','verdict':'pass','exitCode':0,'output':'passed'}
 def test_repeat_reconciles_without_second_execution(self):
  r=request();one=w.handle({'operation':'start','request':r},self.root,self.runner);two=w.handle({'operation':'start','request':r},self.root,self.runner);three=w.handle({'operation':'status','id':r['id']},self.root,self.runner)
  self.assertEqual(one,two);self.assertEqual(one,three);self.assertEqual(self.calls,1)
 def test_same_id_different_task_rejected(self):
  r=request();w.handle({'operation':'start','request':r},self.root,self.runner);r['binding']['revision']=3
  with self.assertRaises(AssertionError):w.handle({'operation':'start','request':r},self.root,self.runner)
  self.assertEqual(self.calls,1)
 def test_interrupted_reservation_never_reruns(self):
  r=request()
  def crash(_):raise KeyboardInterrupt()
  with self.assertRaises(KeyboardInterrupt): w.handle({'operation':'start','request':r},self.root,crash)
  self.assertEqual(w.handle({'operation':'start','request':r},self.root,self.runner)['state'],'unknown');self.assertEqual(self.calls,0)
 def test_invalid_source_never_reserves(self):
  for change in ['path','hash','profile','unknown']:
   r=request()
   if change=='path':r['files'][0]['path']='../../root/.ssh/authorized_keys'
   if change=='hash':r['files'][0]['body']='AA=='
   if change=='profile':r['binding']['profile']='shell'
   if change=='unknown':r['command']='id'
   with self.assertRaises(AssertionError):w.handle({'operation':'start','request':r},self.root,self.runner)
  self.assertEqual(list(self.root.glob('fc-*')),[])
 def test_status_does_not_create_or_launch_request(self):
  r=w.handle({'operation':'status','id':'fc-'+'a'*32},self.root,self.runner);self.assertEqual(r['state'],'unknown');self.assertEqual(self.calls,0)
 def test_busy_worker_does_not_reserve_a_second_request(self):
  import fcntl
  with (self.root/'lock').open('a') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   self.assertEqual(w.handle({'operation':'start','request':request()},self.root,self.runner)['state'],'unknown')
   self.assertEqual(list(self.root.glob('fc-*.json')),[])
  self.assertEqual(self.calls,0)
 def test_receipts_are_private_and_durable_before_launch(self):
  r=request()
  def run(source):
   p=self.root/(r['id']+'.json')
   self.assertEqual(p.stat().st_mode & 0o777,0o600)
   self.assertEqual(json.loads(p.read_text())['state'],'reserved')
   return self.runner(source)
  w.handle({'operation':'start','request':r},self.root,run)
 def test_restrictive_agent_umask_does_not_hide_the_source(self):
  import os
  old=os.umask(0o077)
  try:
   def run(source):
    for p in [self.root,source,source/'tools',source/'cockpit',source/'cockpit/ui']:
     self.assertEqual(p.stat().st_mode & 0o777,0o755)
    return self.runner(source)
   w.handle({'operation':'start','request':request()},self.root,run)
  finally:os.umask(old)
 def test_receipt_outside_source(self):
  r=request()
  def run(source):
   self.assertFalse((source/(r['id']+'.json')).exists());self.assertTrue((self.root/(r['id']+'.json')).exists());return self.runner(source)
  w.handle({'operation':'start','request':r},self.root,run)
if __name__=='__main__':unittest.main()
