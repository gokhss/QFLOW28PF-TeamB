# Shared NTT/INTT RTL review — 2026-10-07

## A. Architecture and source authority

Reviewed the five requested references: Team-B Contract v0.2 YAML; Team-B
Programmable Cryptographic Compute PDF; Common Signals v0.8 CSV; Common Register
Map v1.0 PDF (and companion CSV); Team-2 Final Block Assignments DOCX. Reviewed
all four existing .sv modules, both design notes, both testbenches/runners, and
retained `CODE1` as a historical reference, not a compilable source dependency.

| Item | Source/status | Implementation implication |
|---|---|---|
| Shared NTT/INTT, PAU, Keccak; dedicated X25519 | Contract §§1–5, **FROZEN** | One runtime-mode transform controller, shared arithmetic downstream |
| All listed ML-KEM/ML-DSA variants | Contract §§6–7, **FROZEN** scope | Profile configuration, no per-variant RTL |
| Profile abstraction including ntt_mode, twiddle_profile, memory_schedule | Contract §1, **FROZEN** mechanism | Do not derive all geometry from direction alone |
| TSMC 28 nm | Project **TARGET** | No timing/area claim without ASIC implementation |
| 1/2/4/8 lanes | Contract §2, **EXPERIMENT** | Preserve LANES; no optimal value selected |
| Barrett/Montgomery | Contract §3, **EXPERIMENT / OPEN** | No reduction assumptions in scheduler |
| Masking scheme | Contract §8, **OPEN** | Deterministic control does not establish side-channel resistance |
| Profile-switch latency | Contract §1, **TARGET** | Not measured here |
| Abort timing | Contract §11.1 has synchronous closure, but pending-signoff text elsewhere | Implement user's explicit synchronous interpretation; do not relabel all closure text FROZEN |
| Assignment | Assignment DOCX | Shared NTT: Gokul Raj/Hasrini; PAU: Pokkali Ajay; Fabric: Akhilesh/Rahul; Akhilesh owns Fabric/Team-A handoff |

Important source conflicts remain **OPEN**. Contract §9/Common Signals propose
Team-B error class 0x8xxx, whereas Register Map §7 lists crypto 0x4001–0x4003,
lifecycle 0x8001 and ECC_UNCORRECTABLE 0x9002. Common Signals explicitly calls
error subdivision proposed. Register Map profile table includes IDs through C,
while its final checklist reserves 8–F. These need a controlled cross-team
resolution; this change selects neither numeric encoding. The requested
boundary signal widths are preserved.

### Inventory and resulting hierarchy

| File | Role | Review/change |
|---|---|---|
| ntt_controller.sv | Runtime forward/inverse FSM, configuration capture, local status | Preserve FSM; expose illegal-state fault |
| intt_controller.sv | Inverse-only wrapper instantiating that controller | Preserve alternative entry; forward fault output |
| stage_counter.sv | Sole stage progression and captured final-limit owner | Unchanged |
| butterfly_scheduler.sv | Logical pairs, atomic lane batches, retirement tracking | Validate schedule relationship; one lane-vector procedural owner; qualify lane mask |
| ntt_control.sv | **New PROPOSED internal integration** | One controller/counter/scheduler; configuration capture, fault routing and scrub interlock |
| CODE1 | Historical controller | Unchanged; exclude from builds |

Use `ntt_control` ONCE beneath the Fabric. `codes/filelists/ntt_control.f` uses filelist-relative paths with Verilator `-F`; it is a
source list and intentionally excludes the inverse-only wrapper and CODE1.
Instantiating both `intt_controller` and another controller duplicates physical
FSMs; source reuse alone never prevents that. No datapath exists in these files,
so sharing the computational implementation still requires the teammate's
single runtime-configurable backend.

The existing controller's legacy a2b/b2a names are retained for compatibility.
They are local adapter connections inside `ntt_control`, whose public ports are
internal control names. They must not be mistaken for full-command Team-A
status: a crypto command can contain multiple transforms and other operations.
No full Crypto Fabric was provided or implemented in this change.

## B. Signal/interface audit and ownership

| Signals | Current use / owner | Status and action |
|---|---|---|
| a2b_cmd_opcode[5:0] | Unused legacy controller input; future Fabric decoder | CSV width proposal; preserved per user |
| a2b_profile_id[3:0] | Unused legacy input; Fabric profile capture/decode | **FROZEN width**, encoding **PROPOSED** |
| a2b_context_id[4:0] | Unused legacy input; Fabric context association | **FROZEN width**; context isolation remains Fabric responsibility |
| a2b_start | Controller start && ready | CSV **FROZEN mechanism**; scheduler never consumes Team-A commands |
| a2b_abort/a2b_zeroize | Local cancellation; Fabric must fan out to all consuming engines | CSV **PROPOSED** signal details; cancellation obligations required |
| b2a_ready/busy/done | Local legacy-controller status only | Width/name preserved; CSV semantics **PROPOSED**, required full-operation interlock implemented |
| b2a_error_code[15:0] | Legacy placeholder zero, discarded by internal integration | **FROZEN width**; not suitable as final Fabric error output |
| c2b_ecc_status[1:0] | No raw Team-C port in low-level scheduler | CSV **PROPOSED** flags; [1] must abort consuming operation |
| ecc_uncorrectable | Qualified consuming-beat event into ntt_control | **PROPOSED INTERNAL**; physically routes to controller AND scheduler cancellation |
| error_config/ecc/datapath/scheduler/controller | Sticky individual cause outputs | **PROPOSED INTERNAL**, not numeric subfields; Fabric aggregates/encodes |
| state | ntt_controller / scheduler each owns its own distinct lifecycle | **INTERNAL**, no duplicate transform FSM |
| stage_count / last_stage | stage_counter | **INTERNAL**, one progression owner |
| stage_start / butterfly_enable | ntt_controller | **PROPOSED INTERNAL** stage dispatch / execution permission |
| schedule_first_span_log2 / schedule_span_descending | Captured profile settings in ntt_control | **PROPOSED INTERNAL**, new required standalone-scheduler inputs |
| batch_valid / lane_valid / coefficient pair addresses | butterfly_scheduler | **PROPOSED INTERNAL** work descriptor, not a PAU start/write strobe |
| batch_ready / batch_retired | Future memory/PAU backend | **PROPOSED INTERNAL**, atomic acceptance / all lane writes retired |
| twiddle address | Future twiddle_addr_gen | Not generated here; consumes stage/span/ordinal/mode metadata |
| coefficient write addresses | Backend retains accepted logical pair; RW block maps physical layout | **PROPOSED**, in-place layout requires agreement |
| stage_done | Scheduler | All batches retired, not final issue |
| zeroize_req / scrub_done / backend_flushed | Controller / scrub coordinator / backend | **PROPOSED INTERNAL**, scrub completion and no-late-effects fence are distinct |
| butterfly_done | Deliberately unused legacy input | Per-butterfly completion cannot replace write retirement |

No incorrectly sized existing Team-A ports were found. Missing implementation
at system level: opcode/profile validation, context retention, final-command
status aggregation, Team-C beat ownership qualification, final error encoding,
and all memory/arithmetic/twiddle interfaces. Those are not silently inferred
from the names of local legacy ports.

## C. RTL bugs and protocol risks

| Issue | Severity / evidence | Resolution |
|---|---|---|
| Independent range checks accept inconsistent stage/span | ERROR: original scheduler config_valid only checked each against MAX_STAGE | **FUNCTIONAL CHANGE**: widened first-span +/- ordinal must equal supplied span and stay in range |
| No executable ECC-to-NTT integration path | ERROR at subsystem integration: existing files only instructed Fabric to connect abort | **FUNCTIONAL CHANGE**: new integration fans qualified ECC and datapath faults into cancellation, retains named causes |
| lane_valid high in WAIT_RETIRE and during disabled offers | WARNING: original g_lane decode used OFFER OR WAIT_RETIRE | **FUNCTIONAL CHANGE**: mask only valid with batch_valid; backend must retain accepted descriptors |
| Generated lane slices mistaken for multiple drivers | No reproduced ERROR: baseline strict Verilator lint passed | RTL cleanup to one always_comb owner per packed vector; mapping unchanged |
| Illegal controller state unreported to Fabric | WARNING: recovery existed but only transform_abort indicated it | New independent controller_fault output, retained by integration |
| Local encoded error tied zero | ERROR if used as final Fabric status | Legacy placeholder explicitly discarded; named internal errors exported; final Fabric encoding remains incomplete/OPEN |
| Busy limited to initial dispatch | PASS: original controller covered LOAD through cleanup already | Preserve |
| zeroize/abort racing COMPLETE | PASS in original qualified controller output | Preserve; route faults into that same suppression path and test |
| Separate inverse wrapper accidentally instantiated alongside runtime controller | Architectural risk | Canonical source list/top uses only one runtime controller |
| Memory response interpreted as retirement | Integration risk | batch_retired requires every required write, not PAU result-valid |

## D. RTL guideline review

| Category | Result | Evidence / limitation |
|---|---|---|
| Latch avoidance / combinational defaults | PASS | Complete assignments; strict design lint |
| Blocking/nonblocking / FF separation | PASS | always_comb uses =; always_ff uses <= |
| Multiple procedural drivers | PASS | One vector owner after cleanup; no lint errors |
| FSM case coverage / illegal recovery | PASS | Enumerated states, explicit default drain/zeroize |
| Width, signedness, sizing, indexing | PASS for tested legal builds | Sized casts, safe widths, widened validation; 24 scheduler/integration configurations |
| Combinational feedback | PASS in design lint | Fault report registered in scheduler; controller fault decode independent of abort |
| Reset | WARNING integration requirement | Async assertion; synchronized release and common backend reset required |
| Parameterization | PASS within documented domain | Power-of-two N>=2, LANES=1/2/4/8; LANES=0 not a supported elaboration |
| Synthesizable constructs / ASIC portability | PASS source review; tool signoff pending | No delays/initial/assert/fatal in design RTL; no ASIC synthesis performed |
| Unnecessary logic / sequential depth | PASS review, PPA not measured | One stage owner; no datapath duplication; snapshot/status registers intentional |
| Lint cleanliness | PASS with documented exceptions | Scheduler/counter strict; four unused legacy controller inputs explicitly allowed |
| Verification friendliness | PASS | Deterministic handshakes, independent pair oracle, assertions and fault injection |
| Constant-time control | WARNING system dependency | No secret inputs; readiness/retirement timing is controlled by backend |
| Side-channel resistance | NOT ESTABLISHED | Requires masking implementation and physical assessment |

Four-state X behavior, synthesis FSM recoding, gate-level recovery, CDC/RDC and
reset release are not proved by Verilator's primarily two-state simulation.

## E. Scheduling mathematics and optimization opportunities

Let S=log2(N), execution ordinal s, span exponent m. For a selected contiguous
schedule, m=first-s (descending) or first+s (ascending). Require 0<=s<S and
0<=m<S. `cfg_last_stage` is an ordinal, not a distance. New integration validates
the whole interval before acceptance and captures first/direction once; the
stage counter captures the limit. Scheduler also validates each command.

For butterfly ordinal i in [0,N/2): d=2^m, A=2*d*floor(i/d)+(i mod d), B=A+d.
A has bit m zero, B has it one; the other bits encode i bijectively. Thus every
coefficient appears once per stage, with no same-stage pair overlap. Lane l in
batch g uses i=g*LANES+l. Distinct logical addresses do not prove physical bank
independence; the backend must serialize/backpressure if ports conflict.

| N | Full generic stage ordinals | Stage width | Butterflies/stage |
|---|---|---|---|
| 2 | 0 | 1 | 1 |
| 256 | 0–7 | 3 | 128 |
| 512 | 0–8 | 4 | 256 |
| 1024 | 0–9 | 4 | 512 |

Do not confuse parameter-set names with polynomial length. Standard ML-KEM has
N=256 and seven radix-2 butterfly layers (forward spans 7..1, inverse 1..7);
ML-DSA has N=256 and eight (forward 7..0, inverse 0..7). See
[FIPS 203, Algorithms 9–10](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.203.pdf)
and [FIPS 204, NTT/NTT inverse algorithms](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.204.pdf).
These are mathematical schedule examples, not frozen project profile IDs.
The same pair generator supports both directions; arithmetic operation ordering,
twiddle sequence/representation and inverse normalization still differ and must
be implemented by the configured backend. A seven-stage configuration alone is
not an ML-KEM implementation.

**ENGINEERING RECOMMENDATION:** retain the fixed one-bit address insertion and
shared masks; no multiply/divide datapath is needed for address generation.
One outstanding batch avoids tags/scoreboards but cannot hide inter-batch
memory/PAU latency. Consider deeper queues only after measuring the resulting
throughput/banking bottleneck. FSM recoding, added registers for fanout/timing,
precomputed masks, lane count and memory layout are synthesis experiments, not
claimed improvements. Added validation/status registers cost hardware; this
change prioritizes correctness, not a fabricated area reduction.

## F/G/H. Exact changes and rationale

1. `butterfly_scheduler.sv`: added first-span and descending inputs; widened
   expected-span arithmetic to detect underflow/overflow; kept constant-folded
   range checking. New validation rejects previously accepted inconsistent
   commands. Sequential scheduling, batch order and pair formula are unchanged.
2. Replaced per-generated-lane procedural blocks with one combinational loop,
   whole-vector defaults and explicit inactive-lane zeroing. lane_valid now
   follows batch_valid; coefficient/metadata outputs can still be present when
   invalid and must not be consumed then. No claim of PPA gain from this cleanup.
3. `ntt_controller.sv`: added controller_fault port and state-only illegal-state
   decode. Existing state register, transitions, stage counter, reset, busy and
   cancellation semantics are unchanged. No dummy metadata-use logic added.
4. `intt_controller.sv`: forwards that new output; still an alternative wrapper.
5. `ntt_control.sv`: added a single internal integration instance tree. Captures
   public schedule settings on start&&ready, derives per-stage span, rejects
   impossible intervals, routes named faults into both cancel paths, and retains
   fault causes through scrubbing until the next accepted operation/reset.
   Invalid requested configuration sets error_config without accepting a job.
   ECC status must represent a consumed/owned beat; a stale status is not an event.
6. Zeroization acknowledgement is scrub_done && scheduler_quiescent && !fault.
   The scheduler cannot become quiescent with unretired/unfenced accepted work.
   Scrub_done must itself certify erasure and protection from repopulation.
   Held abort/fault inhibits admission; held zeroize prevents cleanup exit.
7. `codes/filelists/ntt_control.f`: single-core compile list, excludes alternate INTT top.
8. Updated scheduler tests for explicit schedule geometry, invalid relation and
   mask assertions; added the integration testbench/runner and retained the
   controller regression. Updated design notes to remove stale integration gaps.
9. `stage_counter.sv` and `CODE1`: unchanged. No arithmetic, twiddle memory,
   coefficient memory or RW scheduler implementation was added.

All new interfaces are **PROPOSED INTERNAL**. The schedule-input additions and
lane-mask semantics require coordinated backend/integration updates. Old named
controller instantiations may leave the new diagnostic output open; positional
instantiations and wildcard testbenches must be reviewed.

### FSM and priority

| Controller state | Normal next state / condition | Busy |
|---|---|---|
| IDLE | LOAD on accepted start | 0 |
| LOAD | STAGE_START | 1 |
| STAGE_START | BUTTERFLY | 1 |
| BUTTERFLY | STAGE_WAIT on retired stage_done | 1 |
| STAGE_WAIT | COMPLETE if final, else STAGE_START and increment | 1 |
| COMPLETE | IDLE; success only without cancellation | 1 |
| ABORT | ZEROIZE | 1 |
| ZEROIZE | IDLE only after qualified scrub acknowledgement | 1 |
| Illegal | ZEROIZE, fault reported | 1 |

Reset dominates all. Zeroize overrides normal/abort transitions; abort or fault
in an active state enters ABORT. Existing committed effects may retire, but no
new batch/stage is accepted after cancellation is sampled. No clock gating or
combinational emergency datapath halt is added. Success accepted on an earlier
edge cannot be retroactively withdrawn. Busy in COMPLETE is intentional: the
operation remains owned through the completion acceptance edge.

| Scheduler state | Normal next state | Cancellation |
|---|---|---|
| IDLE | OFFER on legal stage_start | Remain idle |
| OFFER | WAIT_RETIRE on valid&&ready | IDLE, discard unaccepted descriptor |
| WAIT_RETIRE | OFFER or DONE after retirement | DRAIN unless retirement/flush already fences work |
| DONE | IDLE | Suppress stage_done |
| DRAIN | IDLE on flush, or ordinary canceled work retirement | Protocol faults require flush |
| Illegal | DRAIN, registered fault | No dispatch/success |

## I. Verification and assertions

Executed Verilator 5.038 with assertions enabled:

- 30 controller/wrapper lint configurations; only four named unused inputs.
- 24 scheduler + 6 counter strict lint configurations, no warning waivers.
- 24 new integration lint configurations; same four legacy unused inputs only.
- 15 controller/wrapper simulation configurations PASS.
- 24 scheduler/counter/controller integration simulation configurations PASS.
- 24 new internal-integration simulation configurations PASS.

Commands from repository root:

    python3 codes/verification/scripts/run_controller_checks.py
    python3 codes/verification/scripts/run_scheduling_checks.py
    python3 codes/verification/scripts/run_integration_checks.py

Coverage includes reset during operation, full and shortened schedules, first/
last stages, forward/inverse mode capture and switching, all four lane counts,
backpressure, pair coverage against a nested-block oracle, delayed retirement,
busy duration, busy start rejection, back-to-back transforms, abort/zeroize in
controller states, cancellation/retirement races, held clearing, illegal states,
invalid stage/span, ECC correctable vs uncorrectable with consuming-beat
qualification, datapath/scheduler/controller fault status, fault/zeroize during
COMPLETE, premature scrub acknowledgement and retained errors after cleanup.

Added SVA checks: lane_valid zero without batch_valid; success implies busy;
external cancellation/fault suppresses stage dispatch, batch offer and success;
stage index in range at dispatch. Existing suites also assert cancellation,
clearing, ready/busy exclusion and stage-completion protocol. These assertions
run in testbenches; no simulation-only constructs were inserted into RTL.

Next integration verification must use real data: official algorithm KATs;
forward/inverse arithmetic equivalence; normalization completion; bank conflicts;
per-lane write retirement; stale response rejection after flush; independent
scrub completion; ECC on actual Team-C handshakes; unsupported opcode/profile
and context policy; multi-engine full-command busy/error aggregation; four-state
simulation; CDC/RDC; ASIC synthesis/STA and post-recoding fault injection.

No formal verification, cryptographic KAT success, ASIC timing closure, measured
PPA benefit or side-channel security is claimed. Backend tests acknowledge work;
they do not prove physical writes or erasure.

## J. Remaining open decisions / teammate handoff

1. **OPEN:** resolve error/profile namespace conflicts. Final Fabric must encode
   named causes into the agreed 16-bit namespace and give fault precedence over
   success. It must NOT connect the legacy constant-zero error output as final
   status. Final full-command error/done semantics require the Fabric contract.
2. **PROPOSED:** agree atomic batch acceptance and capture all active descriptors
   on valid&&ready; no reliance on lane_valid while waiting for retirement.
3. **NOT DEFINED BY PROVIDED PROJECT DOCUMENTS:** exact coefficient/twiddle/result
   bus widths for this backend, ready/valid timing, memory/PAU pipeline latency,
   bank mapping and normalization placement. No operand/result buses invented.
4. Teammate boundary receives logical pairs, stage/span, butterfly ordinal and
   direction; future backend fetches operands/twiddles and launches the shared
   PAU. It returns aggregate retired completion or a fault. PAU result-valid alone
   must never drive batch_retired. No arithmetic datapath was changed.
5. Fabric/Team-C integration must qualify ECC status by the actual consuming beat
   and distribute cancellation/invalidation to all affected engines. The new
   local fault path is implemented; the absent physical bus/Fabric is not.
6. Final inverse normalization must precede successful transform retirement, or
   Fabric must schedule a separate finalization before full-command success.
7. **EXPERIMENT:** lane count, memory throughput, reduction method, masking and
   physical PPA tradeoffs remain open. No per-parameter-set hardware variants.
