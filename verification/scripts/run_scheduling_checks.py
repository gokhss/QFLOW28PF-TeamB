#!/usr/bin/env python3
"""Strict design lint plus parameterized scheduler/counter integration tests."""
import os
from pathlib import Path
import subprocess
from paths import CODES, TB, source, new_build

CONFIGS = [(n, lanes) for n in (2, 4, 8, 256, 512, 1024) for lanes in (1, 2, 4, 8)]


def main():
    build = new_build(prefix="pqc-scheduling-")
    print(f"Logs/build: {build}", flush=True)
    for n, lanes in CONFIGS:
        result = subprocess.run(
            ["verilator", "--lint-only", "--sv", "-Wall", "--top-module",
             "butterfly_scheduler", f"-GN={n}", f"-GLANES={lanes}",
             str(source("butterfly_scheduler.sv"))], capture_output=True, text=True,
        )
        (build / f"scheduler-lint-{n}-{lanes}.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
    for n in (2, 4, 8, 256, 512, 1024):
        result = subprocess.run(
            ["verilator", "--lint-only", "--sv", "-Wall", "--top-module",
             "stage_counter", f"-GN={n}", str(source("stage_counter.sv"))],
            capture_output=True, text=True,
        )
        (build / f"counter-lint-{n}.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
    print("PASS: 30 strict new-block lint checks (no warning waivers)", flush=True)
    env = os.environ.copy()
    env["CCACHE_DIR"] = str(build / "ccache")
    env["CCACHE_TEMPDIR"] = str(build / "ccache-tmp")
    Path(env["CCACHE_TEMPDIR"]).mkdir()
    cmd = ["verilator", "--binary", "--timing", "--assert", "--timescale", "1ns/1ps",
           "-Wall", "-Wno-fatal", "--top-module", "scheduling_tb", "--Mdir", str(build / "obj"),
           "-j", "2", "-CFLAGS", "-O0", "--output-split", "10000",
           *[str(TB / Path(f).name) if f.startswith("tests/") else str(source(f)) for f in ("stage_counter.sv", "ntt_controller.sv",
                                    "butterfly_scheduler.sv", "tests/scheduling_tb.sv")]]
    with (build / "build.log").open("w") as log:
        subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(build / "obj" / "Vscheduling_tb")],
                            capture_output=True, text=True)
    (build / "simulation.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="", flush=True)
    result.check_returncode()


if __name__ == "__main__":
    main()
