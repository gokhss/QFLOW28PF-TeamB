# Shared NTT/INTT controller integration

The implemented design blocks are `ntt_controller.sv`, `intt_controller.sv`,
`stage_counter.sv`, `butterfly_scheduler.sv`, and `ntt_control.sv`. `CODE1` is the unchanged original
reference. Files in `tb/ntt/` and `verification/scripts/` are verification only. See `SCHEDULING_DESIGN.md` for
the proposed scheduler/backend contract and the approved stage extraction.

## Architecture and status

**FROZEN:** one verified configurable core; shared arithmetic across algorithm
families. **TARGET:** TSMC 28 nm. **EXPERIMENT:** 1/2/4/8 lanes, reduction choice,
and physical PPA/security tradeoffs. No measured PPA claim is made here.

`ntt_controller` owns the only FSM implementation and supports runtime direction.
`intt_controller` is an inverse-only alternative wrapper, not another state
machine implementation. Instantiate the runtime-mode core once in the shared
fabric. Instantiating both entry points creates two controller instances; source
reuse does not merge separately instantiated hardware. Compile the wrapper with
the core and `stage_counter.sv`; do not compile the legacy CODE1 as another
module definition.

The controller instantiates one `stage_counter` that owns stage_count, the
captured final-stage limit and its comparison. The FSM generates load, clear,
and advance events; it no longer stores a duplicate stage index or limit.
The separate butterfly scheduler is connected by the surrounding integration;
the controller additionally exports the proposed controller_fault diagnostic. Twiddle, coefficient-memory,
and read/write-scheduler modules remain unimplemented.

## Configuration and parameters

Legal builds use unsigned power-of-two N >= 2 and LANES in {1,2,4,8}.
Counter capacity is log2(N) stages, with width max(1,clog2(log2(N))).
Invalid build parameters inhibit ready; they are not runtime error codes.
Build verification must reject invalid configurations. LANES constrains legal
integration choices but does not change stage-control timing. Downstream logic
owns lane grouping, including partial groups when N/2 is smaller than LANES.

| N | Full schedule | Width | cfg_last_stage for full schedule |
|---|---|---|---|
| 2 | 1 stage | 1 | 0 |
| 256 | 8 stages | 3 | 7 |
| 512 | 9 stages | 4 | 8 |
| 1024 | 10 stages | 4 | 9 |

**PROPOSED INTERNAL INTERFACE:** cfg_last_stage selects a nonempty prefix of
the schedule, captured with intt_mode when start && ready is sampled. Always
connect this new input: tie it to log2(N)-1 for the original full schedule.
No numeric profile IDs are decoded. ML-KEM's seven butterfly layers and ML-DSA's
eight layers can use different configurations of the same N=256 controller.
This alone does not implement either algorithm: twiddle ordering, addresses,
arithmetic representation, and inverse normalization belong downstream. The
mapping of project stage slots to these operations is **OPEN**. N=512/1024 are
generic parameter tests, not the transform lengths of ML-KEM-512/1024.

Stage indices always ascend from zero. The integration captures first span and
span progression independently of direction; a descending physical-address sequence is not the
same thing as a descending stage-ordinal counter.

## Edge semantics and ownership

All internal ports are **PROPOSED**, not cross-team contract freezes. Inputs are
synchronous to clk. Reset assertion is asynchronous; synchronized deassertion
must be supplied by the reset infrastructure. Reset clears local control state
and suppresses output strobes; reset is not proof of downstream zeroization.

The controller accepts start only when ready, enabled, configured legally, and
not canceled. No requests are queued. Ready and busy are mutually exclusive.
Busy remains asserted through COMPLETE (the result-retirement cycle), ABORT,
and ZEROIZE. Done is a one-cycle success indication, with no ready overlap.

The profile layer owns opcode/profile decoding and retained context association.
The four intentionally unused core inputs are a2b_cmd_opcode, a2b_profile_id,
a2b_context_id, and butterfly_done. Keep them for integration; do not add dummy
logic. stage_done, rather than per-butterfly completion, advances this controller.
b2a_error_code stays zero. This is not a complete error reporting implementation:
the fabric must report cancellation/fault causes using the reconciled namespace.

The assignments document places the fabric-to-Team-A handoff under the fabric
integrator. Local b2a_* must not be wired as full-command status without that
integration: an ML-KEM/ML-DSA command generally contains multiple transforms and
other work. The upper controller retains full-command ownership between them.

LOAD is one cycle of initialization, not an acknowledged memory transfer.
stage_start is a one-cycle pulse with unconditional downstream acceptance.
If a future scheduler requires backpressure, an acceptance handshake is a new
**FUNCTIONAL CHANGE**. stage_done must remain low until all current-stage
pipeline results and writes have retired, and clear before the next stage runs.
It must include any final inverse normalization needed before result validity.

## Cancellation and zeroization

Zeroize dominates abort, which dominates normal transitions. Both affect the
state only at clock edges. Dispatch strobes and success validity are qualified
by cancellation; this is synchronous command/result acceptance qualification,
not a combinational arithmetic emergency halt. Do not use those strobes as
clocks or direct asynchronous memory-write controls.

butterfly_enable stays asserted in BUTTERFLY on the cancellation sampling edge:
the group committed at that edge may finish. No later group is authorized by
this controller. The downstream scheduler must honor run deassertion and the
clear request rather than continue issuing an autonomous full stage.

Abort goes through one ABORT cycle before ZEROIZE. Direct zeroize enters ZEROIZE
at the next edge. zeroize_req stays high until zeroize_done is sampled with
a2b_zeroize low. **PROPOSED INTERNAL INTERFACE:** zeroize_done must mean all
owned coefficient/pipeline state has been scrubbed, including protection from
late writes. Hold acknowledgement until request drops, and keep it low outside
that handshake. It is not a fixed one-cycle clear assumption. A failed/missing
acknowledgement leaves busy asserted; no arbitrary timeout is implemented.

A zeroize/abort in COMPLETE suppresses success immediately for the receiving
clock edge and enters recovery. A result already accepted on an earlier edge
cannot be retroactively revoked by this controller. Use ntt_control for implemented ECC/datapath/scheduler fault routing into the
existing abort path. Faults not delivered by the Fabric remain invisible.

Illegal FSM encodings inhibit ready/done, indicate transform_abort, and enter
ZEROIZE. This is RTL recovery, not a fault-tolerant encoding claim. Synthesis
recoding can alter recovery hardware and must be reviewed in the ASIC flow.

## Changes from CODE1

**FUNCTIONAL CHANGES:** captured direction and effective schedule; cancellation
priority in COMPLETE; qualified success/dispatch; reset/enable/config-aware
admission; busy through completion and clearing; acknowledged clearing; no
canceled counter increment; fail-closed illegal-state recovery. The two new
inputs are not backward-compatible with an unmodified instantiation.

RTL cleanup: safe declaration order, explicitly sized LAST_STAGE/increment,
consistent defaults and sequential holds. The four-bit FSM encoding and normal
eight-state flow are retained. Comparisons covering the full index range are
removed at elaboration. No datapath arithmetic or unused-port dummy logic added.
The added configuration registers are intentional capture storage, not PPA
savings. No timing, area, or power improvement has been measured.

## Verification

Executed with Verilator 5.038: all 30 standalone lint/elaboration checks passed
with only the four documented unused-input warnings; all 15 simulation
configurations passed with assertions enabled and inverse-wrapper comparisons.
The verification build additionally reports testbench/force-injection warnings;
these are separate from the standalone RTL lint results.

Run `python3 codes/verification/scripts/run_controller_checks.py` from the workspace root.
Requires Verilator and a C++ build toolchain. Temporary builds/logs go to codes/build/.
The script lints both entry points across 15 configurations and rejects all
diagnostics except the four named integration-input warnings. Directed tests
cover normal forward/inverse schedules, mode/config capture, short schedules,
all active abort states, zeroize in all eight states, concurrent events,
completion races, delayed acknowledgement, held zeroize, reset during each
state, busy starts, invalid runtime configuration, unused butterfly completion,
illegal state recovery, and inverse-wrapper equivalence. Six concurrent
assertions check cancellation, acceptance-to-busy, clearing, exclusive ready/busy,
and matching success outputs.

These checks do not prove arithmetic correctness, memory clearing, downstream
constant-time behavior, physical side-channel resistance, gate-level recovery,
or ASIC synthesis/timing. Those require the future blocks and implementation
flow. No formal verification is claimed. Further tests should include held-start
protocol behavior, early/stale stage_done as environment violations, invalid
build parameters, downstream late writes, normalization completion, and
independent algorithm reference vectors.

## Current review

See `RTL_REVIEW.md` for the current interface audit, new internal integration,
error-namespace conflict, exact changes and regression results.
