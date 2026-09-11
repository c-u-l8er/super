export function taskFileAttachment(task,path,draft,match,source){
  const matched=match?.matched===true&&match.task_ref===task.id&&match.revision===task.revision&&match.repository_ref===task.repository_ref;
  const repositoryNote=matched?`The native-selected Editor repository matched the plan's registered repository (${match.repository_ref}) when this file was shared. It will be checked again before staging. Repository matching alone is not validation or acceptance.`:"The person selected this Editor file for this request. Its match to the plan's runtime repository has not been verified. This snapshot is not validation or acceptance evidence.";
  const sourceNote=source?`\n\nSelected-file source record (other working-tree files are not captured):\n${JSON.stringify(source)}\n`:'';
  const content=`Development plan: ${task.id} (revision ${task.revision})\nTitle: ${task.title}\nAcceptance criteria:\n${task.criteria}\n\n${repositoryNote}${sourceNote}\n\nFile: ${path}\n\n${draft}`;
  if(new TextEncoder().encode(content).length>32000)throw Error('The plan and file exceed the attachment limit. Choose a smaller file.');
  return content;
}
