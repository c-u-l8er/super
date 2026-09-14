#!/usr/local/bin/python3.12
"""Fixed-command SSH bridge to the check-only account in super-worker-02."""
import json, subprocess, sys
COMMAND=['/usr/bin/ssh','-F','/dev/null','-T','-p','2222','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','HostKeyAlias=super-worker-02','-o','UserKnownHostsFile=/usr/local/etc/super-fleet/guest_known_hosts','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','ConnectTimeout=5','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-i','/usr/local/etc/super-fleet/guest_ed25519','fleet@127.0.0.1','super-fleet-check']
def forward(raw,run=subprocess.run):
    assert len(raw)<=196608, 'Request too large'
    msg=json.loads(raw)
    assert isinstance(msg,dict) and msg.get('operation') in ['start','status'], 'Invalid operation'
    assert set(msg)==({'operation','request'} if msg['operation']=='start' else {'operation','id'}), 'Invalid fields'
    p=run(COMMAND,input=raw,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=55)
    assert p.returncode==0 and len(p.stdout)<=98304, 'Guest response unavailable; reconcile the same request'
    return json.loads(p.stdout)
if __name__=='__main__':
    try: print(json.dumps(forward(sys.stdin.buffer.read(196609))))
    except Exception as e:
        print(json.dumps({'error':str(e)[:200]}));sys.exit(1)
