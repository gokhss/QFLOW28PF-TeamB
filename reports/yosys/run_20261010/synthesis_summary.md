# Q-FLOW28PF controller synthesis and baseline review — 2026-10-10

## Source baseline and exact changes

Repository: `/home/gokhs/QFLOW28PF-TeamB`; initial Git status was clean.
HEAD: `d3b4968aa7b35f52926cceed645a946caec31f3b`.
Previous integration baseline: `5501d63eeb7a7970837b6bb78f910eca7976639d`.
The requested declaration is already corrected in HEAD at
`rtl/ntt/interface/qf_ntt_c2b_if.sv:76`:

```diff
-localparam logic [15:0] ERR_ECC_UNCORRECTABLE = 16'h9002;
+localparam logic [15:0] ERR_ECC_UNCORRECTABLE = 16'h8002;
```

This is the historical change, NOT a new edit made during this run. That commit
also updates two matching comments and removes an empty datapath `.gitkeep`.
All controller/scheduler RTL matches the previous integration baseline. No
rollback was necessary or safe to justify. No RTL was edited; SHA256 matches
for all nine source files before/after are in `source_integrity.json`.
`final_rtl.diff` is empty. No teammate files, Git remotes, or commits changed.

The only tracked working-tree change is `tb/ntt/submitted_blocks_tb.sv:161`:
its stale expected ECC response changes from `16'h9002` to `16'h8002`.
`test_expectation.diff` contains the exact diff. This aligns the assertion with
the existing verified RTL and user's specified correction; it does not alter
stimulus, RTL, protocol, reset behavior, or any other expectation.

## Scope and hierarchy

```text
ntt_control                  rtl/ntt/control/ntt_control.sv
├── u_controller: ntt_controller
│   └── stage_counter
└── u_scheduler: butterfly_scheduler
```

`intt_controller` is tested as an alternative convenience wrapper, not
instantiated alongside the shared runtime-mode control in this synthesis top.
`qf_ntt_scheduler`, `qf_ntt_c2b_if`, `qf_ntt_twiddle_addr_gen`, and
`qf_ntt_twiddle_mem` remain standalone and are excluded from these resource
counts. No connection between the two schedulers was invented.
The arithmetic datapath and coefficient-memory backend are absent. There is
no numerical NTT validation, full accelerator synthesis, or full integration PASS.

## Tools and reproducibility

Existing `/usr/bin/yosys` is 0.9 and fails parsing the unchanged parameter
syntax in `stage_counter.sv`; see `old_yosys_parse.log`. No RTL parser workaround
was made. Existing Verilator is `/usr/local/bin/verilator`, version 5.038.
OSS CAD Suite 2026-10-09 was downloaded from its official release after checking
disk space, verified by SHA256, and extracted in isolation under
`/tmp/qflow-tools-20261009/oss-cad-suite`. Existing tools and PATH were not changed.
The synthesis executable is explicitly that suite's `bin/yosys`, version
0.69+272, git 230fb23f8; frontend is its `slang` plugin. Bundled standalone slang
reports 12.0.0+545f88b2e; plugin SHA256 identifies the exact frontend binary.
Tool paths, versions, digest, archive URL, library identity and disk space
are recorded in `tool_versions.txt`. The isolated `/tmp` installation is
**temporary**: preserve it at a durable path before OS cleanup, then update
`YOSYS` in the driver and command paths. No default tool was overwritten.

From repository root, commands actually used were:

```sh
python3 /tmp/qflow_analysis.py audit
python3 /tmp/qflow_analysis.py tests
python3 /tmp/qflow_analysis.py ecc_test
python3 /tmp/qflow_analysis.py activity
python3 /tmp/qflow_analysis.py synth_default
python3 /tmp/qflow_analysis.py sweep
python3 /tmp/qflow_analysis.py physical
python3 /tmp/qflow_analysis.py finish
python3 /tmp/qflow_analysis.py timing_audit
python3 /tmp/qflow_analysis.py polish
```

`analysis_driver.py` is a saved copy of this driver. Use its `tests`, `activity`,
`sweep`, and `physical` actions to reproduce results with the recorded paths.
Do not rerun `ecc_test`: it deliberately requires the old expectation and was a
one-time correction. Do not rerun `audit` over the original audit evidence.
Each `N*_L*/synthesis.ys` and `sta_power.tcl` is directly executable:

```sh
/tmp/qflow-tools-20261009/oss-cad-suite/bin/yosys -m slang -s reports/yosys/run_20261010/N256_L1/synthesis.ys
/labroot/openroad/install/OpenROAD/bin/openroad -exit reports/yosys/run_20261010/N256_L1/sta_power.tcl
```

Flow: `read_slang --top ntt_control -G N=... -G LANES=...`, hierarchy check,
process lowering, flatten/optimize, structural check and zero-SCC check;
then generic `synth`, structural check, generic statistics/netlist. A saved
word-level design is separately mapped with `synth -noabc`, `dfflibmap` and
`abc -liberty` using the same Nangate45 typical library for every configuration.
Structural checks and SCC checks are repeated after mapping. No synthesis
option or parameter was adjusted to improve one result. Mapping is area-driven
with default ABC settings, not constrained timing optimization.

## Verification results

| Test/check | Result | Actual scope |
|---|---|---|
| controller_tb | PASS | Existing 15 configurations, controllers/wrapper, assertions |
| scheduling_tb | PASS | Existing 24 configurations and control integration checks |
| ntt_control_tb | PASS | Existing 24 configurations and modeled-backend cases |
| submitted_blocks_tb, initial | FAIL | Stale expected 9002 disagreed with correct 8002 RTL |
| submitted_blocks_tb, corrected expectation | PASS | Existing standalone scheduler/twiddle/C2B component checks |
| Activity wrapper | PASS | Reuses four N=256 test cases, records cycles/VCD |
| Verilator top lint/elaboration | Completed with warnings | See ntt_control_lint.log; not warning-free |
| Modern parsing/hierarchy/generic synthesis | PASS | All 24 configurations |
| Mapped synthesis and structural/SCC checks | PASS | All 24 configurations |
| STA/reference power execution | Completed | Pre-layout estimates with limitations/violations below |
| Formal equivalence/properties | NOT RUN | No formal proof claimed |
| Numerical NTT/full backend integration | NOT VERIFIED | Required datapath/backend missing |

All simulation builds use Verilator `--timing --assert --timescale 1ns/1ps
-Wall -Wno-fatal`. `-Wno-fatal` permits execution while retaining all warnings;
no new category suppressions were added. Existing inline RTL/TB waivers remain
unchanged. Exact per-test compiler argument arrays are in `test_results.json`.
The initial standalone failure and corrected run logs are both preserved.
Assertions include done implies busy, zeroize/abort/fault suppressing launch
and successful completion, lane mask only during batch-valid, and stage bounds.
Integration tests exercise both modes, captured configuration, modeled delayed
write retirement, back-to-back commands, ECC ownership and fatal handling,
zeroize/abort, completion races, scheduler faults and illegal-state recovery.
These are directed simulations, not exhaustive proofs or arithmetic tests.

## Supported configurations and resource counts

All 24 combinations of N={2,4,8,256,512,1024} and LANES={1,2,4,8} are legal per
current source and existing scheduling/integration tests. N must be a power of
two >=2 and LANES one of the listed powers. Excess lanes for N/2<LANES are masked;
they do not perform additional work. Other parameter values were not synthesized.
Counts below are for top `ntt_control` only. Generic cells and mapped cells are
different representations, not interchangeable area units. Register counts are
post-generic-synthesis one-bit flip-flop cells, not the number of RTL declarations.
JSON/CSV also give combinational cells, generic muxes, word-level add/subtract/
comparison/mux operations, memory resources, relative area/register/power changes,
and modeled cycle counts. Word-level operations are not final gate counts.
All configurations infer zero memories. No multiplier, butterfly or reduction
hardware is included.

| Configuration | N | LANES | Generic cells | FF bits | Mapped cells | Nangate45 area (um2) | Setup slack (ns) | Total power (uW) | Limitations |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| ntt_control_N2_L1 | 2 | 1 | 218 | 25 | 163 | 265.734 | 9.28727 | unavailable | control only; cap violations=0 |
| ntt_control_N2_L2 | 2 | 2 | 219 | 25 | 157 | 262.542 | 9.21179 | unavailable | control only; cap violations=0 |
| ntt_control_N2_L4 | 2 | 4 | 219 | 25 | 157 | 262.542 | 9.21179 | unavailable | control only; cap violations=0 |
| ntt_control_N2_L8 | 2 | 8 | 219 | 25 | 157 | 262.542 | 9.21179 | unavailable | control only; cap violations=0 |
| ntt_control_N4_L1 | 4 | 1 | 228 | 26 | 182 | 292.600 | 9.10604 | unavailable | control only; cap violations=1 |
| ntt_control_N4_L2 | 4 | 2 | 232 | 26 | 178 | 285.418 | 9.22230 | unavailable | control only; cap violations=0 |
| ntt_control_N4_L4 | 4 | 4 | 225 | 26 | 179 | 284.354 | 9.29322 | unavailable | control only; cap violations=0 |
| ntt_control_N4_L8 | 4 | 8 | 225 | 26 | 179 | 284.354 | 9.29322 | unavailable | control only; cap violations=0 |
| ntt_control_N8_L1 | 8 | 1 | 314 | 32 | 230 | 364.686 | 9.24895 | unavailable | control only; cap violations=0 |
| ntt_control_N8_L2 | 8 | 2 | 303 | 31 | 220 | 354.844 | 9.04277 | unavailable | control only; cap violations=1 |
| ntt_control_N8_L4 | 8 | 4 | 304 | 31 | 225 | 353.248 | 9.12268 | unavailable | control only; cap violations=1 |
| ntt_control_N8_L8 | 8 | 8 | 300 | 31 | 225 | 357.238 | 9.05503 | unavailable | control only; cap violations=0 |
| ntt_control_N256_L1 | 256 | 1 | 398 | 42 | 314 | 495.824 | 8.92766 | 51.226 | control only; cap violations=1 |
| ntt_control_N256_L2 | 256 | 2 | 386 | 41 | 300 | 480.662 | 8.98466 | 54.397 | control only; cap violations=1 |
| ntt_control_N256_L4 | 256 | 4 | 378 | 40 | 298 | 473.480 | 9.10980 | 48.437 | control only; cap violations=0 |
| ntt_control_N256_L8 | 256 | 8 | 375 | 39 | 303 | 469.224 | 8.93117 | 41.198 | control only; cap violations=2 |
| ntt_control_N512_L1 | 512 | 1 | 495 | 48 | 376 | 581.742 | 8.75597 | unavailable | control only; cap violations=1 |
| ntt_control_N512_L2 | 512 | 2 | 485 | 47 | 376 | 576.954 | 8.88943 | unavailable | control only; cap violations=1 |
| ntt_control_N512_L4 | 512 | 4 | 478 | 46 | 407 | 605.948 | 9.03417 | unavailable | control only; cap violations=0 |
| ntt_control_N512_L8 | 512 | 8 | 472 | 45 | 385 | 574.028 | 8.86257 | unavailable | control only; cap violations=2 |
| ntt_control_N1024_L1 | 1024 | 1 | 502 | 49 | 406 | 620.844 | 9.00633 | unavailable | control only; cap violations=0 |
| ntt_control_N1024_L2 | 1024 | 2 | 499 | 48 | 394 | 599.298 | 9.02708 | unavailable | control only; cap violations=0 |
| ntt_control_N1024_L4 | 1024 | 4 | 491 | 47 | 394 | 596.106 | 8.76478 | unavailable | control only; cap violations=2 |
| ntt_control_N1024_L8 | 1024 | 8 | 486 | 46 | 398 | 599.032 | 9.04320 | unavailable | control only; cap violations=0 |

## Area, timing and power limitations

Area is the sum of mapped cell areas from the existing
`/labroot/openroad/OpenROAD/test/Nangate45/Nangate45_typ.lib` (matching LEF
geometries; um2). It is a 45 nm reference library at 1.10 V, 25 C, **not TSMC28**.
It excludes placement whitespace, routing, clock tree, fillers and physical
implementation overhead. It cannot establish target chip area.

OpenROAD's bundled OpenSTA was used with the matching technology and cell LEFs.
The first attempt failed to link because the technology LEF had not been loaded;
those setup-failure logs are preserved as `sta_power_initial_no_lef.log`.
The corrected flow loads both LEFs and completed all 24 runs. Binary version
reports `bazel-nostamp`; its digest is recorded rather than inventing a release.

Timing assumptions: ideal 100 MHz clock (10 ns), zero input/output delays,
50 ps input transition and 1 fF per output; no placed/routed parasitics or clock
uncertainty. Reset is false-pathed and intentionally lacks an input arrival
constraint, generating the reported one-input-delay warning. Verbose diagnostics in N256_L1/sta_diagnostics.log confirm this port is rst_n. Positive setup
slack does not establish timing closure: some net loads exceed library maximum
capacitance. Counts are in the table; paths/violations are retained in each log.
The derived `effective_critical_budget_ns=10-slack` includes setup/check effects;
it is not a measured standalone gate delay or signoff Fmax. Hold, recovery,
removal, clock-tree and multi-corner signoff were not established.

Power uses library internal/leakage data and OpenSTA `read_vcd` from the existing
RTL test case's first normal forward and inverse operations, at the same 100 MHz
clock. The activity wrapper observes rather than changes RTL. Per-instance scope
and end-time are explicit in each Tcl; VCD time units are 1 ps. Windows include
reset/start and the two normal operations, ending before subsequent fault tests.
No separate forward/inverse average is claimed. Known matching RTL signal names
are annotated into the mapped design; other internal gate activities are
propagated/estimated by OpenSTA. Unannotated primary input activity is set to zero.
Annotated pin counts and the saved VCD make coverage visible; this is not
full gate-level waveform annotation or glitch-accurate power. No SAIF was needed.
Only the four N=256 cases have workload-based power reports. Total power is
internal+switching+leakage; dynamic is internal+switching. The ideal clock tree has
no mapped clock buffers, so clock-distribution power is absent. Capacitance
violations, no routing parasitics and activity propagation limit accuracy.
These are **reference-library estimates**, not silicon measurements, TSMC28
estimates, or full accelerator power. Other configurations have no power estimate.

## N=256 power and relative comparison detail

All power values are reference estimates in uW; dynamic includes internal and switching. Relative changes use LANES=1 at fixed N. These do not include a datapath or memory backend.

| LANES | Dynamic uW | Leakage uW | Total uW | Area change | FF change | Power change | Cycles (each direction) | Annotated pins |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 41.145 | 10.082 | 51.226 | 0.00% | 0.00% | 0.00% | 4122 | 71 |
| 2 | 44.326 | 10.071 | 54.397 | -3.06% | -2.38% | 6.19% | 2074 | 96 |
| 4 | 38.878 | 9.559 | 48.437 | -4.51% | -4.76% | -5.45% | 1050 | 144 |
| 8 | 31.853 | 9.345 | 41.198 | -5.36% | -7.14% | -19.58% | 538 | 240 |

## UNOPTFLAT and remaining warnings

Verilator reports the path scheduler_quiescent -> controller output decode ->
stage_start -> scheduler fault_event -> scheduler_quiescent. In
`ntt_controller.sv`, ntt_enable affects b2a_ready in S_IDLE; stage_start depends
only on S_STAGE_START and cancel. They share one always_comb process, which
creates the coarse process dependency seen by Verilator. Ready/start acceptance
feeds next state through a register, not directly back into stage_start.
Scheduler fault is registered before entering the controller cancellation path.
Source inspection plus `scc -expect 0` at word-level, generic and library-mapped
levels for every one of the 24 configurations finds no combinational SCC.
This is a process-dependency warning for the tested configurations, not evidence
of an actual synthesized combinational loop. No RTL rewrite or warning suppression
was made. An optional future cleanup could split independent decode equations,
but it is outside the one-constant request and needs separate review/equivalence.

Unused legacy controller inputs are a2b_cmd_opcode, a2b_profile_id,
a2b_context_id and butterfly_done; metadata belongs at the fabric boundary.
Keep these existing ports. Other warning classes and every actual warning are
recorded in `warnings.json`: TB filename/helper-module mismatch, declaration
initialization, unused observations, reset/force-related sync/async analysis and
UNOPTFLAT where reported. The source and all warning messages are preserved.

## Trade-off interpretation and next step

At N=256 the existing modeled-backend test takes 4122/2074/1050/538 cycles for
LANES=1/2/4/8 respectively, for both directions (accepted command to observed
done). These are measured **control/test-model** cycles, not arithmetic latency.
Extra lanes reduce batch-counter width; their arithmetic and memory costs are
absent, so the controller can become smaller with more lanes. Do not choose an
accelerator lane count based on these controller-only estimates. The CSV gives
relative changes against LANES=1 at fixed N; no comparisons mix tools or flows.

Next: obtain the actual arithmetic/coeff-memory backend and its fixed timing,
retirement, ECC ownership and flush/scrub contract. Keep profile/twiddle values
and algorithm-specific mathematical validation open until supplied. Obtain the
licensed TSMC28 Liberty/LEF/PVT and timing/activity constraints for target PPA,
then repeat mapping, load repair, placement/STA and workload power on the complete
agreed hierarchy. No invented datapath or scheduler bridge is present here.

Generated build/object caches are ignored through this report folder's
.gitignore. Existing repository rules already ignore *.log and *.vcd; these
files remain on disk but are not automatically Git-staged. Reports, scripts,
JSON/CSV and netlists are retained. No commits or pushes were made.
