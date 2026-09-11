// Explicit local operator CLI. Does not submit runtime validation or acceptance.
import {readFile} from 'node:fs/promises';
import {runProposalTests} from './lib/proposal-test-runner.mjs';
const controller=new AbortController();process.on('SIGTERM',()=>controller.abort());
const [repository,attemptFile,runRoot,profile]=process.argv.slice(2);
if(!repository||!attemptFile||!runRoot||![5,6].includes(process.argv.length)){console.error('Usage: node tools/proposal-test-runner.mjs REPOSITORY REVIEW_ATTEMPT_JSON EXISTING_RUN_DIRECTORY [PROFILE]');process.exitCode=2;}
else try{
  const bytes=await readFile(attemptFile);if(bytes.length>65536)throw Error('Review record exceeds 64 KiB.');
  const result=await runProposalTests({repository,attempt:JSON.parse(bytes),runRoot,signal:controller.signal,profile,timeoutMs:['super-elixir-review@1','super-rust-review@1'].includes(profile)?120000:30000});
  console.log(JSON.stringify({directory:result.directory,state:result.record.state,verdict:result.record.verdict,reason:result.record.reason,snapshot_sha256:result.record.snapshot_sha256},null,2));
  process.exitCode=result.record.verdict==='pass'?0:1;
}catch(e){console.error(e.message);process.exitCode=1;}
