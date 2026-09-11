// Bounded line comparison for the exact shared and proposed drafts. Line tokens
// retain endings so a final-newline or CRLF-only edit remains visible.
function lines(text){return text.match(/[^\n]*\n|[^\n]+$/g)??[];}
export function proposalChanges(before,after,{maxCells=500000,maxRows=600}={}){
  const a=lines(before),b=lines(after);let start=0,endA=a.length,endB=b.length;
  while(start<endA&&start<endB&&a[start]===b[start])start++;
  while(endA>start&&endB>start&&a[endA-1]===b[endB-1]){endA--;endB--;}
  let rows=[],added=0,removed=0,totalRows=0;
  function emit(kind,oldLine,newLine,text){totalRows++;if(kind==='added')added++;if(kind==='removed')removed++;if(rows.length<maxRows)rows.push({kind,oldLine,newLine,text});}
  const n=endA-start,m=endB-start,coarse=n>0&&m>0&&n*m>maxCells;
  if(coarse){for(let i=start;i<endA;i++)emit('removed',i+1,null,a[i]);for(let j=start;j<endB;j++)emit('added',null,j+1,b[j]);}
  else {
    const width=m+1,table=new Uint32Array((n+1)*width);
    for(let i=n-1;i>=0;i--)for(let j=m-1;j>=0;j--)table[i*width+j]=a[start+i]===b[start+j]?table[(i+1)*width+j+1]+1:Math.max(table[(i+1)*width+j],table[i*width+j+1]);
    let i=0,j=0;
    while(i<n||j<m){if(i<n&&j<m&&a[start+i]===b[start+j]){emit('context',start+i+1,start+j+1,a[start+i]);i++;j++;}
      else if(i<n&&(j===m||table[(i+1)*width+j]>=table[i*width+j+1])){emit('removed',start+i+1,null,a[start+i]);i++;}
      else{emit('added',null,start+j+1,b[start+j]);j++;}}
  }
  return {rows,added,removed,coarse,truncated:totalRows>rows.length,omitted:totalRows-rows.length,unchanged:before===after};
}
export function displayLine(text){return text.endsWith('\r\n')?text.slice(0,-2)+' ⟦CRLF⟧':text.endsWith('\n')?text.slice(0,-1):text+' ⟦no final newline⟧';}
