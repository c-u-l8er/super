import test from 'node:test';import assert from 'node:assert/strict';
import {schematicLayout,adjacentNodes,clampZoom,NODE_WIDTH,NODE_HEIGHT} from '../cockpit/ui/schematics-layout.js';
import {schematic,connections} from '../cockpit/ui/schematics-model.js';
function verify(layout,edgeCount){
 assert.equal(layout.paths.length,edgeCount);
 const boxes=[...layout.points].map(([id,p])=>({id,...p,right:p.x+NODE_WIDTH,bottom:p.y+NODE_HEIGHT}));
 for(const a of boxes)for(const b of boxes)if(a.id!==b.id)assert.ok(a.right<=b.x||b.right<=a.x||a.bottom<=b.y||b.bottom<=a.y,'node boxes overlap');
 for(const edge of layout.paths){
  assert.ok(edge.path.startsWith('M '));
  for(let i=1;i<edge.segments.length;i++){
   const a=edge.segments[i-1],b=edge.segments[i];assert.ok(a.x===b.x||a.y===b.y,'orthogonal segment');
   for(const r of boxes){const hit=a.x===b.x?a.x>r.x&&a.x<r.right&&Math.max(a.y,b.y)>r.y&&Math.min(a.y,b.y)<r.bottom:a.y>r.y&&a.y<r.bottom&&Math.max(a.x,b.x)>r.x&&Math.min(a.x,b.x)<r.right;assert.ok(!hit,`${edge.from} → ${edge.to} crosses ${r.id}`);}
  }
 }
}
test('layout is stable across state changes and ignores unknown endpoints',async()=>{const nodes=[{id:'a'},{id:'b'}],edges=[{from:'a',to:'b',label:'flows'},{from:'a',to:'missing'}];const a=await schematicLayout(nodes,edges,2),b=await schematicLayout(nodes.map(n=>({...n,state:'running'})),edges,3);assert.deepEqual(a,b);verify(a,1);assert.ok(a.points.get('b').y>a.points.get('a').y);});
test('actual Super workflows route all wires outside node interiors in both directions',async()=>{
 const ids=[...new Set(connections.flatMap(([a,b])=>[a,b]))],screens=ids.map(id=>[id,id,'Screen']);
 for(const direction of ['DOWN','RIGHT'])for(const screen of ['continue-work','editor','bots','development-tasks']){
  const graph=schematic({screen,screens,p:{development_tasks:{},bots:{}},world:'test'});verify(await schematicLayout(graph.nodes,graph.edges,3,{direction}),graph.edges.length);
 }
 verify(await schematicLayout(ids.map(id=>({id})),connections.map(([from,to,label])=>({from,to,label})),3),connections.length);
});
test('cycles, self loops, duplicate edges and disconnected nodes keep separate ports',async()=>{const nodes=['a','b','c','d'].map(id=>({id})),edges=[{from:'a',to:'b'},{from:'a',to:'b'},{from:'b',to:'c'},{from:'c',to:'a'},{from:'c',to:'c'}];const g=await schematicLayout(nodes,edges,3);verify(g,5);assert.notDeepEqual(g.paths[0].segments[0],g.paths[1].segments[0]);assert.ok(g.points.has('d'));});
test('tracing includes direct connections without lighting unrelated work',()=>{assert.deepEqual([...adjacentNodes('a',[{from:'a',to:'b'},{from:'c',to:'a'},{from:'b',to:'d'}])].sort(),['a','b','c']);});
test('zoom has bounded readable steps',()=>{assert.equal(clampZoom(.1),.2);assert.equal(clampZoom(3),1.5);assert.equal(clampZoom(.89999999),.9);});
