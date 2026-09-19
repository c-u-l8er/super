import test from 'node:test';
import assert from 'node:assert/strict';
import {parseInventory,sshArguments,probe} from './fleet-probe.mjs';
const sample=`schema=super-host-probe@1
hostname=sample
os=FreeBSD
release=15.1-RELEASE
arch=amd64
user=travis
cpus=16
memory_bytes=30854651904
tool_git=yes
tool_node=no
tool_elixir=no
tool_erl=no
tool_cargo=no
end=super-host-probe@1
`;
test('inventory carries tools and capacity and makes no worker-readiness claim at all',async()=>{
 const r=await probe('sample',async()=>({stdout:sample}));assert.equal(r.status,'observed');assert.equal('workerReady' in r,false);assert.equal(r.inventory.logicalCpus,16);assert.equal(r.inventory.tools.node,false);
 assert.equal(parseInventory(sample.replace('os=FreeBSD','os=Linux')).os,'Linux');
});
test('malformed, duplicate, truncated and overflowing observations are rejected',()=>{
 for(const s of [sample.replace('end=super-host-probe@1',''),sample+'cpus=2\n',sample.replace('cpus=16','cpus=NaN'),sample.replace('memory_bytes=30854651904','memory_bytes=99999999999999999999'),sample.replace('tool_git=yes','tool_git=maybe'),sample.replace('hostname=sample','hostname=bad\x1b'),sample.repeat(100)])assert.throws(()=>parseInventory(s));
});
test('target cannot introduce SSH options or shell syntax',()=>{
 for(const target of ['-oProxyCommand=bad','host;touch /tmp/bad','$(id)','user@host\n','user@-bad','a b',''])assert.throws(()=>sshArguments(target));
 const args=sshArguments('user@host');assert.ok(args.includes('StrictHostKeyChecking=yes'));assert.ok(args.includes('BatchMode=yes'));assert.ok(args.includes('ForwardAgent=no'));assert.equal(args.at(-2),'user@host');
});
test('unreachable host never reuses a previous successful observation',async()=>{
 const r=await probe('sample',async()=>{throw Object.assign(Error('failed'),{stderr:'Host key verification failed.'});});assert.equal(r.status,'unavailable');assert.equal('workerReady' in r,false);assert.equal(r.inventory,undefined);
});
test('probe uses a bounded subprocess without a local shell',async()=>{
 await probe('sample',async(file,args,opts)=>{assert.equal(file,'ssh');assert.equal(opts.shell,undefined);assert.equal(opts.timeout,12000);assert.equal(opts.maxBuffer,16384);return {stdout:sample};});
});
test('a bhyve host reports each guest as running or stopped from its process list, never merely present',()=>{
 const withGuests=sample.replace('end=super-host-probe@1','hypervisor=bhyve\nguests_json=[{"id":"super-worker-02","label":"super-worker-02","status":"running"},{"id":"old","label":"old","status":"stopped"}]\nend=super-host-probe@1');
 const i=parseInventory(withGuests);assert.equal(i.hypervisor,'bhyve');assert.deepEqual(i.guests.map(g=>g.id+':'+g.status),['super-worker-02:running','old:stopped']);
 // the older probe's name list still parses, as present
 assert.deepEqual(parseInventory(sample.replace('end=super-host-probe@1','hypervisor=bhyve\nguest_names=a,b\nend=super-host-probe@1')).guests.map(g=>g.status),['present','present']);
 assert.throws(()=>parseInventory(sample.replace('end=super-host-probe@1','hypervisor=bhyve\nguests_json=[{"id":"x","label":"x","status":"alive"}]\nend=super-host-probe@1')));
 // the script asks the process list with a bracketed first letter so its own command line cannot match
 const script=sshArguments('user@host').at(-1);assert.ok(script.includes('pgrep -qf "bhyve: [$first]$rest"'));assert.ok(!script.includes('guest_names='));
});
