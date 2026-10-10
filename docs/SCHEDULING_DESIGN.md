# Stage Counter / Butterfly Scheduling

## Scope and ownership

**FROZEN:** one configurable shared architecture. **TARGET:** TSMC 28 nm.
**EXPERIMENT:** LANES=1/2/4/8 and implementation PPA/security tradeoffs.
All interfaces introduced here are **PROPOSED INTERNAL INTERFACES**. Their
approved project-wide definitions are **NOT DEFINED BY PROVIDED PROJECT
DOCUMENTS**. This document defines this implementation's proposed protocol.

`stage_counter.sv` is instantiated exactly once by `ntt_controller.sv`. It owns
the stage index, captured final-stage index, range validation and comparison.
The controller owns its lifecycle FSM, direction capture and load/advance/clear
events. `intt_controller.sv` remains an alternative inverse wrapper and forwards controller_fault.

`butterfly_scheduler.sv` is connected by the new internal `ntt_control.sv`. It owns only the butterfly batch index and a captured stage
descriptor. Its stage snapshot is not another stage-progression counter. No
twiddle generator, twiddle ROM, coefficient memory interface, read/write
scheduler or arithmetic datapath has been implemented.

Compile the controller with `stage_counter.sv`; add `intt_controller.sv` when
using the inverse wrapper. Do not compile the legacy `CODE1` as a second
definition of ntt_controller.

## Stage counter

Legal N is a power of two >= 2. LANES is deliberately absent: it does not affect
stage progression. STAGE_COUNT=clog2(N), STAGE_W=max(1,clog2(STAGE_COUNT)).
For N=256/512/1024 the widths are 3/4/4 and maximum stage indices are 7/8/9.

Priority is reset > clear > load > guarded advance > hold. A legal load captures
cfg_last_stage and selects index zero. An invalid load holds existing state and
cfg_valid is low. The output cfg_valid describes the incoming configuration,
not the captured limit. Clear/reset set both registers to zero; last_stage then
reads true, as in the prior controller. No active-operation flag is implied.

Advance is allowed only below the captured limit, so an extra advance never
wraps. The controller still requests advancement only for an uncanceled
STAGE_WAIT -> STAGE_START transition, never directly from stage_done. Clear
occurs on the same outgoing COMPLETE/ABORT/ZEROIZE/illegal-state edges as before.

The approved controller extraction preserves its ports and intended valid-trace
timing. **FUNCTIONAL CHANGE outside the legal protocol:** an erroneous advance
at the final stage saturates; invalid direct loads are rejected. These unit
behaviors are not a claim of arbitrary fault-trace equivalence.

## Scheduler configuration and descriptors

Legal N is a power of two >= 2 and LANES is 1,2,4,8. Unsupported build values
must be rejected by integration/build validation; parameter-valid logic also
prevents acceptance of a stage command for an unsupported build.

Each stage has B=N/2 butterflies, in ceil(B/LANES) batches. Logical address width
is clog2(N); butterfly-index width is max(1,clog2(B)). A separate minimal batch
index cannot overflow on the final batch. The sole partial-batch case for legal
power-of-two builds is B<LANES; inactive lane outputs are zero.

At stage_start the scheduler captures stage_count, stage_span_log2 and
transform_intt. Both indices must be <= clog2(N)-1, and span must equal
schedule_first_span_log2 +/- stage_count as selected by schedule_span_descending. The controller guarantees an
idle scheduler at normal stage dispatch; there is no stage-ready port. Stage
commands received during ordinary active execution are faults. DRAIN ignores
new commands until cancellation/recovery resolves.

For butterfly ordinal i and span exponent m:

    distance = 2**m
    block    = floor(i / distance)
    offset   = i % distance
    A        = block * (2 * distance) + offset
    B        = A + distance

RTL inserts a zero bit at position m to form A and sets that bit for B, using
one stage-derived mask and a fixed one-bit shift. Lane l in batch g receives
i=g*LANES+l. Every legal coefficient occurs exactly once per stage, but distinct
logical addresses do NOT guarantee different physical SRAM banks or sufficient
ports. The future backend may serialize access or apply backpressure.

The profile layer chooses the span sequence; the scheduler does not decode
algorithm IDs or infer inverse geometry from mode alone. For a full schedule,
descending or ascending span exponents use the same hardware. For a shortened
schedule, the profile must select the appropriate span interval and twiddle
sequence. The exact project profile mapping remains **OPEN**. Capturing a
seven-stage limit alone does not implement ML-KEM or its inverse.

lane_valid is zero whenever batch_valid is zero, including WAIT_RETIRE.
The backend captures the mask and payload on acceptance. Descriptor payload is lane_valid, coeff_addr_a/b, butterfly_index, batch_stage,
batch_span_log2 and batch_intt. Array lane l is element [l] of each packed array.
Addresses are coefficient indices, not byte addresses or bank selections.
Twiddle logic consumes the stage/span/mode/ordinal metadata; no twiddle address
is generated here. Read/write logic retains the descriptor and associates the
same logical pair with in-place writeback (a proposed layout assumption).

## Handshakes and stage completion

| Port | Source -> destination | Contract |
|---|---|---|
| stage_start, stage_count, transform_intt | Controller -> scheduler | Capture a stage command on its rising edge |
| stage_span_log2 | Retained profile/schedule layer -> scheduler | Valid span on the stage command edge |
| butterfly_enable | Controller -> scheduler | High throughout execution until done or cancellation |
| batch_valid / batch_ready | Scheduler / future backend | Atomic acceptance of all active lanes on a rising edge |
| batch_retired | Future backend -> scheduler | One-cycle response, after every active lane's work and writes retire |
| stage_done | Scheduler -> controller | One-cycle success, after all batches retire |
| abort_req | Existing abort source -> scheduler | Connect to the controller's abort request source |
| zeroize, zeroize_req | Security source / controller -> scheduler | Either cancels work admission |
| backend_flushed | Future backend -> scheduler | Cancellation fence: no old write or response can subsequently occur |
| scheduler_quiescent | Scheduler -> clearing coordinator | No outstanding scheduler work; not proof that secrets were erased |
| scheduler_fault | Scheduler -> fabric/controller fault routing | Registered fault level, cleared only by coordinated backend flush |

batch_valid does not depend on batch_ready. The payload remains stable under
backpressure unless explicit cancellation overrides the request. The backend
must also honor cancellation at its acceptance edge. butterfly_enable is not a
general pause interface: the existing controller keeps it high in BUTTERFLY.

Exactly one batch may be outstanding. batch_retired must occur at least one
clock edge after acceptance and drop before the next rising edge. It is not a
per-lane result-valid or merely a last-issue indication. The proposed backend
owns aggregate lane-completion and write-retirement tracking. No tags or
multi-entry scoreboard are needed under this single-outstanding contract.

Read latency, write latency, PAU latency, pipeline latency, physical memory
banking and port availability are **NOT DEFINED BY PROVIDED PROJECT DOCUMENTS**.
No fixed cycle count for these is built into this scheduler. The response-edge
rule above is an explicit proposed interface constraint, not a memory latency.

The five states are IDLE -> OFFER -> WAIT_RETIRE -> (OFFER or DONE) -> IDLE,
with DRAIN for canceled outstanding work or protocol-fault recovery. DONE is
visible while the controller is in BUTTERFLY; the scheduler returns to IDLE as
the controller enters STAGE_WAIT, before the next stage_start.

## Cancellation, faults, and clearing

abort_req OR zeroize OR zeroize_req suppresses new batch acceptance and success.
No clocks or in-flight datapath register writes are combinationally halted.
An unaccepted offer is discarded. Accepted work must retire or be fenced by
backend_flushed before DRAIN exits; cancellation plus retirement on the same
edge returns idle without success. Cancellation also suppresses the DONE pulse.
Metadata remains available while an accepted batch is draining.

Unexpected stage commands, early/unsolicited retirement, an active-operation
flush without cancellation, invalid stage/span configuration, and illegal FSM
encodings fail closed. scheduler_fault is REGISTERED to avoid a combinational
loop through controller abort -> stage_start -> fault -> abort. Local acceptance
and success are suppressed immediately by fault detection. Fault recovery
requires backend_flushed; a normal retirement alone cannot clear fault_q.

On normal cancellation, backend_flushed certifies outstanding work has been
invalidated or retired and cannot return stale responses. On protocol-fault
recovery it fences ALL backend work, since bookkeeping cannot be trusted. The
fence must clear before a new stage command; a stage command with a stale/high
flush fence is rejected. A global reset must reset/invalidate the backend too;
resetting this scheduler alone cannot erase external pending writes.

backend_flushed must be produced independently of scheduler_quiescent. The
clearing coordinator can combine the fence, actual memory/datapath scrub
completion, and scheduler_quiescent to assert the controller's zeroize_done.
Do not directly wire zeroize_done back as backend_flushed if it depends on
scheduler_quiescent. No second zeroization FSM is implemented here.

## Remaining integration work and limits

- These local connections, configuration capture and named fault routing are now
  implemented in ntt_control; connect that internal top beneath the Fabric.
  No numeric error code was introduced.
- Implement memory read/write and aggregate retirement behind batch_ready and
  batch_retired; use the descriptor for twiddle requests and PAU launch.
- Inverse normalization is not implemented. The profile-aware backend must
  cover required normalization before final retirement, or the team must define
  an explicit finalization operation before overall completion. A scheduler
  stage_done by itself is not evidence of full inverse-transform correctness.
- Coordinate flushing, physical scrubbing and stale-response prevention.
- Measure throughput before adding deeper outstanding queues. With one batch
  outstanding, memory/PAU latency cannot be hidden across batches.

Control has no coefficient-data inputs or secret-dependent branches. Observable
timing can still follow backend readiness/retirement; downstream secret-dependent
stalling is not made safe by this controller. No side-channel security, physical
PPA improvement, ASIC timing closure, or formal verification is claimed.

## Verification commands

Executed with Verilator 5.038:

- PASS: 24 scheduler plus 6 stage-counter standalone lint configurations, with
  `-Wall`, warnings fatal and no warning waivers.
- PASS: all 24 N={2,4,8,256,512,1024} x LANES={1,2,4,8} simulation configurations
  with assertions enabled, including controller integration and registered
  scheduler-fault propagation through abort/zeroization.
- PASS: the existing 30 controller/wrapper lint configurations (only the four
  documented integration-input warnings) and 15 simulation configurations after
  stage extraction.

Verification testbenches additionally produce test-only filename, unused
observation/input-bit, and asynchronous-reset/force-injection diagnostics; those
are distinct from the warning-free standalone new-block RTL lint. These are
simulation results, not formal equivalence or gate-level verification.

    python3 codes/verification/scripts/run_scheduling_checks.py
    python3 codes/verification/scripts/run_controller_checks.py

The first script performs strict standalone design lint (no warning waivers)
for six N values and all four lane counts, plus counter lint. Its testbench uses
an independent nested-block pair oracle, checks every coefficient exactly once
per stage, runs both directions/all spans, applies request stalls and retirement
latency, exercises partial lanes and cancellation/fault recovery, and connects
the real refactored controller to the scheduler for complete and shorter
transforms. A backend handshake model acknowledges writes; it is not a memory
implementation and cannot prove real data was written or erased.

The second script reruns the existing controller/inverse-wrapper regression
with the new counter source dependency. Four pre-existing unused integration
inputs remain intentionally documented; they are not hidden with dummy logic.

See `RTL_REVIEW.md` and run `python3 codes/verification/scripts/run_integration_checks.py` for
the current integrated ECC, fault propagation and schedule-validation checks.
