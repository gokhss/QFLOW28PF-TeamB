# Directory reorganization audit

This change moves files and updates path/build plumbing only. It preserves the
fixed `ntt_control` hierarchy, every RTL module/port/parameter and all testbench
contents. No missing arithmetic datapath or coefficient memory was invented.
`qf_ntt_scheduler` remains separate; `butterfly_scheduler` remains the scheduler
instantiated by `ntt_control`.

## Inventory before moving

484 files were inventoried with role, size and SHA-256:

| Role | Files | Disposition |
|---|---:|---|
| Current RTL | 9 | Moved by actual responsibility; bytes unchanged |
| Testbenches | 4 | Moved to tb/ntt; bytes unchanged |
| Python runners | 4 | Moved to verification/scripts; source/build paths updated |
| Design/review documentation | 4 | Moved to docs; maintained path references updated |
| Control filelist | 1 | Moved to filelists; same RTL membership, filelist-relative paths |
| CODE1 | 1 | Preserved under docs/legacy; historical duplicate module name, not compiled |
| Existing verification evidence | 100 | All retained; logs/results separated, historical diff under docs |
| Existing generated build files | 361 | Left in build unchanged; excluded from Git |

The complete inventory is [inventory_before.json](reorganization/inventory_before.json).
Exact-content duplicate groups are recorded in
[duplicates.json](reorganization/duplicates.json); none was automatically removed.
CODE1 is useful historical material even though its module name overlaps the
current controller. Existing generated build trees are retained as historical
local outputs; their embedded old source paths are not rewritten or reused as
verification evidence for the relocated source.

The parent project PDFs, YAML, CSV, DOCX and codes.zip were outside the requested
codes/ reorganization and remain untouched. The ZIP is a historical snapshot,
not another active source tree.

## Every moved file

123 files moved. The individual old/new path and role of each is listed in
[moves.tsv](reorganization/moves.tsv). [moves.json](reorganization/moves.json)
also includes every unchanged original path, for a complete preservation audit.

| Original file | Final path, relative to codes/ |
|---|---|
| ntt_control.sv | rtl/ntt/control/ntt_control.sv |
| ntt_controller.sv | rtl/ntt/control/ntt_controller.sv |
| intt_controller.sv | rtl/ntt/control/intt_controller.sv |
| stage_counter.sv | rtl/ntt/control/stage_counter.sv |
| butterfly_scheduler.sv | rtl/ntt/scheduler/butterfly_scheduler.sv |
| qf_ntt_scheduler.sv | rtl/ntt/scheduler/qf_ntt_scheduler.sv |
| qf_ntt_twiddle_addr_gen.sv | rtl/ntt/control/qf_ntt_twiddle_addr_gen.sv |
| qf_ntt_twiddle_mem.sv | rtl/ntt/memory/qf_ntt_twiddle_mem.sv |
| qf_ntt_c2b_if.sv | rtl/ntt/interface/qf_ntt_c2b_if.sv |
| tests/controller_tb.sv | tb/ntt/controller_tb.sv |
| tests/ntt_control_tb.sv | tb/ntt/ntt_control_tb.sv |
| tests/scheduling_tb.sv | tb/ntt/scheduling_tb.sv |
| tests/submitted_blocks_tb.sv | tb/ntt/submitted_blocks_tb.sv |
| tests/run_controller_checks.py | verification/scripts/run_controller_checks.py |
| tests/run_integration_checks.py | verification/scripts/run_integration_checks.py |
| tests/run_scheduling_checks.py | verification/scripts/run_scheduling_checks.py |
| tests/run_submitted_checks.py | verification/scripts/run_submitted_checks.py |
| CONTROLLER_DESIGN.md | docs/CONTROLLER_DESIGN.md |
| FIXED_INTEGRATION_REVIEW.md | docs/FIXED_INTEGRATION_REVIEW.md |
| RTL_REVIEW.md | docs/RTL_REVIEW.md |
| SCHEDULING_DESIGN.md | docs/SCHEDULING_DESIGN.md |
| CODE1 | docs/legacy/CODE1 |
| ntt_control.f | filelists/ntt_control.f |
| verification/submitted_review/**/*.log | verification/logs/submitted_review/ (same subtree; every file listed in ledger) |
| verification/submitted_review/results.json | verification/results/submitted_review/results.json |
| verification/submitted_review/rtl_change.diff | docs/verification_history/rtl_change.diff |

Twiddle address generation is control logic, so it is under control/, not the
empty arithmetic datapath directory. No coefficient memory module was supplied;
memory/ contains only the actual twiddle ROM interface.

## Paths, filelists and generated output

`verification/scripts/paths.py` centralizes source lookup and allocates isolated
run directories under codes/build/. Only filesystem lookup/output plumbing in
the four runners changed; parameter matrices, assertions, test algorithms,
compiler options and warning policies did not change. The Python runners work
independently of the caller's current directory.

- `filelists/ntt_control.f`: same four RTL modules as before, dependency ordered.
- `filelists/ntt_control_tb.f`: new list that includes the control filelist and
  the existing tb/ntt/ntt_control_tb.sv. No standalone scheduler is inserted.
- Invoke both with Verilator **-F**, so source and nested-list paths resolve
  relative to the containing filelist rather than the current working directory.

`.gitignore` excludes generated build trees, simulator executables/objects,
Verilator-generated C++/headers/make files, caches, waveforms, editor temporaries,
and local verification/logs and verification/results contents. The build/logs/
results directory placeholders remain trackable. Source RTL, testbenches,
filelists, documentation, scripts and golden/reference vectors are not ignored.

Ignore rules were checked using an isolated temporary Git repository, without
initializing or modifying the workspace's .git directory. See
[gitignore_check.json](reorganization/gitignore_check.json). Nothing was staged,
committed or deleted. The retained historical raw logs/results stay on disk but
are intentionally excluded from future Git additions; historical summaries and
the path/hash audit in docs remain trackable.

## Exact verification commands

Executed from /home/gokhs/Documents/PQC:

```sh
verilator --lint-only --sv -Wall -Wno-fatal --top-module ntt_control -F codes/filelists/ntt_control.f > codes/verification/logs/reorganization/control_filelist_lint.log 2>&1
verilator --lint-only --timing --assert --timescale 1ns/1ps -Wall -Wno-fatal --top-module ntt_control_tb -F codes/filelists/ntt_control_tb.f > codes/verification/logs/reorganization/control_tb_filelist_lint.log 2>&1
python3 codes/verification/scripts/run_controller_checks.py > codes/verification/logs/reorganization/controller.log 2>&1
python3 codes/verification/scripts/run_scheduling_checks.py > codes/verification/logs/reorganization/scheduling.log 2>&1
python3 codes/verification/scripts/run_submitted_checks.py > codes/verification/logs/reorganization/submitted.log 2>&1
python3 codes/verification/scripts/run_integration_checks.py > codes/verification/logs/reorganization/integration.log 2>&1
```

The first controller/scheduling/integration builds were interrupted when the
session paused. Their console logs are retained as *-interrupted.log and their
build trees are preserved. These are not counted as completed tests. The three
commands were restarted after resume. The standalone submitted-block run had
already completed and was not needlessly repeated.

## Results after restructuring

| Check | Result | Evidence |
|---|---|---|
| Control RTL filelist lint/elaboration | PASS with baseline warnings | Same four RTL modules; four unused legacy inputs |
| Control testbench filelist lint/elaboration | PASS with baseline testbench warnings | Nested -F paths resolve correctly |
| Controller regression | PASS | Same 15 cases and 30 lint configurations |
| Scheduler regression | PASS | Same 24 cases; 24 scheduler + 6 counter strict lint checks |
| Submitted/standalone regression | PASS, component scope only | 16 stages, 8 abort cases, 3 active resets, four ECC values; four strict module lint checks |
| ntt_control integration regression | PASS, modeled-backend scope only | Same 24 cases and 24 lint configurations |
| File preservation | PASS | All 484 original files remain; 123 moved, none deleted |
| RTL/testbench byte identity | PASS | All nine RTL and four testbench SHA-256 values unchanged |
| Existing historical evidence/build preservation | PASS | Every original evidence and build file byte-identical |
| Git ignore audit | PASS | Source/reference candidates retained, generated outputs ignored |

Verification used Verilator 5.038. Exact case lists for the three parameterized
suites were compared with the preserved pre-move simulation logs and matched.
The only nine original files with changed bytes are four documentation files,
four Python runners and the filelist; changes are limited to paths/build
plumbing. All other 475 original files are byte-identical.

Remaining diagnostics were not newly suppressed: four unused legacy controller
inputs; two empty outputs exposed by the existing unwaived temporary-copy audit;
and existing testbench diagnostics. Testbench build categories observed:
`DECLFILENAME`, `PINMISSING`, `PROCASSINIT`, `SYNCASYNCNET`, `UNOPTFLAT`, `UNUSEDSIGNAL`.
The submitted testbench reports SYNCASYNCNET because its scoreboard samples the
same reset net used asynchronously by RTL. File-by-file warning counts and exact
new build directories are recorded in
[verification_summary.json](reorganization/verification_summary.json). Raw logs
are retained under verification/logs/reorganization and the printed build paths.
All four simulation-build warning category/count sets match the preserved
pre-move logs. The existing integration-test build includes one UNOPTFLAT
diagnostic for scheduler_quiescent; it is recorded, not suppressed or changed.
The standalone control RTL lint reports only its four documented unused inputs.
There are no newly introduced RTL diagnostics.

Complete final filesystem tree, including preserved/generated outputs:
[final_tree.txt](reorganization/final_tree.txt).
The compact tree containing all non-generated sources, documentation and
placeholders is [source_tree.txt](reorganization/source_tree.txt).


## Verification boundary

The PASS results above apply only to the existing controller, scheduler,
standalone-component and modeled-backend integration tests. They are not a
claim that the full NTT/INTT arithmetic datapath, coefficient memory, physical
zeroization, algorithm KATs or ASIC implementation are verified. Missing
backend RTL/specifications remain exactly as documented in the integration
review.
