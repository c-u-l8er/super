# Motor ↔ Machine Architecture — Research & Brainstorming Brief for Super / ComputeDriven

**Date:** 2026-08-23  
**Status:** research brief / design exploration, not yet a frozen spec  
**Audience:** next Opus/Super implementation session  
**Purpose:** continue the earlier **LLM → Motor → Machine** idea and decide what the cleanest Motor/Machine seam should be before it gets baked into Super, WRL/TRVM, the Factory, or physical-device work.

---

## 0. Executive thesis

The most promising interpretation of the idea is:

> **A Motor is not a machine, and it is not merely a model. A Motor is a bounded policy artifact that proposes actions against a typed Machine contract. A Machine is an embodiment/execution boundary. A separately identified Binding is what connects the two.**

That separation is the main recommendation of this brief.

The system should **not** make a Motor own a Machine, embed a machine identifier into a Motor, or let an LLM speak directly to low-level hardware buses. Instead:

```text
Goal / human / higher-level LLM
            │
            ▼
      Reasoner / Planner
            │
            │ bounded goal / task
            ▼
          Motor
   learned action policy
            │
            │ MotorProposal
            ▼
   Governor / TRVM laws
            │
            │ authorized intent
            ▼
      MotorBinding
   adapters + limits + lease
            │
            ▼
          Machine
  deterministic execution edge
            │
      ┌─────┴─────────────┐
      ▼                   ▼
 digital executor     physical driver
 browser/code/DB      ROS/CAN/EtherCAT/etc.
      │                   │
      └────────┬──────────┘
               ▼
       receipts / telemetry
               │
               ▼
        authoritative World
```

The strongest rule to preserve from current Super/TRVM thinking is:

> **The Motor proposes. Governance authorizes. The Machine executes. The World records what actually happened.**

For physical systems, add one more rule:

> **The learned layer never owns the hard real-time or safety loop.**

Current robotics research is moving in a surprisingly similar direction. Google DeepMind's 2026 Gemini Robotics stack explicitly separates a high-level embodied reasoning model from a lower-level vision-language-action model that executes motion; its on-device model exists specifically to avoid network latency/connectivity constraints. NVIDIA's GR00T models consume language, vision and proprioception and output *action chunks*, while conventional robotics stacks such as `ros2_control` keep lifecycle, hardware interfaces and low-jitter control loops beneath the learned policy. That is much closer to the architecture Super has been converging on than a naive "LLM controls a motor" design.

---

# 1. Terminology: avoid the word collision now

This project is using **Motor** in a higher-level computational sense. Physical robotics also contains literal electric motors. That can become confusing fast.

Use this convention in code/docs:

- **`Motor`** — capital M: learned or adaptive policy artifact in Super.
- **machine** / **`Machine`** — an embodiment or execution substrate exposing typed observations/actions.
- **actuator / drive / servo / joint** — physical motion hardware.
- **controller** — deterministic low-level control loop or state machine.
- **driver** — adapter between a Machine's semantic command interface and concrete hardware/software transport.
- **Binding** — the explicit artifact that mounts one Motor onto one Machine under a particular contract, calibration, governor policy and authority lease.

This lets the same abstraction cover:

```text
Motor → browser Machine
Motor → codebase Machine
Motor → game-world Machine
Motor → HVAC Machine
Motor → robot-arm Machine
Motor → CNC / industrial Machine
Motor → future WRL-native computer/robot
```

A physical servo motor is therefore **inside a physical Machine backend**. It is not the thing meant by the Super `Motor` abstraction.

---

# 2. Existing idea to preserve from the prior discussion

The previous brainstorming already had a good primitive:

```text
Motor M(P, G, C, H) → Δ
```

where the Motor receives some combination of:

- **P** — projection / perceived World state,
- **G** — goal,
- **C** — constraints/capabilities,
- **H** — relevant history,

and returns a proposed delta/action rather than mutating reality itself.

The earlier Motor result vocabulary was also useful:

```text
PROPOSE
REFUSE
REQUEST
ESCALATE
DECOMPOSE
WAIT
```

Keep that spirit. A Motor is more interesting if refusal, information requests and escalation are first-class outputs rather than treating every inference as a command.

The earlier lifecycle idea also still looks right:

```text
trace → train → evaluate → challenger → champion → install
```

with Super managing Motor lifecycle, the Factory producing/testing Motor artifacts, WRL expressing goals/actions/world semantics, and TRVM/governance deciding what may become real.

The key missing piece was: **what exactly does a Motor install onto, and what does “compatible with this Machine” mean?**

This brief proposes that `MotorBinding` is the answer.

---

# 3. Research signal: the industry is splitting reasoning from action

## 3.1 Google DeepMind: embodied reasoner → VLA

As of July/August 2026, Google DeepMind describes **Gemini Robotics ER 2** as a high-level embodied reasoning model that understands the physical world, plans multi-step tasks, coordinates robots, and then **hands motor execution to a lower-level VLA model**. Gemini Robotics 2 is the action model; Gemini Robotics On-Device 2 is the local version optimized for network/latency constraints.

The On-Device 2 model card describes inputs as text, images and robot proprioception, with **numerical robot actions** as outputs. DeepMind also emphasizes multi-embodiment adaptation rather than one model being permanently fused to one body.

**Implication for Super:** do not make the big LLM the machine driver. The higher model can reason, plan, select tools/Motors, generate goals, diagnose failure, or train challengers. The Motor should sit closer to action and can eventually be much smaller/faster than the reasoning model.

## 3.2 NVIDIA GR00T: action chunks + embodiment adaptation

NVIDIA's GR00T platform follows another useful pattern. Its VLA models accept onboard video, language commands and proprioceptive state, then output **action chunks**: predictive sequences of relative joint motions. GR00T is positioned as cross-embodiment and adaptable through post-training.

**Implication for Super:** the output of a Motor does not have to be a single atomic action. `MotorProposal` can contain a short bounded horizon / action chunk, as long as the Machine/Governor can interrupt, validate and settle it.

This is useful because asking an expensive model to choose every 1 ms control update is absurd, but having it choose a short, bounded action trajectory can be practical.

## 3.3 OpenVLA: embodiment-specific action normalization is real work

OpenVLA and subsequent optimized fine-tuning work expose another important fact: a learned policy cannot simply emit universal numbers and assume every robot/body interprets them identically. Action normalization, action spaces, camera layouts and embodiment adaptation matter.

**Implication for Super:** resist the temptation to define one magical global `float[] action` ABI. Define semantic, versioned action/observation schemas and make adaptation an explicit artifact.

## 3.4 `ros2_control`: controller/hardware separation is worth stealing

`ros2_control` separates controllers from dynamically loaded hardware components. Hardware components expose state and command interfaces; the controller manager owns lifecycle and hardware access. Its docs explicitly emphasize low jitter and real-time scheduling for actual hardware control.

**Implication for Super:** a physical Machine should expose a stable semantic interface above its device driver. Motor logic should not know whether a joint target ultimately becomes CANopen PDOs, EtherCAT process data, PWM, a serial message, or a simulator call.

## 3.5 CANopen CiA 402: drives already look like governed state machines

CiA 402 standardizes behavior for servo drives, frequency inverters and stepper drives with a finite-state automaton, control/status words and defined operating modes.

**Implication for Super:** the physical edge is not “write random voltage.” It is already naturally modeled as typed state transitions under a deterministic driver/controller. WRL/TRVM-style state and authority semantics can sit *above* that rather than replacing it.

## 3.6 EtherCAT: deterministic synchronization belongs below the AI layer

EtherCAT uses distributed clocks for tightly synchronized servo axes; its technology material describes sub-microsecond-class synchronization, and Safety over EtherCAT supports safety-critical motion/control architectures.

**Implication for Super:** let dedicated control infrastructure own synchronized actuation. Super/Motor should specify bounded intent/trajectory/goal semantics, not attempt to replace a proven bus-level servo scheduler with an LLM loop.

---

# 4. Recommended object model

I would make these distinct first-class concepts.

## 4.1 World

The **World** is authoritative state and causal history, not whatever the Motor currently believes.

It contains or projects:

- machine state,
- available capabilities,
- observations/telemetry,
- goals,
- leases,
- completed actions,
- refusals,
- failures,
- receipts,
- relevant environment state.

A Motor receives a **projection** of this World, never implicit global knowledge.

This stays aligned with the projection/authority work already happening in Super.

## 4.2 Machine

A **Machine** is an embodiment/execution boundary.

A Machine should answer:

1. What can be observed?
2. What can be commanded?
3. At what semantic level?
4. What invariants/limits can never be bypassed?
5. What timing model applies?
6. Can it be paused/reset/snapshotted/simulated?
7. What counts as successful settlement?

A Machine may be:

- a real physical robot,
- a simulated robot,
- a browser,
- a software repo,
- a database,
- a game actor,
- a cluster,
- a client computer,
- an HVAC system,
- an industrial process,
- eventually a WRL-native hardware machine.

The Machine is **not itself the learned intelligence**.

## 4.3 Motor

A **Motor** is an action policy artifact.

It packages more than weights:

- model/policy artifact,
- input observation contract,
- output proposal contract,
- supported Machine contract families,
- required capabilities,
- inference/runtime requirements,
- timing expectations,
- bounded action horizon,
- training provenance,
- evaluation evidence,
- known limitations,
- artifact hash/version,
- optional adapter requirements.

This is the important conceptual distinction:

> **Model ≠ Motor.**
>
> A model becomes a Motor only when it has an action ABI, authority assumptions, compatibility contract, provenance and evaluation evidence.

## 4.4 MotorBinding

The **Binding** is the missing connection object.

A Motor should not be modified when installed on a Machine. Instead mounting it creates a separate immutable/receipt-backed object:

```json
{
  "schema": "motor-binding@1",
  "binding_id": "...",
  "motor": {
    "artifact": "sha256:...",
    "abi": "motor-abi@1"
  },
  "machine": {
    "id": "machine:robot-arm-7",
    "contract": "sha256:..."
  },
  "observation_adapter": "sha256:...",
  "action_adapter": "sha256:...",
  "governor_policy": "sha256:...",
  "capability_lease": "lease:...",
  "calibration": "calibration:...",
  "mode": "shadow",
  "max_horizon_ms": 250,
  "rate": {
    "target_hz": 20,
    "deadline_ms": 40
  },
  "created_from_eval": "eval:...",
  "expires_at": "..."
}
```

The UI can call the operation **Mount Motor**, while the canonical record is a `MotorBinding`.

This gives us:

```text
one Motor → many Machines
one Machine → many Motors
one Machine → Motor A for navigation + Motor B for manipulation
one Motor → sim Machine first, real Machine later
```

without mutating the Motor artifact itself.

## 4.5 Driver / Adapter

The adapter translates between a Machine's native embodiment and the Motor's declared semantic spaces.

Examples:

```text
Motor action:     end_effector_delta@2
Machine action:   franka_joint_trajectory@4
Adapter:          IK + limits + calibration
```

or:

```text
Motor action:     browser.intent@1
Machine action:   super.web.command@3
Adapter:          typed command mapper
```

Adapters should be content-addressed and independently testable. This is analogous to a device driver plus an embodiment adapter, not “prompt glue.”

## 4.6 Governor

The Governor is the non-negotiable enforcement layer between proposal and execution.

It can validate:

- capability authority,
- machine state,
- action bounds,
- resource conflicts,
- current lease,
- rate/horizon limits,
- safety envelope,
- approval requirements,
- action preconditions,
- stale observations,
- contradictory Motor proposals.

A Motor cannot bypass the Governor merely because it is local, trusted, small, or previously successful.

## 4.7 Receipt / settlement

Every executed proposal should settle into something like:

```text
proposal_id
binding_id
motor_artifact_hash
machine_contract_hash
basis/world cursor
requested action
allowed/transformed action
execution start/end
observed outcome
refusal/fault if any
resulting World revision
```

That is the substrate the Factory later learns from.

---

# 5. Proposed ABI

The earlier compact formula can become a typed ABI rather than a philosophical statement.

```text
Motor.step(
  observation: ProjectionFrame,
  goal: Goal,
  constraints: MotorConstraints,
  history: MotorHistory
) -> MotorProposal
```

Possible `MotorProposal` variants:

```text
PROPOSE(ActionChunk)
REFUSE(Reason)
REQUEST(ObservationOrCapability)
ESCALATE(Reason, Context)
DECOMPOSE(Subgoals)
WAIT(Condition | Deadline)
```

### ActionChunk

```json
{
  "schema": "action-chunk@1",
  "basis": "world:cursor:...",
  "space": "machine.end_effector_delta@2",
  "horizon_ms": 200,
  "steps": ["..."],
  "interruptible": true,
  "expected_effects": ["..."],
  "stop_conditions": ["..."]
}
```

The Motor must not silently assume that `basis` remains current for the whole horizon. The binding/governor decides whether a proposal can continue, must be revalidated, or must be interrupted.

This makes Motor execution fit naturally with the current Super work on projection freshness, claim validity and authority.

---

# 6. Machine contract

A Machine contract could look roughly like:

```json
{
  "schema": "machine-contract@1",
  "machine_kind": "physical",
  "observations": [
    "joint_state@1",
    "camera.rgb@2",
    "gripper.force@1"
  ],
  "actions": [
    "joint_trajectory@3",
    "gripper.position@1"
  ],
  "timing": {
    "observation_hz": 50,
    "command_hz_max": 100,
    "hard_control_loop_hz": 1000
  },
  "invariants": [
    "joint_limits@4",
    "workspace_limits@2",
    "estop@1"
  ],
  "lifecycle": [
    "OFFLINE",
    "SAFE",
    "READY",
    "ACTIVE",
    "FAULT"
  ],
  "simulation": {
    "available": true,
    "contract_equivalent": true
  }
}
```

For a digital Machine, the same shape works with different semantics:

```text
observations: DOM projection, repo state, service health
commands: click/type/navigate, patch/apply/test, deploy/restart
invariants: capability rules, protected branches, effect wall
```

This is important: **Motor/Machine should be general enough that robotics is one embodiment of the architecture, not a second architecture bolted onto Super.**

---

# 7. The LLM's role

There are at least four legitimate ways an LLM can participate. The architecture should support all four without conflating them.

## Mode A — LLM is the Motor

Useful early in development.

```text
projection + goal → LLM → typed MotorProposal
```

Advantages:

- fastest to prototype,
- broad generalization,
- good for novel/low-frequency actions,
- generates traces for later training.

Disadvantages:

- latency,
- cost,
- stochasticity,
- poor fit for high-rate loops,
- harder to certify.

This should be considered the **bootstrap Motor**, not necessarily the final Motor.

## Mode B — LLM is the planner; smaller Motor executes

This is my recommended target architecture and is close to the current Gemini Robotics ER → VLA split.

```text
LLM / Reasoner
   ↓ goal/subtask
small Motor / VLA / policy
   ↓ bounded action chunk
Machine
```

This is probably where Super becomes interesting: the expensive model handles semantics and exception cases while cheap learned policies accumulate beneath it.

## Mode C — LLM is teacher / trace labeler

The LLM watches traces, explains failures, proposes policies/examples and helps generate training/evaluation data. It never directly controls the Machine during production.

This fits the Factory particularly well.

## Mode D — LLM is exception solver

Normal operation uses deterministic/small learned Motors. Unknown state causes:

```text
Motor → ESCALATE
      → LLM reasons
      → governed proposal
      → trace captured
      → candidate skill/Motor crystallized later
```

This matches the broader Super thesis that expensive cognition should be an exception path and successful higher-level reasoning should **crystallize downward** into cheaper reusable handlers/policies.

---

# 8. Motor hierarchy instead of one giant policy

Do not require one Motor to control every semantic timescale.

A physical Machine might have:

```text
mission Motor            ~0.2–2 Hz
manipulation Motor       ~10–30 Hz
locomotion Motor         ~20–100 Hz
trajectory controller    ~100–1000+ Hz
servo/drive loop         hardware-specific, often higher
```

A digital Machine might similarly have:

```text
project Motor        chooses work
coding Motor         proposes patch/action chunks
browser Motor        interacts with page
low-level executor   deterministic command API
```

The important part is not the exact frequencies. It is that each layer has a **contract and bounded authority**, and the low-level loops do not disappear merely because a higher-level model can theoretically emit actions.

Potential future abstraction:

```text
MotorGraph
  nodes = Motors/controllers
  edges = typed goals/observations/action spaces
  governor = authority + arbitration across edges
```

That begins to look like a learned causal/program graph rather than today's monolithic “agent harness.”

---

# 9. Physical Machines: recommended bridge

When Super eventually controls real hardware, I would not invent a proprietary bus first. Put Super above existing device-control standards and learn from them.

## Layer P4 — Super/WRL goal

```text
"move this part into fixture B"
```

## Layer P3 — Motor output

```text
semantic pose / action chunk / skill command
```

## Layer P2 — Machine adapter/controller

```text
IK / trajectory / mode state machine / limits
```

`ros2_control` is a good reference architecture here: controllers and hardware components are distinct, hardware exposes command/state interfaces, and lifecycle is explicit.

## Layer P1 — device protocol

Depending on hardware:

- CAN / CAN FD via Linux SocketCAN,
- CANopen / CiA 402 for drives,
- EtherCAT for synchronized multi-axis systems,
- serial/vendor APIs,
- industrial Ethernet/fieldbus,
- microcontroller-specific link.

## Layer P0 — hard safety and electrical control

- drive limits,
- current/torque limits,
- watchdog,
- emergency stop,
- safe torque off / equivalent safety functions,
- servo loop.

**No LLM output should bypass P2/P1/P0.**

For a prototype robot, SocketCAN is especially appealing because Linux exposes CAN as a normal network-style socket interface and even supports virtual CAN (`vcan`) for test/simulation. That could make a nice early Super Machine driver because the same higher-level code can run against a virtual bus before real hardware exists.

For industrial synchronized motion, EtherCAT is the more serious direction; its distributed clocks and safety ecosystem are exactly the sort of concerns the AI layer should consume as a Machine capability, not reimplement.

---

# 10. Shadow → Suggest → Execute should be a first-class binding mode

Never jump directly from “Motor loaded” to “Motor owns Machine.”

A binding should have an explicit mode:

### `shadow`

Motor sees the live projection and proposes actions, but nothing is executed. Compare proposals against human/controller decisions.

### `suggest`

Motor proposals are visible and may be accepted by a person or higher-level governor.

### `execute`

Motor may receive an execution lease for its declared action space and bounds.

Potential later modes:

```text
execute_canary
execute_bounded
execute_autonomous
```

Promotion can be evidence-based:

```text
shadow traces
  ↓
offline evaluation
  ↓
simulation replay
  ↓
challenger
  ↓
canary binding
  ↓
champion binding
```

The **Motor artifact does not change** during promotion. The Binding/authority does.

That is cleaner for provenance and rollback.

---

# 11. Motor compatibility should be proven at bind time

A Motor should not simply claim “works with robot arms.”

Binding should require compatibility evidence such as:

```text
Motor input schema      ⊇ projected observations provided by Machine
Motor action schema     → adapter exists → Machine action schema
rate/deadline            compatible
required capabilities    grantable
required sensors          present
calibration               valid
safety envelope           enforceable beneath Motor
model runtime             fits target hardware or remote budget
simulation/eval           meets threshold
```

This is where TRVM-style certificates could eventually become extremely useful.

A binding could be **committable only if** its compatibility proof is valid.

This is much more interesting than today's agent ecosystem, where a prompt/harness often “supports a tool” merely because its name appears in a schema.

---

# 12. Multi-Motor arbitration

A Machine will eventually have multiple Motors that want overlapping authority.

Do not solve this by prompt etiquette.

Possible deterministic arbitration inputs:

- capability scope,
- lease/ownership,
- Motor priority,
- World state,
- resource locks,
- action-space overlap,
- safety preemption,
- deadline,
- operator override.

Example:

```text
navigation Motor wants base.velocity
inspection Motor wants camera.pan
manipulation Motor wants arm.joint_trajectory
safety controller wants STOP
```

Non-overlapping resources can run concurrently. Conflicting resources need a deterministic winner or refusal.

This looks like a natural extension of the authority/lease work already happening in Super.

---

# 13. The World should learn from execution, not from Motor confidence

A Motor can say:

```text
"I expect the gripper to close on the object."
```

That is not World truth.

The Machine executes. Sensors/receipts then establish what happened.

This gives a clean physical version of a principle Super is already enforcing digitally:

> **Command success is not projection truth.**

For robotics:

```text
MotorProposal accepted
      ≠
object actually grasped
```

For code:

```text
patch command returned success
      ≠
tests/deployment actually correct
```

For a browser:

```text
click intent accepted
      ≠
page transitioned as expected
```

The same causal model can therefore span physical and digital Machines.

---

# 14. Training / Factory loop

The Factory could eventually produce Motors from governed traces.

Each training row can carry:

```text
World basis
Machine contract
Binding/adapters
Goal
projection
proposal
whether proposal was authorized
executed action
observed result
human correction
reward/eval label
refusal/escalation outcome
artifact/version identities
```

Then:

```text
large teacher / LLM
        │
        ├─ successful traces
        ├─ corrections
        └─ exception solutions
             ↓
       Motor dataset
             ↓
    candidate Motor
             ↓
  sim / replay / falsifiers
             ↓
         challenger
             ↓
     shadow on Machine
             ↓
         champion
```

This makes the earlier “AI Factory” idea concrete: **the factory manufactures action policies, not merely prompts.**

The Store could then distribute content-addressed Motor artifacts plus their manifests/evals, while site-local Bindings remain authority-sensitive and Machine-specific.

---

# 15. A useful analogy: drivers, cartridges and nervous systems

Three analogies help explain the architecture, but none should become the formal model.

## Driver analogy

The Motor does not know the bus. The Machine driver translates semantic commands into concrete execution.

Good for engineering.

## Cartridge analogy

A Motor is installable intelligence; a Binding is the cartridge inserted into a compatible Machine slot.

Good for product/UI language.

## Nervous-system analogy

LLM = deliberative cortex, Motor = learned motor program, deterministic controller = spinal/reflex layer, Machine = body, World projection = sensed environment.

Good for intuition, but avoid pretending biology maps perfectly.

The formal architecture should remain typed contracts + governed bindings.

---

# 16. What not to do

I would explicitly reject these designs for now:

## A. `machine.motor = model_id`

Too fused. No explicit compatibility, authority, calibration, adapter or provenance.

## B. LLM emits CAN/EtherCAT packets

Wrong abstraction level and unsafe. Bus semantics belong in a driver/controller.

## C. One universal raw numeric action vector

Embodiments differ. Make semantic action spaces versioned and adapt explicitly.

## D. Treat Motor output as state

A proposal is not an outcome. Only Machine execution + observation settles World truth.

## E. Put safety only in the prompt/system message

Hard constraints belong below the learned layer.

## F. Require every Machine to run ROS

ROS is useful prior art and a bridge for robotics; it should not define Super's general Machine ABI.

## G. Make one giant Motor do planning, manipulation and servo control

Different timescales and guarantees deserve different components.

## H. Make cloud availability part of the hard action loop

A cloud LLM may plan or teach. Physical/deterministic safety and control must remain local enough to survive network loss.

---

# 17. Recommended first experiment inside Super — before buying/building a robot

Do this **digitally first**.

Create a tiny `Machine` abstraction with a simulated embodiment.

Example Machine: **2D gantry / cursor world**

```text
state:
  x, y
  carrying?
  target objects

actions:
  move(dx, dy)
  grab()
  release()

invariants:
  bounds
  max step
  one object at a time
```

Create three Motor implementations against the exact same Machine contract:

1. **LLM Motor** — expensive general policy.
2. **Deterministic Motor** — hand-coded controller.
3. **Small learned Motor** — trained/distilled from traces.

Then test:

- same Motor against sim Machine and alternative Machine adapter,
- same Machine with different Motors,
- shadow/suggest/execute promotion,
- stale projection refusal,
- Motor requests missing observation,
- conflicting Motors and deterministic arbitration,
- action chunk interrupted mid-horizon,
- Machine lies/faults and receipts expose divergence,
- binding revoked while Motor is running,
- Motor artifact upgraded without mutating old Binding history.

Only after this abstraction feels right should a physical driver be added.

This experiment is more valuable than immediately wiring an LLM to an Arduino because it tests the architecture we actually care about.

---

# 18. Recommended first physical experiment

After the digital contract works, use a deliberately boring physical Machine.

A good target is a **1-axis or 2-axis position-controlled actuator** with encoder feedback and a controller that already enforces current/position limits.

Suggested architecture:

```text
Super Motor
   ↓ bounded target/action chunk
Machine adapter
   ↓ semantic position/velocity command
local controller
   ↓
SocketCAN / CANopen or vendor driver
   ↓
drive + actuator
   ↑
encoder/status telemetry
   ↑
Machine observation
   ↑
World receipt
```

Use `vcan` first to prove the driver path without hardware, then substitute a real CAN interface.

Do **not** make the initial physical proof “LLM generates PWM.” The interesting proof is that the same governed Motor/Machine contract survives the transition from simulated execution to a real embodied Machine.

---

# 19. Proposed falsifiers / laws

These are the questions I would want the next Opus agent to turn into executable tests before calling the abstraction real.

### MM-1 — Proposal is not mutation

A Motor can produce any proposal and the Machine/World remains unchanged until governance commits execution.

### MM-2 — Binding is the authority seam

Possessing a Motor artifact alone grants no Machine authority.

### MM-3 — Machine identity is not Motor identity

The same Motor hash can bind to two compatible Machines without producing a new Motor artifact.

### MM-4 — Adapter identity is semantic

Changing the action/observation adapter changes Binding identity and invalidates compatibility evidence tied to the old adapter.

### MM-5 — Revocation wins

Revoking a Binding/lease prevents future chunks from executing even if the Motor process continues running.

### MM-6 — Basis matters

A proposal made against an invalid/stale basis cannot silently execute when the action's preconditions depend on changed state.

### MM-7 — Action acknowledgement is not outcome

Machine command acknowledgement cannot by itself establish the predicted World effect.

### MM-8 — Hard limits are below the Motor

Sabotaging/replacing the Motor cannot bypass Machine-level limits.

### MM-9 — Action horizon is bounded

A Motor cannot acquire an unbounded future action lease by submitting one chunk.

### MM-10 — Execution multiplicity survives the stack

If an action is at-most-once, every layer capable of invoking it must preserve/discharge that multiplicity constraint. This is the physical/digital continuation of the W.1.4.1 law.

### MM-11 — Shadow cannot actuate

A shadow Binding can observe/propose/score but no path from its proposal reaches a Machine command interface.

### MM-12 — Simulation is not silently equivalent

A Motor passing simulation does not become executable on a physical Machine unless the Binding explicitly carries the required embodiment/compatibility evidence.

---

# 20. Open design questions for the next Opus session

These are worth brainstorming before coding too deeply.

1. **Is `Motor` the right permanent noun?** It is evocative and fits “learned motor program,” but collides with physical motors. Uppercase convention may be enough.

2. **Should `Machine` mean every executable substrate or only a persistent World-hosted object?** I lean broad: anything with typed observation/action ports and governed settlement can be a Machine.

3. **Does the Motor output WRL directly, or an action IR that WRL can encode?** My current preference: Motor returns a typed action/proposal IR whose canonical semantic representation can be WRL. Do not require a neural policy to emit pretty source text.

4. **Where does adapter logic live?** I lean Binding-owned, content-addressed adapter artifacts, never implicit transforms inside Motor runtime.

5. **Can Motors call Motors?** Probably via goals/subcontracts rather than direct hidden calls. A MotorGraph or orchestrator can make the hierarchy explicit.

6. **Should every Motor be learned?** Probably no. The interface should admit deterministic/manual policies too. A hand-coded controller can satisfy `motor-abi@1`; that gives us baselines and lets the Factory replace components gradually.

7. **What is the smallest Motor runtime?** The long-term interesting target may be tiny local policies/compiled nets/WRL programs with an LLM only on exception.

8. **How do we represent action time?** A physical Machine needs deadlines, horizon, interruption semantics and perhaps a Machine clock—not merely a list of actions.

9. **How much of `MotorBinding` belongs in TRVM law/certificates versus Super orchestration?** Likely identity/compatibility/authority laws in TRVM; lifecycle/UI/scheduling in Super.

10. **Does Factory train Motors per Machine or per contract family?** The bigger thesis becomes much stronger if Motors learn portable semantic action spaces and adapters handle embodiments.

---

# 21. Suggested sequence for implementation

Do not interrupt the current W.1.4.x → W.2 LIVE LOCAL sequence to build robotics. Treat this as the design lane to pick up after/alongside the desktop foundation.

Suggested progression:

```text
M.0  terminology + Motor/Machine/Binding records only
M.1  simulated digital Machine + deterministic Motor
M.2  LLM Motor using same ABI
M.3  shadow/suggest/execute + receipts
M.4  multiple Motors + arbitration + revocation
M.5  trace → challenger Motor training experiment
M.6  virtual physical bus / SocketCAN vcan Machine
M.7  real one-axis actuator
M.8  ROS2-control / richer robot embodiment adapter
M.9  VLA Motor experiment (OpenVLA/GR00T/etc.)
```

The critical milestone is not M.7. It is M.3/M.4: proving that intelligence can be swapped without changing Machine truth/authority semantics.

---

# 22. Strongest product/research thesis

The most exciting form of this idea is **not** “Super can control robots.” Lots of stacks can control robots.

It is:

> **Super can turn reasoning traces into installable, governed Motors that can be mounted onto compatible digital or physical Machines, while TRVM/WRL keep authority, causality, receipts and world truth outside the learned policy.**

That gives the portfolio a possible unifying line:

```text
Worlds are what exist.
Machines are what can act.
Motors are learned ways to act.
Bindings say where they may act.
Governance says what may become real.
Receipts say what actually happened.
The Factory turns expensive reasoning into cheaper Motors.
```

If that works, the architecture is more specific than **Agent = Model + Harness**. It becomes closer to a programmable substrate for manufacturing and deploying behavior.

And the physical-machine path becomes a particularly strong demonstration because the causal boundary is impossible to hand-wave: the robot either moved, the sensor either changed, and the receipt either establishes it or it does not.

---

# 23. External research consulted (current as of 2026-08-23)

These sources are research anchors, not dependencies the Super design must adopt wholesale.

1. **Google DeepMind — Gemini Robotics 2**  
   High-level Gemini Robotics ER 2 + lower-level VLA/On-Device architecture; multi-embodiment physical agents.  
   https://deepmind.google/models/gemini-robotics/

2. **Google DeepMind — Gemini Robotics ER 2**  
   Explicitly describes the embodied reasoning model as a high-level brain that hands motor execution to a lower-level VLA model.  
   https://deepmind.google/models/gemini-robotics/embodied-reasoning/

3. **Google DeepMind — Gemini Robotics On-Device 2 model card**  
   Text/image/proprioception inputs; numerical robot-action outputs; on-device execution.  
   https://deepmind.google/models/model-cards/gemini-robotics-on-device-2/

4. **NVIDIA — Isaac GR00T**  
   Cross-embodiment robot foundation models; video + language + proprioception → action chunks; simulation/training/runtime stack.  
   https://developer.nvidia.com/isaac/gr00t

5. **NVIDIA Research — GR00T N1.6**  
   Current open generalist humanoid robot foundation-model direction.  
   https://research.nvidia.com/labs/gear/gr00t-n1_6/

6. **OpenVLA**  
   Open VLA implementation and fine-tuning work; useful evidence around embodiment/action-space adaptation and action inference.  
   https://github.com/openvla/openvla

7. **ros2_control documentation**  
   Controller manager, hardware interfaces, lifecycle and real-time control architecture.  
   https://control.ros.org/

8. **CAN in Automation — CiA 402**  
   Standardized finite-state behavior and command/status interfaces for servo drives, inverters and steppers.  
   https://www.can-cia.org/can-knowledge/cia-402-series-canopen-device-profile-for-drives-and-motion-control

9. **Linux Kernel — SocketCAN**  
   Linux's common CAN networking interface; includes virtual CAN useful for development/testing.  
   https://docs.kernel.org/networking/can.html

10. **EtherCAT Technology Group — EtherCAT technology / Safety over EtherCAT**  
    Distributed clocks, synchronized motion and safety transport as examples of guarantees that belong below the learned layer.  
    https://www.ethercat.org/en/technology.html  
    https://www.ethercat.org/en/safety.html

---

# 24. One-paragraph handoff to Opus

**Please treat this as a brainstorming/research input, not an instruction to derail W.2.** The key proposal is to make `Motor`, `Machine`, and `MotorBinding` separate identities. A Motor is a content-addressed learned/deterministic policy with a typed observation/action ABI; a Machine is an embodiment/execution boundary with typed ports, lifecycle, timing and invariants; a Binding connects them through explicit adapters, calibration, governor policy and capability lease. Motor output is always a proposal against a World basis, never World truth. Governance authorizes, Machine executes, receipts establish actual outcomes. LLMs can bootstrap Motors, plan above them, teach them or solve exceptions, but the long-term direction is to crystallize repeated expensive reasoning into smaller local Motors. For physical Machines, preserve deterministic controllers and safety beneath Motor output, using existing hardware interfaces (ROS2-control/CANopen/EtherCAT/etc.) rather than letting an LLM own the real-time bus. The first implementation should be a simulated Machine and multiple interchangeable Motors before touching real hardware.
