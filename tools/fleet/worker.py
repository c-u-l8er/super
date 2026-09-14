#!/usr/bin/env python3
"""Fixed-profile guest check endpoint. Install root-owned; invoke through QGA.
Ledger is outside the unprivileged, network-isolated test sandbox. A reserved ID
is never executed twice, including after interruption or a missing response.
"""
import base64, fcntl, hashlib, json, os, re, selectors, signal, subprocess, sys, time
from pathlib import Path
ROOT = Path('/var/lib/super-fleet-checks')
FILES = ['cockpit/ui/task-activity.js', 'tools/fleet-probe.mjs', 'tools/fleet-probe-test.mjs', 'tools/task-activity-test.mjs']
PROFILE = 'super-fleet-behavior@1'
LIMIT = 196608
DESTINATION = ('locuchest', '100')

def digest(b): return hashlib.sha256(b).hexdigest()
def canonical(v): return json.dumps(v, separators=(',', ':'), ensure_ascii=False).encode()
def syncdir(p):
    fd = os.open(p, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)
def save(p, v):
    tmp = p.with_suffix('.pending')
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
        json.dump(v, f, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, p); syncdir(p.parent)
def validate(r):
    assert isinstance(r, dict) and set(r) == {'schema','id','binding','files','snapshot'}, 'Invalid request'
    assert r['schema'] == 'super-fleet-request@1' and re.fullmatch(r'fc-[a-f0-9]{32}', r['id']), 'Invalid identity'
    b = r['binding']
    assert set(b) == {'world','task','revision','head','host','guest','profile'}, 'Invalid binding'
    assert isinstance(b['world'], list) and len(b['world']) == 2 and isinstance(b['world'][0], str) and 0 < len(b['world'][0]) <= 100 and type(b['world'][1]) is int, 'Invalid world'
    assert isinstance(b['task'], str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}',b['task']) and type(b['revision']) is int and b['revision'] > 0, 'Invalid task'
    assert re.fullmatch(r'[a-f0-9]{40,64}',b['head']) and (b['host'], b['guest']) == DESTINATION and b['profile'] == PROFILE, 'Unsupported destination/profile'
    assert isinstance(r['files'], list) and [f['path'] for f in r['files']] == FILES, 'Unexpected source paths'
    rows = []; contents = []
    for f in r['files']:
        assert set(f) == {'path','body','sha256'}, 'Invalid file'
        data = base64.b64decode(f['body'], validate=True)
        assert len(data) <= 32768 and digest(data) == f['sha256'], 'Source identity mismatch'
        rows.append([f['path'], f['sha256']]); contents.append(data)
    assert r['snapshot'] == digest(canonical(rows)), 'Snapshot identity mismatch'
    return contents

def execute(source):
    # QGA runs this supervisor as root, but test code runs as super in an empty,
    # network-isolated namespace. Nothing from /home, /root or the ledger is bound.
    args = ['/usr/bin/systemd-run','--quiet','--wait','--pipe','--collect','--unit=super-check-'+source.name,
            '-p','User=super','-p','MemoryMax=512M','-p','TasksMax=128','-p','RuntimeMaxSec=35','-p','KillMode=control-group','--',
            '/usr/bin/bwrap','--unshare-all','--die-with-parent','--new-session',
            '--ro-bind','/usr','/usr','--symlink','usr/bin','/bin','--symlink','usr/lib','/lib',
            '--symlink','usr/lib64','/lib64','--proc','/proc','--dev','/dev','--tmpfs','/tmp',
            '--ro-bind',str(source),'/source','--chdir','/source','--clearenv',
            '--setenv','PATH','/usr/bin:/bin','--setenv','LANG','C.UTF-8',
            '/usr/bin/node','--test','tools/task-activity-test.mjs','tools/fleet-probe-test.mjs']
    def limits():
        import resource
        resource.setrlimit(resource.RLIMIT_NOFILE,(128,128))
        resource.setrlimit(resource.RLIMIT_NPROC,(128,128))
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        resource.setrlimit(resource.RLIMIT_FSIZE,(1048576,1048576))
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=limits, env={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'})
    output = bytearray(); omitted = 0; deadline = time.monotonic()+40; timedout = False
    sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ)
    while sel.get_map():
        if time.monotonic() > deadline:
            timedout = True
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            break
        for key,_ in sel.select(.2):
            chunk = os.read(key.fd,8192)
            if not chunk: sel.unregister(key.fd); continue
            room = max(0,16384-len(output)); output.extend(chunk[:room]); omitted += max(0,len(chunk)-room)
    sel.close(); p.stdout.close(); code = p.wait(timeout=5)
    return {'state':'completed','verdict':'pass' if code == 0 and not timedout else 'fail','exitCode':code,'timedOut':timedout,'output':output.decode('utf-8','replace'),'omittedBytes':omitted,'nodeSha256':digest(Path('/usr/bin/node').read_bytes())}

def handle(msg, root=ROOT, runner=execute):
    assert isinstance(msg,dict) and msg.get('operation') in ['start','status'], 'Invalid operation'
    start = msg['operation'] == 'start'
    assert set(msg) == ({'operation','request'} if start else {'operation','id'}), 'Unknown fields'
    r = msg.get('request'); contents = validate(r) if start else None
    ident = r['id'] if start else msg['id']
    assert isinstance(ident,str) and re.fullmatch(r'fc-[a-f0-9]{32}',ident), 'Invalid request ID'
    root.mkdir(mode=0o755, parents=True, exist_ok=True)
    root.chmod(0o755)  # The unprivileged sandbox must be able to reach its source.
    receipt = root / (ident+'.json')
    # One global lock bounds concurrency and keeps receipt reservation atomic.
    with (root/'lock').open('a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if receipt.exists(): return json.loads(receipt.read_text())
            return {'state':'unknown','id':ident,'reason':'Worker busy; no completion available. Check status before starting another request.'}
        if receipt.exists():
            old = json.loads(receipt.read_text())
            if start: assert old['requestSha256'] == digest(canonical(r)), 'Request ID already belongs to different source'
            # Owning the lock means the prior supervisor is no longer executing.
            if old['state'] == 'reserved':
                old.update(state='unknown',reason='The worker stopped before saving an outcome. This request will not be rerun.'); save(receipt,old)
            return old
        if not start: return {'state':'unknown','id':ident,'reason':'No durable receipt found. The request is not resubmitted.'}
        assert len(list(root.glob('fc-*.json'))) < 32, 'Worker history is full'
        record = {'schema':'super-fleet-receipt@1','id':ident,'binding':r['binding'],'snapshot':r['snapshot'],'requestSha256':digest(canonical(r)),'state':'reserved','startedAt':int(time.time()*1000),'advisory':True}
        save(receipt,record)  # Before staging or process launch. Never reuse this ID.
        try:
            source = root/ident; source.mkdir(mode=0o755); source.chmod(0o755)
            for f,data in zip(r['files'],contents):
                p = source/f['path']; p.parent.mkdir(parents=True,exist_ok=True)
                for parent in p.parents:
                    if parent == source: break
                    parent.chmod(0o755)
                p.write_bytes(data); p.chmod(0o444)
            (source/'package.json').write_text('{"type":"module"}\n'); (source/'package.json').chmod(0o444)
            record.update(runner(source))
        except Exception:
            record.update(state='unknown',reason='Worker could not retain a completed check. This request will not be rerun.')
        record['finishedAt'] = int(time.time()*1000); save(receipt,record); return record

if __name__ == '__main__':
    try:
        config=Path('/etc/super-fleet-worker.json')
        if config.exists():
            c=json.loads(config.read_text()); DESTINATION=(c['host'],c['guest'])
            assert DESTINATION in [('locuchest','100'),('cd-floor-01','super-worker-02')], 'Invalid installed destination'
        raw=sys.stdin.buffer.read(LIMIT+1); assert len(raw)<=LIMIT, 'Request too large'
        print(json.dumps(handle(json.loads(raw)), ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'error':str(e)[:200]})); sys.exit(1)
