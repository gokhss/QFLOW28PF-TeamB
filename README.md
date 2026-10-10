# Q-FLOW28-PF shared NTT/INTT control RTL

The fixed hierarchy is `ntt_control` -> `ntt_controller` -> `stage_counter`,
plus `ntt_control` -> `butterfly_scheduler`. `intt_controller` is an alternative
inverse-only wrapper, not an additional engine in that hierarchy.
`qf_ntt_scheduler` remains a separate standalone scheduler. It does not replace
or connect to `butterfly_scheduler`.

## Layout

- `rtl/ntt/control/`: transform/stage control and combinational twiddle addressing.
- `rtl/ntt/scheduler/`: existing batch scheduler and separate standalone scheduler.
- `rtl/ntt/interface/`: C2B request/response interface.
- `rtl/ntt/memory/`: supplied twiddle ROM interface.
- `rtl/ntt/datapath/`: placeholder only; no arithmetic RTL has been supplied.
- `tb/ntt/`: original, unmodified SystemVerilog testbenches.
- `verification/scripts/`: original test runners with updated path/build plumbing.
- `verification/logs/`, `verification/results/`: preserved local evidence and new
  run summaries; ignored by Git, except directory placeholders.
- `docs/`: design/review documents, historical references and reorganization audit.
- `filelists/`: fixed control RTL and its existing integration testbench filelists.
- `build/`: generated Verilator output, binaries, caches and per-run logs; ignored
  by Git. Pre-reorganization build output remains here as historical local data.

`docs/legacy/CODE1` is the unchanged original controller reference, excluded
from compile lists. Do not compile it as a second `ntt_controller` definition.
The project documents and submitted `codes.zip` in the parent directory are
unchanged. The ZIP remains a historical snapshot, not the current layout.

## Verification

Requirements: Python 3, Verilator (tested with 5.038), GNU Make and a C++ toolchain.
From `~/Documents/PQC`, execute:

```sh
verilator --lint-only --sv -Wall -Wno-fatal --top-module ntt_control -F codes/filelists/ntt_control.f
verilator --lint-only --timing --assert --timescale 1ns/1ps -Wall -Wno-fatal --top-module ntt_control_tb -F codes/filelists/ntt_control_tb.f
python3 codes/verification/scripts/run_controller_checks.py
python3 codes/verification/scripts/run_scheduling_checks.py
python3 codes/verification/scripts/run_submitted_checks.py
python3 codes/verification/scripts/run_integration_checks.py
```

Use `-F`, not `-f`: nested filelists and source paths are relative to their
filelist directory. Each Python runner resolves sources relative to its own
location, so it also works from another current directory. Every run gets an
isolated directory under `build/`; the printed path contains its build, lint,
simulation and cache output. No test algorithm, parameter matrix, compiler
options or warning policy was changed by the move.

The baseline has documented unused-port/empty-output diagnostics; `-Wno-fatal`
does not make those warnings disappear. The submitted-block runner also exposes
the fixed control's original inline waiver in temporary audit copies. See
[the integration review](docs/FIXED_INTEGRATION_REVIEW.md) for the warning scope.

## Verification limits

These tests establish controller/scheduler/standalone-component behavior with
verification models. The arithmetic datapath, coefficient memory and final
backend latency/retirement specification remain unavailable. There is no full
NTT/INTT cryptographic datapath verification or algorithm KAT claim.

See [the reorganization report](docs/REORGANIZATION.md) for the file-by-file move
ledger, checksums, directory trees, executed commands and results.
