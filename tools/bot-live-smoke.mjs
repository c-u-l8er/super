import {open} from './lib/cockpit-control.mjs';
import {writeFileSync,mkdirSync} from 'node:fs';
import assert from 'node:assert/strict';
const port=Number(process.env.APP_SMOKE_PORT||4691),out=process.env.SUPER_VISUAL_EVIDENCE_DIR||'/tmp/super-bot-live-smoke';
mkdirSync(out,{recursive:true});
let app;const checks=[];
const check=(label,value)=>{assert.ok(value,label);checks.push(label);console.log(label);};
async function shot(name){const r=await fetch(`http://127.0.0.1:${port}/session/${app.session()}/screenshot`);writeFileSync(`${out}/${name}.png`,Buffer.from((await r.json()).value,'base64'));}
async function send(text){await app.page(`const input=document.querySelector('#bot-message');input.value=arguments[0];input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#bot-send').click()`,[text]);}
async function ready(){await app.until(()=>app.page(`return !document.querySelector('#bot-send').disabled`),20000,'send ready');}
try{
 app=await open({port,fixture:true});
 await app.page(`document.querySelector('[data-nav="bots"]').click();document.querySelector('[data-nav="new-bot"]').click();for(const [k,v] of Object.entries({name:'Live activity test',role:'Test',group:'Test',instructions:'Test',provider:'claude'})){const el=document.getElementById('new-bot-'+k);el.value=v;}document.querySelector('#create-bot-submit').click();`);
 await app.until(()=>app.page(`return document.querySelector('#bot-activity-state').textContent==='Needs connection' && !document.querySelector('#bot-connect').disabled`),20000,'needs connection');
 check('Disconnected bot has a direct connect action',await app.page(`return document.querySelector('#bot-activity-action').textContent==='Connect provider'`));
 await app.page(`document.querySelector('#bot-connect').click()`);await ready();
 await send('Check the labels');
 await app.until(()=>app.page(`return document.querySelector('#bot-live-output').textContent.includes('I am checking')`),20000,'live output');
 check('Assistant text appears before final reply',await app.page(`return document.querySelector('#bot-send').disabled && !document.querySelector('#bot-transcript').textContent.includes('I checked the shared files')`));
 check('Private reasoning is not exposed',await app.page(`return !document.body.textContent.includes('PRIVATE_FIXTURE_MUST_NOT_APPEAR')`));
 check('Activity sidebar shows live assistant output',await app.page(`return document.querySelector('#bot-activity-rail').textContent.includes('I am checking')`));
 await shot('01-live-output');
 await app.page(`document.querySelector('[data-nav="runtime"]').click()`);
 check('Bot progress remains available on another page',await app.page(`return document.querySelector('#bot-activity-rail').textContent.includes('I am checking') && !document.querySelector('#bot-activity-rail').hidden`));
 await shot('01b-live-away-from-chat');
 await app.page(`document.querySelector('#bot-activity-rail [data-nav]').click()`);await ready();
 check('Completed reply appears in the transcript',await app.page(`return document.querySelector('#bot-transcript').textContent.includes('I checked the shared files')`));
 check('Completed state offers the next message',await app.page(`return document.querySelector('#bot-activity-state').textContent==='Reply complete'`));await shot('02-complete');
 await app.page(`document.querySelector('#bot-new').click()`);await send('PROPOSAL_FIXTURE');await ready();
 check('Proposals ask for review instead of claiming completion',await app.page(`return document.querySelector('#bot-activity-state').textContent==='Needs your review'`));
 check('Receiving a proposal does not execute it',!(await app.list('workspaces')).some(w=>w.name==='Reviewed fixture workspace'));
 await app.page(`document.querySelector('#bot-activity-action').click()`);
 check('Review action focuses a proposal control',await app.page(`return !!document.activeElement.closest('.bot-proposal')`));
 await app.page(`document.querySelector('#bot-new').click()`);await send('CANCEL_FIXTURE');
 await app.until(()=>app.page(`return !document.querySelector('#bot-cancel-reply').hidden`),15000,'cancel available');
 await app.page(`document.querySelector('#bot-cancel-reply').click()`);await ready();
 check('Cancellation restores the draft',await app.page(`return document.querySelector('#bot-message').value==='CANCEL_FIXTURE'`));
 check('Cancellation gives an honest stopped state',await app.page(`return document.querySelector('#bot-activity-state').textContent==='Reply stopped'`));await shot('03-cancelled');
 await app.page(`document.querySelector('#bot-new').click()`);await send('EXPIRED_FIXTURE');
 await app.until(()=>app.page(`return document.querySelector('#bot-status').textContent.includes('sign-in has expired')`),20000,'expired auth');
 check('Expired authentication blocks send',await app.page(`return document.querySelector('#bot-send').disabled`));
 check('Expired authentication exposes reconnect',await app.page(`return document.querySelector('#bot-activity-state').textContent==='Needs connection' && !document.querySelector('#bot-activity-action').disabled`));
 check('Failed request preserves the assignment',await app.page(`return document.querySelector('#bot-message').value==='EXPIRED_FIXTURE'`));await app.page(`document.querySelector('#bot-activity').scrollIntoView({block:'start'})`);await shot('04-reconnect');
 await app.page(`document.querySelector('[data-nav="edit-bot"]').click();const input=document.querySelector('#new-bot-instructions');input.value='Updated persistent instructions';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#create-bot-submit').click()`);
 check('Edited profile is stored for reopening',await app.page(`return JSON.parse(localStorage.getItem('super-bot-roster-v1')).bots.find(b=>b.name==='Live activity test').instructions==='Updated persistent instructions'`));
 writeFileSync(`${out}/checks.json`,JSON.stringify({passed:true,checks},null,2));
}finally{if(app)await app.close();}
