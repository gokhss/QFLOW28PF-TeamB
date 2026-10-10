# Submitted fixed architecture — independent verification review

Full NTT/INTT integration: **NOT VERIFIED / unresolved inputs**.

The user confirmed that no arithmetic datapath or fixed datapath latency
specification is supplied, and that qf_ntt_scheduler is a standalone block,
not a child of ntt_control. No connection between the two schedulers has been
invented. No controller, scheduler, twiddle formula, or architectural hierarchy
has been replaced. The only design RTL change is the local C2B reset handshake
correction described below.

## Authority and actual source inventory

Inspected all nine current .sv design files, existing tests/design notes,
CODE1 (historical reference), and every entry in codes.zip. The archive contains
the previous control baseline only; it has no extra datapath, coefficient RAM,
ROM image, or integration spec. All files originating in the archive remain
byte-for-byte unchanged after this work; see verification/results/submitted_review/results.json.

References checked: Team-B Contract v0.2 YAML, Team-B engineering PDF,
Common Signals v0.8 CSV, Common Register Map v1.0 PDF/CSV, and assignment DOCX.
The fixed shared-core architecture is preserved. Lane selection and reduction
method remain EXPERIMENT items; N=256/single-lane in the standalone qf scheduler
is its submitted isolated-test scope, not a new project-wide freeze.

Exact current synthesizable hierarchy (not a complete crypto engine):

    codes/rtl/ntt/control/ntt_control.sv : ntt_control
      u_controller : ntt_controller       codes/rtl/ntt/control/ntt_controller.sv
        u_stage_counter : stage_counter  codes/rtl/ntt/control/stage_counter.sv
      u_scheduler : butterfly_scheduler   codes/rtl/ntt/scheduler/butterfly_scheduler.sv

Separate alternative entry, not instantiated in the fixed hierarchy:

    codes/rtl/ntt/control/intt_controller.sv : intt_controller
      u_shared_controller : ntt_controller
        u_stage_counter : stage_counter

Separate supplied standalone modules, not connected to ntt_control:

    codes/rtl/ntt/scheduler/qf_ntt_scheduler.sv        : qf_ntt_scheduler
    codes/rtl/ntt/control/qf_ntt_twiddle_addr_gen.sv : qf_ntt_twiddle_addr_gen
    codes/rtl/ntt/memory/qf_ntt_twiddle_mem.sv      : qf_ntt_twiddle_mem
    codes/rtl/ntt/interface/qf_ntt_c2b_if.sv           : qf_ntt_c2b_if

`codes/filelists/ntt_control.f` retains the same source hierarchy; paths were updated
during directory reorganization (use Verilator `-F`). CODE1 must not be compiled as a second
ntt_controller definition. No final integrated RTL top can be supplied without
inventing the missing backend. Current files remain the actual submitted RTL,
with the one tested fix, not a substitute architecture.

## Real interfaces and alignment findings

| Block/path | Actual ports/protocol | Verified locally / unresolved |
|---|---|---|
| ntt_control command | clk/rst_n, start/enable/intt_mode, cfg_last_stage/first_span/descending, ready/busy/done | Existing configuration capture, full busy and completion regressions rerun |
| ntt_control backend | batch_valid/ready, lane_valid, pair addresses, ordinal, stage/span/mode; batch_retired | One outstanding atomic batch; retirement requires real writes; test backend only |
| ntt_control cancellation/status | abort_req, zeroize, ecc_uncorrectable, datapath_fault; scrub_done/backend_flushed; five named error outputs | Local cancellation, fault priority and scrub interlocks tested; real scrub hardware absent |
| qf_ntt_scheduler command | stage_start, butterfly_enable, transform_intt, stage_count[2:0], abort_i | Independent full-stage issue engine; no batch input, no read-ready, no datapath-result-valid |
| qf scheduler reads | rd_en, rd_addr_u/v[7:0], bf_index[6:0] | N=256, 128 distinct pairs/stage; forward distance=2^stage, inverse distance=2^(7-stage) |
| qf scheduler writes | wr_en, wr_addr_u/v[7:0], butterfly_done | Fixed two-entry valid/address pipeline; butterfly_done equals wr_en, not observed arithmetic completion |
| qf stage completion | stage_done, scheduler_busy | Last scheduled write edge, suppressed by abort; no actual memory-write acknowledgement exists |
| Twiddle address | transform_intt, stage_count[2:0], bf_index[6:0] -> twiddle_addr[7:0] | Combinational submitted formulas exercised; mode/stage are live inputs, not captured here |
| Twiddle memory | rd_en, rd_addr -> rd_data, rd_valid; DATA_WIDTH/ADDR_WIDTH/DEPTH/ROM_INIT parameters | Synchronous one-cycle read, hold data on disabled read; default image all zero |
| C2B request | req_valid/ready, context[4:0], region[1:0], abort_i | One pending request; metadata held during backpressure; readiness fixed during reset |
| C2B boundary | b2c_valid/context/region; c2b_ready/data[31:0]/ecc_status[1:0]/completion | No coefficient address, write-enable or write-data ports; cannot act as a coefficient RAM by direct wiring |
| C2B response | rsp_valid/data/completion, ecc_correctable/fatal, error_code[15:0] | Registered response on accepted boundary beat; fatal invalidates data/completion; not transform completion |

A read command sampled at edge k enters qf scheduler pipeline slot 0. Twiddle
ROM data/valid for that command are visible after edge k. At edge k+1 the
scheduler address/valid enters slot 1, exposing wr_en for the subsequent
write-consumption edge k+2. The testbench checks edge-sampled write association
against a two-edge history and ROM association against a one-edge history.
This establishes the supplied control timing only. It does not establish when
an absent coefficient memory or arithmetic unit produces a valid result.

The standalone twiddle formulas were checked over every stage/butterfly in
both directions. The test ROM contains address tags to detect alignment errors,
not cryptographic twiddles. No polynomial transform correctness or compatibility
of those formulas with an absent datapath/coefficient representation is claimed.
No production constants, inverse normalization, or KAT reference results exist
in the uploaded RTL.

The C2B implementation assumes response data/ECC and any completion are valid
on the same edge as b2c_valid && c2b_ready. It clears pending on that beat and
ignores later unsolicited completion. The Common Signals row describes ready
as access acceptance; a separate response-latency protocol is NOT DEFINED BY
PROVIDED PROJECT DOCUMENTS. This assumption must be resolved with Team C before
system integration; no speculative transaction FSM was added.

## Abort, zeroize, ECC and status limitations

- Existing ntt_control cancel/zeroize and named-error tests still succeed using
  a backend acknowledgement model. This is not proof of actual state erasure.
- qf scheduler samples abort_i synchronously: a read on that sampling edge may
  enter the pipeline; later reads stop, committed write descriptors drain, and
  stage_done is suppressed, including abort coincident with the final write.
  It has no zeroize port or scrub engine. No new zeroize wiring was invented.
- C2B abort cancels pending activity; it does not clear retained rsp_data or
  context/region registers. Actual zeroization of this storage is unresolved.
- ecc_fatal is registered after the fatal C2B beat. A future integration must
  reconcile that event latency with the fixed control's same-edge completion
  invalidation requirement. Merely wiring the registered event cannot establish
  fault precedence on an earlier completion edge. No invented bypass was added.
- Baseline correction confirmed by the user on 2026-10-09: C2B error_code
  emits 0x8002 for fatal ECC, matching the supplied EDITED RTL and Team-B class
  0x8. The active RTL retains its previously tested reset-readiness fix, which
  the edited copy lacked. The fatal-ECC test expectation now uses 0x8002.
  The older Register Map still lists 0x9002; that source artifact has not been
  rewritten. This local correction does not implement final Fabric aggregation.
  Also, C2B comments call ECC 11 reserved, while Common Signals describes
  independent flags; the implementation treats it fatal either way. No new
  encoding meaning was assigned.
- Legacy ntt_controller error_code remains zero and is disconnected in the fixed
  ntt_control. Named errors are exported instead. Final Fabric error/done
  aggregation, context policy, command/profile checking and bus ownership are
  absent, not certified by these tests.

## Reproduced RTL error and exact correction

`qf_ntt_c2b_if.sv`, request admission:

    before: assign req_ready = !pending_q && !abort_i;
    after:  assign req_ready = rst_n && !pending_q && !abort_i;

**FUNCTIONAL CORRECTION:** reset forces pending_q low, so the original expression
advertised readiness while the reset branch discarded incoming requests. The
new expression prevents that false handshake. No ports, widths, queue depth,
normal transfer timing, ECC encoding or abort behavior changed. This is a
local reset fix, not an architecture change.

The new test reproduced the failure before editing RTL. The failing output is
retained in `verification/logs/submitted_review/reset_failure_before_fix.log` and
the exact design diff in `codes/docs/verification_history/rtl_change.diff`. The same check succeeds afterward.

## Executed verification — explicitly limited scope

Verilator version: 5.038. Detailed logs are copied under
`codes/verification/logs/submitted_review/`; summary and SHA-256 file hashes are in
`codes/verification/results/submitted_review/results.json`.

| Verification | Observed result | Scope |
|---|---|---|
| Existing controller/wrapper regression | 15 simulation configurations completed, assertions enabled | Local controllers, not full crypto engine |
| Existing scheduler/counter regression | 24 simulation configurations completed | N=2/4/8/256/512/1024, LANES=1/2/4/8 |
| Existing ntt_control integration regression | 24 simulation configurations completed | Existing batch backend model, including ECC/fault races |
| Existing lint/elaboration matrices | 30 controller, 30 scheduler/counter, 24 internal-top checks completed | Baseline warnings described below |
| Four supplied qf_* modules | Strict -Wall standalone lint/elaboration completed without warnings | Actual submitted RTL ports |
| New component testbench | Completed without assertion failures after reset fix | 16 full stages, 8 aborted stages, 3 active resets, all four ECC values |
| Full datapath/coefficient-memory integration | NOT RUN / NOT VERIFIED | Required RTL/protocol missing |
| Algorithm KATs / synthesis PPA / formal / gate-level | NOT RUN | Not implied by component simulation |

New checks cover independent pair-address oracle and coefficient coverage,
write-address latency, ROM data/address association, enable pauses with draining
writes, stage completion count, abort on first/middle/final-write positions,
reset with outstanding metadata, C2B backpressure and captured metadata,
correctable/fatal ECC, response invalidation, one-cycle events, abort beating
response, and ignoring unsolicited completion. SVA checks abort suppression of
stage_done, fatal suppression of response success, and stalled C2B metadata
stability. Reset release/CDC and four-state/X behavior require further tools.

No warnings were newly suppressed. The four qf_* standalone lint invocations
use fatal warnings. The new testbench build reports one SYNCASYNCNET diagnostic:
its edge-sampled scoreboard observes rst_n, also used asynchronously by RTL.
The warning remains visible in the build log. Existing regression testbenches
have their original warnings and original policies, with full logs retained.

To expose rather than conceal the fixed control's existing inline waiver, the
new runner makes temporary copies, removes only lint pragma comments, and lints
those copies with all diagnostics visible. The fixed sources are untouched.
The audit reports six warnings: two PINCONNECTEMPTY outputs (b2a_error_code,
transform_done), and four UNUSEDSIGNAL inputs (a2b_cmd_opcode, a2b_profile_id,
a2b_context_id, butterfly_done). This is **not warning-free lint**; no dummy
logic or interface deletion was used to remove the diagnostics.

Reproduce from the workspace root:

    python3 codes/verification/scripts/run_controller_checks.py
    python3 codes/verification/scripts/run_scheduling_checks.py
    python3 codes/verification/scripts/run_integration_checks.py
    python3 codes/verification/scripts/run_submitted_checks.py

`submitted_blocks_tb` is verification only. It connects the standalone scheduler
address stream to the twiddle generator/ROM to check their local association;
it neither connects the two schedulers nor declares a production subsystem top.
The C2B unit is independently stimulated. No arithmetic stub pretends to be
uploaded hardware.

## Inputs required before complete integration can be claimed

1. Actual arithmetic datapath RTL and real operand/result, mode, fault, flush
   and zeroize ports; supported latency/throughput and backpressure rules.
2. Submitted integration specification beneath the unchanged ntt_control batch
   interface: actual coefficient storage/read/write path and retirement owner.
   qf_ntt_scheduler remains independent unless an authoritative connection is
   subsequently supplied; none is assumed here.
3. Approved twiddle images, profile-to-schedule/representation mapping, inverse
   normalization placement, and independent reference/KAT expectations.
4. Team-C data/ECC/completion timing and storage-zeroization contract, including
   how retained interface data and late responses are invalidated.
5. Final Fabric error namespace/status aggregation and fault/completion timing.

Until those are supplied, component success must not be reported as complete
fixed-architecture NTT/INTT verification.
