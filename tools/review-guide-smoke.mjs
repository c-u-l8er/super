import {open} from './lib/cockpit-control.mjs';
import assert from 'node:assert/strict';
let app;
try{
 app=await open({port:4795,fixture:true});
 await app.page(`import('./review-guide.js').then(({guideReview})=>{
 const task={id:'guide-task',revision:1,status:'planned',required_checks:{profiles:['super-javascript-behavior@1']}},attempt={id:'guide-attempt',task_revision:1,status:'recorded',test_runs:{}};
 const current=()=>({frame:{world:window.cockpit.frame.world,projection:{development_tasks:{[task.id]:task},development_attempts:{[attempt.id]:attempt}}}});
 window.guideFixture={task,attempt,current,calls:[]};
 window.mountGuide=()=>{document.querySelector('#guide-fixture')?.remove();const card=document.createElement('details');card.id='guide-fixture';card.open=true;card.dataset.attemptId=attempt.id;
 card.innerHTML='<summary>Review fixture</summary><select id="attempt-test-profile-guide-attempt"><option>super-javascript-behavior@1</option></select><button id="attempt-run-guide-attempt">Run</button><button data-stage-saved-review>Stage</button><section data-acceptance-run><input><button>Accept</button></section><p role="status"></p>';
 const material=document.createElement('details');material.innerHTML='<summary>Retained proposal</summary><pre>Proposed file</pre>';card.append(material);document.querySelector('#workspace-canvas').append(card);
 card.querySelector('#attempt-run-guide-attempt').onclick=()=>window.guideFixture.calls.push('test');card.querySelector('[data-stage-saved-review]').onclick=()=>window.guideFixture.calls.push('stage');card.querySelector('[data-acceptance-run] button').onclick=()=>window.guideFixture.calls.push('accept');
 guideReview({card,material,attempt,task,current});};window.mountGuide();})`);
 await app.until(()=>app.page(`return !!document.querySelector('[data-review-next]')`),10000,'guide mounted');
 assert.ok(await app.page(`const c=document.querySelector('#guide-fixture');return c.querySelector('[data-review-next]').textContent==='Review proposed files'&&!c.querySelector('.review-details').open`));
 await app.page(`document.querySelector('[data-review-next]').click()`);
 assert.ok(await app.page(`const c=document.querySelector('#guide-fixture');return c.querySelector('[data-review-next]').textContent==='Run the next check' && !c.querySelector('.review-guide details').hidden && !c.querySelector('.review-details').open`));
 await app.page(`document.querySelector('[data-review-next]').click();document.querySelector('.review-details [role=status]').textContent='Source changed. Prepare a fresh proposal.'`);
 await app.until(()=>app.page(`return document.querySelector('.review-guide [role=status]').textContent.includes('Source changed')`),10000,'refusal visible');
 assert.deepEqual(await app.page(`return window.guideFixture.calls`),['test']);
 await app.page(`const a=window.guideFixture.attempt;a.test_runs={r:{run_id:'r',started_at:'2026',state:'completed',profile:'super-javascript-behavior@1',outcome:{verdict:'pass',snapshot_sha256:'snapshot'}}};window.mountGuide()`);
 assert.equal(await app.page(`return document.querySelector('[data-review-next]').textContent`),'Apply the tested files in Editor');
 await app.page(`document.querySelector('[data-review-next]').click();window.mountGuide()`);
 assert.equal(await app.page(`return document.querySelector('[data-review-next]').textContent`),'Check saved files and accept');
 await app.page(`document.querySelector('[data-review-next]').click()`);
 assert.deepEqual(await app.page(`return window.guideFixture.calls`),['test','stage']);
 assert.ok(await app.page(`return document.querySelector('.review-details').open && document.activeElement===document.querySelector('[data-acceptance-run] input')`));
 await app.page(`window.guideFixture.task.revision=2;document.dispatchEvent(new Event('runtime-view-rendered'))`);
 assert.ok(await app.page(`return document.querySelector('[data-review-next]').disabled`));
 console.log('Review guide: progressive disclosure, visible refusal, progress across renders, existing control delegation, explicit acceptance and stale-plan protection passed.');
}finally{if(app)await app.close();}
