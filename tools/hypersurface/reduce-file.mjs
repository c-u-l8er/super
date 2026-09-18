// Trusted experiment bootstrap arguments, never a Super command payload.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { createReducerHost } = await import(pathToFileURL(process.argv[2]));
const input = readFileSync(process.argv[3], 'utf8');
const result = await createReducerHost().reduce(input);
console.log(JSON.stringify(result));
process.exitCode = result.status === 'candidate' ? 0 : 2;
