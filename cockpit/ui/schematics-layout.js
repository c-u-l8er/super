import * as bundle from './vendor/elk.bundled.js';
const ELK=bundle.default??globalThis.ELK;
const engine=new ELK();
const cache=new Map();
const coordinate=value=>Math.round(value*1000)/1000;
const point=p=>({x:coordinate(p.x),y:coordinate(p.y)});
export const NODE_WIDTH=196,NODE_HEIGHT=104;
// Cached geometry depends on graph structure, never on changing status text.
export async function schematicLayout(nodes,edges,_columns,{direction='DOWN'}={}){
 const ids=new Set(nodes.map(n=>n.id)),valid=edges.filter(e=>ids.has(e.from)&&ids.has(e.to));
 const key=JSON.stringify([nodes.map(n=>n.id),valid.map(e=>[e.from,e.to,e.label]),direction]);
 if(cache.has(key))return cache.get(key);
 const pending=(async()=>{
  const ports=new Map(nodes.map(n=>[n.id,[]]));
  const right=direction==='RIGHT';
  const links=valid.map((edge,i)=>{
   const from=`wire-${i}-from`,to=`wire-${i}-to`;
   ports.get(edge.from).push({id:from,width:1,height:1,layoutOptions:{'elk.port.side':right?'EAST':'SOUTH'}});
   ports.get(edge.to).push({id:to,width:1,height:1,layoutOptions:{'elk.port.side':right?'WEST':'NORTH'}});
   return {id:'wire-'+i,sources:[from],targets:[to]};
  });
  const graph=await engine.layout({id:'schematic',layoutOptions:{
   'elk.algorithm':'layered','elk.direction':right?'RIGHT':'DOWN','elk.edgeRouting':'ORTHOGONAL',
   'elk.padding':'[top=32,left=32,bottom=32,right=32]',
   'elk.spacing.nodeNode':'44','elk.layered.spacing.nodeNodeBetweenLayers':'64',
   'elk.spacing.edgeNode':'20','elk.layered.spacing.edgeNodeBetweenLayers':'20',
   'elk.spacing.edgeEdge':'16','elk.layered.spacing.edgeEdgeBetweenLayers':'16',
   'elk.layered.considerModelOrder.strategy':'NODES_AND_EDGES',
   'elk.layered.crossingMinimization.strategy':'LAYER_SWEEP','elk.randomSeed':'1'
  },children:nodes.map(n=>({id:n.id,width:NODE_WIDTH,height:NODE_HEIGHT,ports:ports.get(n.id),layoutOptions:{'elk.portConstraints':'FIXED_SIDE'}})),edges:links});
  const points=new Map((graph.children??[]).map(n=>[n.id,point(n)]));
  const paths=(graph.edges??[]).flatMap(e=>{const original=valid[Number(e.id.slice(5))];return (e.sections??[]).map(section=>{const segments=[section.startPoint,...(section.bendPoints??[]),section.endPoint].map(point);return {...original,segments,path:roundedPath(segments)};});});
  if(paths.length!==valid.length)throw Error('Some connections could not be routed.');
  return {points,paths,width:graph.width??64,height:graph.height??64};
 })();
 cache.set(key,pending);if(cache.size>24)cache.delete(cache.keys().next().value);
 try{return await pending;}catch(error){cache.delete(key);throw error;}
}
export function roundedPath(points){
 if(!points.length)return '';
 let path=`M ${points[0].x} ${points[0].y}`;
 for(let i=1;i<points.length-1;i++){
  const a=points[i-1],b=points[i],c=points[i+1],ab=Math.hypot(b.x-a.x,b.y-a.y),bc=Math.hypot(c.x-b.x,c.y-b.y),r=Math.min(8,ab/2,bc/2);
  if(!r)continue;
  const enter={x:b.x+(a.x-b.x)*r/ab,y:b.y+(a.y-b.y)*r/ab},exit={x:b.x+(c.x-b.x)*r/bc,y:b.y+(c.y-b.y)*r/bc};
  path+=` L ${enter.x} ${enter.y} Q ${b.x} ${b.y} ${exit.x} ${exit.y}`;
 }
 const last=points.at(-1);return path+` L ${last.x} ${last.y}`;
}
export function adjacentNodes(id,edges){return new Set([id,...edges.filter(e=>e.from===id||e.to===id).map(e=>e.from===id?e.to:e.from)]);}
export const clampZoom=value=>Math.max(.2,Math.min(1.5,Math.round(value*10)/10));
