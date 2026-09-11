import {readFile} from 'node:fs/promises';
import {verifyTestedCheckout} from './lib/proposal-test-runner.mjs';
try{
 const [repository,attemptFile,runFile]=process.argv.slice(2);
 const result=await verifyTestedCheckout({repository,attempt:JSON.parse(await readFile(attemptFile,'utf8')),run:JSON.parse(await readFile(runFile,'utf8'))});
 process.stdout.write(JSON.stringify(result));
}catch(e){process.stderr.write(String(e.message).slice(0,1200));process.exitCode=1;}
