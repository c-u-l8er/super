/* The invariants a recovery must hold, checked against what the driver acknowledged before a kill.
 *
 * `ev` is the lineage's acknowledgement file read after the kill and before the reboot (see
 * driver.exs). It holds one `boot` event per boot, so it splits into SEGMENTS, and EVERY segment in it
 * ended in a kill: the reboot has not written its own `boot` line yet.
 *
 * Two facts about Super shape these checks, both learned by getting them wrong once:
 *   · `perform` consumes the OLDEST active grant for the capability, not the one just minted. So an
 *     acknowledged effect is checked against its OWN `grant_ref`, never against the grant the driver
 *     minted before calling it.
 *   · a kill can land after a durable write and before the driver records it: a mint whose `grant`
 *     line never landed, an effect whose `ack` never landed. That is durable-but-unrecorded, not
 *     invented, and at most ONE of each can happen per kill (the driver is sequential). More than one
 *     at a boundary, or one anywhere else, is invented.
 */
const LEGAL = {null: ['PROPOSED'], PROPOSED: ['AUTHORIZED'], AUTHORIZED: ['APPROVED', 'CLAIMED'], APPROVED: ['CLAIMED'],
  CLAIMED: ['ATTEMPTED', 'FAILED', 'UNKNOWN'], ATTEMPTED: ['COMMITTED', 'FAILED', 'UNKNOWN'], COMMITTED: ['FAILED', 'UNKNOWN'], FAILED: [], UNKNOWN: []};
const num = id => Number(String(id).replace(/^\D+/, ''));

export function check(rep, ev) {
  const segs = []; for (const e of ev) { if (e.event === 'boot') segs.push([]); else segs.at(-1)?.push(e); }
  const acked = ev.filter(e => e.event === 'ack' && e.allow);
  const ackedIds = new Set(acked.map(a => a.effect_id));
  const recordedGrants = new Set(ev.filter(e => e.event === 'grant').map(e => e.grant));
  const effects = new Map(rep.effects.map(e => [e.id, e]));
  const grants = new Map(rep.grants.map(g => [g.id, g]));
  const receipts = rep.receipts.filter(r => r.kind === 'capability-effect-receipt@1');
  const receiptById = new Map(receipts.map(r => [r.id, r]));
  const lost = [], invented = [], unrecorded = [], split = [];

  // 1. every acknowledged transition is there, whole
  for (const a of acked) {
    const e = effects.get(a.effect_id);
    if (!e) { lost.push(`${a.effect_id}: acknowledged, absent`); continue; }
    if (e.state !== 'COMMITTED') lost.push(`${a.effect_id}: acknowledged COMMITTED, recovered ${e.state}`);
    if (receiptById.get(a.receipt_id)?.effect_ref !== a.effect_id) lost.push(`${a.effect_id}: acknowledged receipt ${a.receipt_id} absent`);
    const g = grants.get(e.grant_ref);
    if (!g) lost.push(`${a.effect_id}: its grant ${e.grant_ref} absent`);
    else if (g.status !== 'consumed' || JSON.stringify(g.consumptions) !== JSON.stringify([e.id])) lost.push(`${a.effect_id}: its grant ${g.id} reads ${g.status} ${JSON.stringify(g.consumptions)}`);
  }
  for (const g of recordedGrants) if (!grants.has(g)) lost.push(`${g}: acknowledged mint, absent`);

  // 2. nothing exists that neither an acknowledgement nor a kill boundary can account for
  const boundaries = segs.length;                           // every segment in `ev` ended in a kill
  const unackedEffects = rep.effects.filter(e => !ackedIds.has(e.id)).map(e => e.id).sort((x, y) => num(x) - num(y));
  // For each segment: the last acknowledged effect number up to and including it, and the first
  // acknowledged one after it. An unacknowledged effect sits at the kill that ended the segment it follows.
  const ackNums = segs.map(t => t.filter(e => e.event === 'ack' && e.allow).map(e => num(e.effect_id)));
  const bounds = []; let running = -1;
  for (let i = 0; i < segs.length; i++) {
    for (const n of ackNums[i]) running = Math.max(running, n);
    let nextFirst = Infinity; for (let j = i + 1; j < segs.length && nextFirst === Infinity; j++) if (ackNums[j].length) nextFirst = Math.min(...ackNums[j]);
    bounds.push([running, nextFirst]);
  }
  const perBoundary = new Map();
  for (const id of unackedEffects) {
    // which kill boundary it sits at: the segment whose acknowledged ids it follows
    const seg = bounds.findIndex(([last, nextFirst]) => num(id) > last && num(id) < nextFirst);
    if (seg < 0 || seg >= boundaries) { invented.push(`${id}: unacknowledged and not at any kill boundary`); continue; }
    perBoundary.set(seg, [...(perBoundary.get(seg) ?? []), id]);
  }
  for (const [seg, ids] of perBoundary) { if (ids.length > 1) invented.push(`kill ${seg + 1}: ${ids.length} unacknowledged effects ${ids.join(',')}`); else unrecorded.push(`effect ${ids[0]} (kill ${seg + 1})`); }
  // The demo seed's own grant for this capability is left REVOKED and unconsumed by `revoke_domain`;
  // it predates the loop and carries no authority, so it is not the driver's to account for.
  const unrecordedGrants = rep.grants.filter(g => !recordedGrants.has(g.id) && !(g.status === 'revoked' && g.consumptions.length === 0));
  if (unrecordedGrants.length > boundaries) invented.push(`${unrecordedGrants.length} grants no acknowledgement names, ${boundaries} kills to account for them`);
  else for (const g of unrecordedGrants) unrecorded.push(`grant ${g.id} ${g.status}`);

  // 3. histories are legal, consumption and receipts are one-to-one with real effects
  for (const e of rep.effects) {
    let prev = null;
    for (const s of e.history) { if (!(LEGAL[prev] ?? []).includes(s)) invented.push(`${e.id}: illegal ${prev}→${s}`); prev = s; }
    if (prev !== e.state) invented.push(`${e.id}: state ${e.state}, history ends ${prev}`);
    // CLAIMED is durable before consent is consumed (Gateway.perform), in a DIFFERENT store, so a kill
    // between the two saves leaves a claim whose consumption never landed. Super's recovery listing is
    // what must name it; a split the listing does not name would be the defect.
    if (e.history.includes('CLAIMED')) {
      const g = grants.get(e.grant_ref);
      if (!g || !g.consumptions.includes(e.id)) {
        const named = rep.recovery_listing?.[e.id]?.grant_registry;
        if (named && named !== 'COMPLETE') split.push(`${e.id} ${e.state}: claimed, consumption not durable; grant ${e.grant_ref} ${g?.status ?? 'absent'} ${JSON.stringify(g?.consumptions ?? [])}; listing grant_registry=${named}`);
        else invented.push(`${e.id}: CLAIMED without its grant ${e.grant_ref} consumed, and the recovery listing does not name it (${named ?? 'no row'})`);
      }
    }
  }
  for (const g of rep.grants) {
    if (g.consumptions.length > 1) invented.push(`${g.id}: consumed ${g.consumptions.length} times`);
    for (const c of g.consumptions) { const e = effects.get(c); if (!e) invented.push(`${g.id}: consumed by absent ${c}`); else if (e.grant_ref !== g.id) invented.push(`${g.id}: consumed by ${c}, whose grant is ${e.grant_ref}`); }
  }
  const byRef = new Map(); for (const r of receipts) byRef.set(r.effect_ref, (byRef.get(r.effect_ref) ?? 0) + 1);
  for (const [ref, n] of byRef) {
    if (n > 1) invented.push(`${ref}: ${n} receipts`);
    const e = effects.get(ref); if (!e) invented.push(`${ref}: receipt for an absent effect`); else if (!e.history.includes('COMMITTED')) invented.push(`${ref}: receipt, never COMMITTED (${e.state})`);
  }

  const inflight = unackedEffects.map(id => { const e = effects.get(id), g = grants.get(e.grant_ref); return {effect: id, state: e.state, history: e.history.join('>'), crash_phase: rep.recovery_listing?.[id]?.crash_phase ?? null, grant: e.grant_ref, grant_status: g?.status ?? 'absent'}; });
  // Effects that never reached CLAIMED hold no consent, and recovery does not close them: they stay
  // PROPOSED/AUTHORIZED, outside the recovery listing, for good. Reported, not counted as a violation.
  const open_preclaim = rep.effects.filter(e => ['PROPOSED', 'AUTHORIZED', 'APPROVED'].includes(e.state)).map(e => `${e.id} ${e.state}`);
  return {acked: acked.length, effects: rep.effects.length, receipts: receipts.length, lost, invented, unrecorded, split, open_preclaim, inflight};
}
