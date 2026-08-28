#!/usr/bin/env bash
# sabotage-bots — each bot law, falsified.
#
# The browser layer had a negative battery and no proof that any of its
# assertions could fail. `ampd/tools/sabotage.sh` and `tools/sabotage-host.sh`
# both exist because a test that passes with its fix disabled is an invariant
# check, not a falsifier, and this arc has now mislabelled three of them.
#
# Two screens the BEAM harness learned the hard way and this one has from the
# start:
#   * a sabotage that breaks the PARSE turns every assertion red, which reads
#     as the strongest possible result and is awarded for a broken sed. So the
#     file is parsed before the battery runs.
#   * a sed that matches nothing is reported as MISSED and counted as a
#     failure, never as a pass. Three probes went stale against a refactor in
#     W.1.2 and that is only harmless because missing scores as failing.
#
# One file is touched, and it is backed up ONCE however many probes target it
# — the multi-pair backup bug in F.8.2.3 wrote a sabotage into the source tree
# permanently because it backed the same file up per pair.
set -uo pipefail
cd "$(dirname "$0")/.."

SRC=site/app-prototype.html
ORIG=$(mktemp)
cp "$SRC" "$ORIG"
restore(){ cp "$ORIG" "$SRC"; }
# **AN `INT` HANDLER THAT DOES NOT EXIT IS NOT A SIGNAL HANDLER.**
#
# `trap 'restore; rm -f "$ORIG"' EXIT INT TERM` runs the cleanup on Ctrl-C
# and then CARRIES ON — the sabotage loop keeps going with the backup
# already deleted, so the next probe writes a sabotage the restore can no
# longer undo. An earlier round established the three-trap form and this
# file was written afterwards without it. The EXIT trap still fires when
# the signal handler exits, so the tree is restored exactly once.
cleanup(){ restore; rm -f "$ORIG"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FALSIFIED=0; NOT=0

probe(){
  local name="$1" expect="$2" expr="$3"
  restore
  perl -0pi -e "$expr" "$SRC"

  if cmp -s "$SRC" "$ORIG"; then
    echo "MISSED     $name — the pattern matched nothing; the probe is stale, not the law"
    NOT=$((NOT+1)); return
  fi
  if ! node --input-type=module -e "
    import {readFileSync} from 'node:fs';
    const h=readFileSync('$SRC','utf8');
    const s=[...h.matchAll(/<script>([\\s\\S]*?)<\\/script>/g)].map(m=>m[1]).join('\n;\n');
    new Function(s);" 2>/dev/null; then
    echo "BROKE      $name — sabotage does not parse; every assertion would go red for the wrong reason"
    NOT=$((NOT+1)); return
  fi

  local out; out=$(node tools/authority-battery.mjs 2>&1)
  if grep -q "^FAIL $expect\$" <<<"$out"; then
    echo "falsified  $name"
    FALSIFIED=$((FALSIFIED+1))
  else
    echo "NOT        $name — expected '$expect' to go RED and it did not"
    NOT=$((NOT+1))
  fi
}

# L1 — creating a bot confers nothing.
probe "a new bot is born holding something" \
      "a new bot holds no capability" \
      's/grants:\[\], may_delegate:\[\], presents:\[\], delegates:\[\],/grants:[{capability:"lane.spawn",resource:"*",duration:"run"}], may_delegate:[], presents:[], delegates:[],/'

probe "a new bot is born observing something" \
      "a new bot observes nothing" \
      's/grants:\[\], may_delegate:\[\], presents:\[\], delegates:\[\],/grants:[{capability:"super.observe.lanes",resource:"*"}], may_delegate:[], presents:[], delegates:[],/'

# L4 — the citation gate and the observation gate are DIFFERENT gates. This is
# the W.1.3 bypass: a claim having a cite said nothing about whether the bot
# was permitted to read the cited thing.
probe "any object may be cited" \
      "citing an unobserved object refuses" \
      's/const unseen = built\.flatMap\(citedBy\)\.filter\(o=>!frame\.objects\[o\]\);/const unseen = [];/'

probe "citations optional again" \
      "an uncited claim is refused" \
      's/const uncited = built\.filter\(c=>citedBy\(c\)\.length===0\);/const uncited = [];/'

probe "claim kinds unclassified" \
      "a claim must declare a known kind" \
      's/const misKind = built\.filter\(c=>!CLAIM_KINDS\[c\.kind\]\);/const misKind = [];/'

# L4b — observation is scoped by RESOURCE. The W.1.3.1 bug was `mayObserve`
# admitting an undefined resource, plus a frame that asked once per KIND.
probe "the projection filters per kind, not per object" \
      "a lane-a grant yields exactly lane-a" \
      "s/  lanes\.filter\(l => admits\(sc,'lanes',l\.id\)\)\.forEach\(l =>/  lanes.filter(l => admits(sc,'lanes',l.id) || scopeOf(b).some(p=>p.kind==='lanes')).forEach(l =>/"

probe "an undefined resource admits the whole kind" \
      "a resource-scoped grant does not admit the bare kind" \
      "s/^function admits\(scope, kind, resource\)\{\$/function admits(scope, kind, resource){ if(resource===undefined) return scope.some(p=>p.kind===kind);/m"

# L6 — nothing global escapes. Three routes now: the frame admitting an object
# the bot may not observe, the cursor carrying the global authority digest, and
# freshness keyed on the global clock rather than the bot's own projection.
probe "observation checks bypassed in the frame" \
      "a zero-observation projection is empty" \
      's/^function admits\(scope, kind, resource\)\{$/function admits(scope, kind, resource){ return true;/m'

probe "the bot cursor carries the global authority digest" \
      "a bot cursor carries no global authority digest" \
      "s/^  const digest = 'sha256:'.*\$/  const digest = authoritySnapshot();/m"

probe "freshness keyed on the GLOBAL clock" \
      "scout learns nothing — its claim did not go stale" \
      "s@^  const now = botFrame\(basis\.bot\);\$@  const now = {cursor:{projection_digest:'v'+viewClock}};@m"

probe "the cursor carries the global view again" \
      "a frame carries no global clock" \
      "s/^             bot:b\.id, projection_digest:digest \} \};\$/             bot:b.id, view:viewClock, projection_digest:digest } };/m"

# L3 — one coherent frame, and UNESTABLISHED is not a badge on an ordinary
# utterance. W.1.3.1 let a bot speak from a frame whose facts were never shown
# to coexist, with a warning beside it.
probe "the basis is resampled at utterance time" \
      "every claim shares one basis" \
      's/basis:frame\.cursor, coherence:frame\.coherence \};/basis:assembleFrame(b).cursor, coherence:frame.coherence };/'

probe "an unestablished frame may still assert facts" \
      "an unestablished frame supports no factual claim" \
      "s@^  if\(frame\.coherence === 'UNESTABLISHED'\)\$@  if(false)@m"

probe "the frame is not built under a stability check" \
      "a coherent frame says so" \
      "s/    if\(stabilityToken\(b\) === before\)\{ f\.coherence='COHERENT'; f\.settled=true; return f; \}/    if(true){ f.coherence=undefined; f.settled=true; return f; }/"

probe "coherence keyed on the GLOBAL clock" \
      "scout's frame is COHERENT despite continuous invisible churn" \
      "s@^function stabilityToken\(b\)\{ return assembleFrame\(b\)\.cursor\.projection_digest; \}\$@function stabilityToken(b){ return viewClock; }@m"

# L5 — validity is per claim KIND, the KIND is the object's to give, and
# three of the four kinds lose validity some way other than going stale.
probe "every claim kind decays" \
      "the recommendation is BASIS-BOUND" \
      "s@^  if\(c\.kind === 'interpretation'\) return 'BASIS-BOUND';\$@  if(false) return 'BASIS-BOUND';@m"

probe "no claim ever decays" \
      "the snapshot claim goes stale" \
      's/^function claimStale\(c, basis\)\{ return !VALIDITY_HOLDS\[claimValidity\(c, basis\)\]; \}$/function claimStale(c, basis){ return false; }/m'

# The W.1.3.2 rule GPT refused to let B.1 inherit: non-snapshot => immortal.
probe "non-snapshot claims are immortal again" \
      "a revoked grant INVALIDATES the decision it authorized" \
      "s@^function claimValidity\(c, basis\)\{\$@function claimValidity(c, basis){ if(c.kind !== 'snapshot') return CLAIM_VALIDITY[c.kind][0];@m"

probe "a decision outlives the authority behind it" \
      "a revoked grant INVALIDATES the decision it authorized" \
      "s@^    return \(now && now\.objects && cites\.every\(o => now\.objects\[o\.id\]\)\) \? 'VALID' : 'INVALIDATED';\$@    return 'VALID';@m"

probe "a durable claim survives retraction of its object" \
      "a retracted object RETRACTS the durable claim" \
      "s@^    return gone \? 'RETRACTED' : 'ESTABLISHED';\$@    return 'ESTABLISHED';@m"

# The retraction check must not become the next side channel: a bot that has
# LOST the grant naming the object may not learn the object was withdrawn.
probe "retraction is reported to a bot that may no longer see the object" \
      "a bot that lost the grant is NOT told the object was retracted" \
      "s@    const gone = cites\.some\(o => o\.kind && admits\(sc, o\.kind, o\.resource\) && !worldHolds\(o\)\);@    const gone = cites.some(o => !worldHolds(o));@"

# Validity must read the resource the frame stamped, not re-parse the id.
probe "the claim does not carry its resolved citations" \
      "the durable claim carries its resolved resource" \
      "s@^    cited: citedBy\(c\)\.map\(o => \(\{ id:o, kind:frame\.objects\[o\]\.kind,\$@    cited: citedBy(c).map(o => ({ id:o, kind:null,@m"

probe "a claim may declare any class it likes" \
      "a live object cannot support a durable claim" \
      "s@^    const bad = citedBy\(c\)\.find.*\$@    const bad = undefined;@m"

# Aggregates must cite what established them.
probe "an aggregate may under-cite" \
      "an aggregate citing only the summary is incomplete" \
      "s/      if\(mem && !mem\.every\(m=>cites\.includes\(m\)\)\)/      if(false)/"

# L2 — narrowing is over the WHOLE grant, not capability plus duration.
probe "delegation ignores what the bot holds" \
      "delegating an unheld capability refuses" \
      "s/  if\(!parent\) return \{refused:'delegation-exceeds-holder/  if(false) return {refused:'delegation-exceeds-holder/"

probe "holding implies passing on" \
      "holding is not permission to pass on" \
      's/  if\(!b\.may_delegate\.includes\(capId\)\)/  if(false)/'

probe "only capability and duration are checked" \
      "delegation may not widen resource" \
      "s/^const DIMS = \['resource','duration','workspace','run','placement','budget','policy'\];\$/const DIMS = ['duration'];/m"

probe "every dimension narrows vacuously" \
      "delegation may not widen placement" \
      's/^function narrows\(dim, parent, child\)\{$/function narrows(dim, parent, child){ return true;/m'

probe "budget may widen" \
      "delegation may not widen budget" \
      "s/    case 'budget':   return Number\(child\) <= Number\(parent\);/    case 'budget':   return true;/"

probe "duration enum reopened" \
      "duration enum stays closed" \
      's/  if\(req\.duration !== undefined && BOT_DUR\.indexOf\(req\.duration\) < 0\)/  if(false)/'

probe "a revoked parent leaves its children alive" \
      "revoking a parent revokes its children" \
      "s/  doomed\.forEach\(d=>\{ d\.status='revoked'; d\.revoked_reason='parent-grant-revoked'; \}\);//"

# L7 — a bot may hold an approval-class capability and may never hold the
# consent. The second half is the one that matters.
probe "consent is delegable" \
      "consent cannot be delegated" \
      's/  if\(HUMAN_ONLY\.includes\(capId\)\)/  if(false)/'

# L8 — a group is a disclosure context, and its scope is an intersection.
probe "group scope is a union" \
      "scout sees no lanes, so #TRVM discloses none" \
      's/  return ms\.map\(scopeOf\)\.reduce\(\(a,b\)=>intersectScope\(a,b\)\);/  return ms.flatMap(scopeOf);/'

# The W.1.3.1 group bug: intersecting KIND NAMES rather than predicates, so two
# bots with disjoint resources on one kind still disclosed to each other.
probe "group scope intersects kind names, not resources" \
      "disjoint resources on one kind intersect to nothing" \
      "s@^  return ms\.map\(scopeOf\)\.reduce\(\(a,b\)=>intersectScope\(a,b\)\);\$@  return [...new Set(ms.flatMap(m=>scopeOf(m).map(p=>p.kind)))].map(k=>({kind:k,resource:'*'}));@m"

probe "a collection is admitted by its own id, not its members" \
      "a collection is admitted by its members, not its own id" \
      "s@^  if\(o\.members\) return o\.members\.map\(m => \(\(objects\|\|\{\}\)\[m\]\|\|\{\}\)\.resource\);\$@  if(o.members) return [o.resource];@m"

# L8b — the object id is IDENTITY, the grant resource is AUTHORITY SCOPE, and
# W.1.3.2 recovered the second by parsing the first.
probe "the disclosure resource is parsed back out of the object id" \
      "a group granted capabilities(gateway) may be told about the gateway object" \
      "s@^  return \[o\.resource\];\$@  return [oid.split(':').slice(1).join(':')];@m"

probe "an object with no declared resource is disclosed anyway" \
      "an object with no declared resource is not disclosable" \
      "s@^    if\(!res\.length \|\| res\.some\(r => r === undefined \|\| r === null\)\)\$@    if(false)@m"

probe "the frame stops stamping the resource it admitted by" \
      "and it carries the resource it was admitted by" \
      "s@    resource:'gateway', label:'capability gateway', screen:'capabilities', sub:'gateway',@    label:'capability gateway', screen:'capabilities', sub:'gateway',@"

probe "a group discloses anything the speaker can see" \
      "ada may not state a lane fact in a group that cannot see lanes" \
      's/    if\(!res\.every\(r => admits\(sc, o\.kind, r\)\)\)/    if(false)/'

probe "non-members may speak" \
      "a non-member may not speak" \
      "s/  if\(!g\.members\.includes\(botId\)\) return \{refused:'not-a-member.*\$//m"

echo
echo "bot sabotage: $FALSIFIED falsified · $NOT not"
[ "$NOT" -eq 0 ]
