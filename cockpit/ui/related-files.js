// A batch is checked completely before the bot composer is changed.
export function relatedFileSelection(files){
  if(!Array.isArray(files)||files.length<1||files.length>4)throw Error('Choose between one and four open files.');
  const paths=new Set();
  for(const file of files){
    if(!file||typeof file.path!=='string'||paths.has(file.path))throw Error('Each selected file must have a distinct path.');
    paths.add(file.path);
    if(typeof file.draft!=='string'||file.draft.includes('\0')||new TextEncoder().encode(file.draft).length>24000)throw Error(file.path+' is too large or is not complete text. Choose files of at most 24 KB.');
  }
  return files.map(file=>({file,path:file.path,original:file.original,draft:file.draft}));
}
export function validateContextBatch(items,existingCount){
  if(!Array.isArray(items)||!items.length||items.length>4||existingCount+items.length>4)throw Error('Attach up to four files per message. Remove an attachment or choose fewer files.');
  for(const item of items){
    if(!item?.reference||typeof item.attachment?.name!=='string'||typeof item.attachment?.content!=='string'||item.attachment.content.includes('\0')||new TextEncoder().encode(item.attachment.content).length>32000)throw Error('A selected file cannot be attached. No files were added.');
  }
  return items;
}
