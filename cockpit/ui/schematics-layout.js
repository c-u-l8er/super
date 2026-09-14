export function schematicLayout(nodes,edges,columns){
 const cols=Math.max(1,Math.min(4,Math.floor(columns)||1)),w=230,h=180,pad=24;
 const points=new Map(nodes.map((n,i)=>[n.id,{x:pad+i%cols*w,y:pad+Math.floor(i/cols)*h}]));
 const paths=edges.flatMap((edge,i)=>{const a=points.get(edge.from),b=points.get(edge.to);if(!a||!b)return [];const bottom=a.y+104,ay=bottom+14+(i%3)*10,by=b.y-12,gutter=b.x-12;return [{...edge,path:`M ${a.x+98} ${bottom} V ${ay} H ${gutter} V ${by} H ${b.x+98} V ${b.y}`}];});
 return {points,paths,width:cols*w+pad*2,height:Math.ceil(nodes.length/cols)*h+pad*2};
}
export function adjacentNodes(id,edges){return new Set([id,...edges.filter(e=>e.from===id||e.to===id).map(e=>e.from===id?e.to:e.from)]);}
export const clampZoom=value=>Math.max(.5,Math.min(1.5,Math.round(value*10)/10));
