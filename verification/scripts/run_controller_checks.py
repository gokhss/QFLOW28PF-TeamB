#!/usr/bin/env python3
"""Lint both controller entry points, then run directed tests with SVA enabled."""
import os
from pathlib import Path
import re
import subprocess
from paths import CODES, TB, source, new_build

BUILD = new_build(prefix="pqc-controller-")
SOURCES = [str(source(name)) for name in
           ("stage_counter.sv", "ntt_controller.sv", "intt_controller.sv")]
CONFIGS = [(n, lanes) for n in (256, 512, 1024) for lanes in (1, 2, 4, 8)]
CONFIGS += [(2, 1), (4, 2), (8, 8)]
EXPECTED_UNUSED = {"a2b_cmd_opcode", "a2b_profile_id", "a2b_context_id", "butterfly_done"}


def main():
    print(f"Logs/build: {BUILD}", flush=True)
    for top in ("ntt_controller", "intt_controller"):
        for n, lanes in CONFIGS:
            result = subprocess.run(
                ["verilator", "--lint-only", "--sv", "-Wall", "-Wno-fatal",
                 "--top-module", top, f"-GN={n}", f"-GLANES={lanes}", *SOURCES],
                capture_output=True, text=True, check=False,
            )
            output = result.stdout + result.stderr
            (BUILD / f"lint-{top}-{n}-{lanes}.log").write_text(output)
            if result.returncode:
                raise RuntimeError(output)
            # Waive only these four explicitly retained integration inputs.
            # Width, latch, loop, and all other unexpected diagnostics fail.
            seen = set()
            for line in output.splitlines():
                if line.startswith("%Warning"):
                    match = re.search(r"%Warning-UNUSEDSIGNAL:.*Signal is not used: '([^']+)'", line)
                    if not match or match.group(1) not in EXPECTED_UNUSED:
                        raise RuntimeError(f"Unexpected lint diagnostic: {line}")
                    seen.add(match.group(1))
            if seen != EXPECTED_UNUSED:
                raise RuntimeError(f"Revisit unused-port expectations: {seen}")
    print("PASS: 30 lint/elaboration configurations; only four documented unused inputs", flush=True)
    env = os.environ.copy()
    env["CCACHE_DIR"] = str(BUILD / "ccache")
    env["CCACHE_TEMPDIR"] = str(BUILD / "ccache-tmp")
    Path(env["CCACHE_TEMPDIR"]).mkdir()
    command = [
        "verilator", "--binary", "--timing", "--assert", "--timescale", "1ns/1ps",
        "-Wall", "-Wno-fatal", "--top-module", "controller_tb",
        "--Mdir", str(BUILD / "obj"), "-j", "2", *SOURCES,
        str(TB / "controller_tb.sv"),
    ]
    with (BUILD / "build.log").open("w") as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(BUILD / "obj" / "Vcontroller_tb")],
                            capture_output=True, text=True, check=False)
    (BUILD / "simulation.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    result.check_returncode()


if __name__ == "__main__":
    main()
