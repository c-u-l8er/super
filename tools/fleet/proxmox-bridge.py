#!/usr/bin/env python3
"""Separate forced-command key: only the fixed endpoint in VM 100, no shell."""
import json, subprocess, sys
if __name__ == '__main__':
    try:
        raw=sys.stdin.buffer.read(196609)
        assert len(raw)<=196608, 'Request too large'
        msg=json.loads(raw)
        assert isinstance(msg,dict) and msg.get('operation') in ['start','status'], 'Invalid operation'
        # Guest endpoint validates the complete message before any launch.
        p=subprocess.run(['/usr/sbin/qm','guest','exec','100','--timeout','50','--pass-stdin','1','--','/usr/bin/python3','/usr/local/libexec/super-fleet-worker.py'],input=raw,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=55)
        assert p.returncode == 0, 'Guest response unavailable; reconcile the same request'
        outer=json.loads(p.stdout)
        assert outer.get('exited') and not outer.get('out-truncated'), 'Guest response incomplete'
        value=json.loads(outer.get('out-data',''))
        print(json.dumps(value))
    except Exception as e:
        print(json.dumps({'error':str(e)[:200]})); sys.exit(1)
