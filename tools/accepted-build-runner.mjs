import {readFile} from 'node:fs/promises';
import {runAcceptedBuild} from './lib/accepted-build-runner.mjs';
const controller=new AbortController();process.on('SIGTERM',()=>controller.abort());
try{const [repository,file,runRoot]=process.argv.slice(2);const bytes=await readFile(file);if(bytes.length>256*1024)throw Error('Review record exceeds build limit.');const result=await runAcceptedBuild({repository,attempt:JSON.parse(bytes),runRoot,signal:controller.signal});console.log(JSON.stringify({directory:result.directory}));process.exitCode=result.record.state==='completed'?0:1;}catch(e){console.error(String(e.message).slice(0,1200));process.exitCode=1;}
