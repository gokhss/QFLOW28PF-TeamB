# Final current-RTL regression — 2026-10-09

All existing test suites completed successfully on the current sources with
Verilator 5.038 and assertions enabled. This is a control/component regression,
not complete NTT/INTT datapath verification. No RTL or testbench was modified.
Before/after SHA-256 values match for all nine RTL files and four testbenches.

| Check | Result | Scope |
|---|---|---|
| Controller / inverse wrapper | PASS | 15 simulation configurations; 30 lint/elaboration configurations |
| Stage counter / butterfly scheduler | PASS | 24 simulation configurations; 30 strict lint configurations |
| Fixed ntt_control integration | PASS | 24 simulation configurations; 24 lint configurations; modeled backend |
| Submitted standalone blocks | PASS | Four strict module lint checks; 16 normal stages, eight abort cases, three active resets, four ECC values |
| Control RTL filelist | PASS with existing warnings | Current four-module hierarchy elaborates |
| Integration testbench filelist | PASS with existing warnings | Current nested filelist and testbench elaborate |

The scheduler/integration matrices cover N=2/4/8/256/512/1024 and LANES=1/2/4/8.
Controller tests cover all lane counts at N=256/512/1024 plus three small builds.
The 63 parameterized simulation instances contain multiple directed tests each;
they are not a measure of exhaustive state-space coverage.

Exercised cases include forward/inverse control, mode/config capture, full and
shortened schedules, first/last stages, pair coverage, backpressure, delayed
retirement, busy and completion, busy starts, back-to-back operations, reset,
abort, zeroize/completion races, illegal-state recovery, invalid configuration,
ECC qualification, datapath/scheduler faults, error retention and scrub interlocks.
Standalone tests additionally check qf scheduler address/write timing, twiddle
ROM tag association, C2B backpressure, all ECC values and response invalidation.

## Current RTL cross-check

- Nine unique design module declarations; verification source map covers those
  same nine files. No duplicate EDITED source remains.
- Fixed hierarchy remains ntt_control -> ntt_controller -> stage_counter, plus
  ntt_control -> butterfly_scheduler. No qf_ntt_scheduler was inserted.
- qf_ntt_c2b_if and the fatal-response test both use 16'h8002. Both fatal ECC
  inputs 10 and 11 are checked. The reset-readiness fix remains present.
- qf_ntt_scheduler, twiddle blocks and C2B remain standalone relative to
  ntt_control; their unit tests are not a complete physical backend connection.

## Remaining diagnostics

Strict standalone scheduler/counter and qf module lint completed without warning
waivers. Fixed control lint retains four unused legacy inputs. The existing
unwaived-copy audit exposes two empty output connections. Testbench builds retain
DECLFILENAME, PINMISSING, PROCASSINIT, UNUSEDSIGNAL and SYNCASYNCNET diagnostics as
applicable; the integration build also reports the existing UNOPTFLAT diagnostic
for scheduler_quiescent. These have not been suppressed or corrected in this
verification-only run. A simulation pass is not lint/ASIC signoff, and the
UNOPTFLAT report remains a review item. Exact per-suite warning counts are in
the machine-readable results.

## Commands and evidence

Executed from /home/gokhs/Documents/PQC:

```sh
python3 codes/verification/scripts/run_controller_checks.py
python3 codes/verification/scripts/run_scheduling_checks.py
python3 codes/verification/scripts/run_submitted_checks.py
python3 codes/verification/scripts/run_integration_checks.py
verilator --lint-only --sv -Wall -Wno-fatal --top-module ntt_control -F codes/filelists/ntt_control.f
verilator --lint-only --timing --assert --timescale 1ns/1ps -Wall -Wno-fatal --top-module ntt_control_tb -F codes/filelists/ntt_control_tb.f
```

Raw runner/filelist logs:
`codes/verification/logs/final_rtl_20261009T162910Z/`.
Machine-readable exit codes, individual passing cases, build directories,
warning counts and before/after source hashes:
`codes/verification/results/final_rtl_20261009T162910Z.json`.

## Verification limit

The arithmetic datapath, coefficient memory, production twiddle images and
complete backend latency/retirement/zeroization specification are still missing.
Actual NTT/INTT arithmetic, algorithm KATs, final Fabric error aggregation,
physical scrubbing, ASIC timing/PPA and side-channel properties are not verified.
The full crypto datapath is therefore NOT marked PASS.
