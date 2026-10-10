"""Repository paths only; no verification policy or RTL behavior changes."""
from pathlib import Path
import tempfile

CODES = Path(__file__).resolve().parents[2]
TB = CODES / "tb" / "ntt"
RTL_PATHS = {
    "ntt_control.sv": CODES / "rtl/ntt/control/ntt_control.sv",
    "ntt_controller.sv": CODES / "rtl/ntt/control/ntt_controller.sv",
    "intt_controller.sv": CODES / "rtl/ntt/control/intt_controller.sv",
    "stage_counter.sv": CODES / "rtl/ntt/control/stage_counter.sv",
    "butterfly_scheduler.sv": CODES / "rtl/ntt/scheduler/butterfly_scheduler.sv",
    "qf_ntt_scheduler.sv": CODES / "rtl/ntt/scheduler/qf_ntt_scheduler.sv",
    "qf_ntt_twiddle_addr_gen.sv": CODES / "rtl/ntt/control/qf_ntt_twiddle_addr_gen.sv",
    "qf_ntt_twiddle_mem.sv": CODES / "rtl/ntt/memory/qf_ntt_twiddle_mem.sv",
    "qf_ntt_c2b_if.sv": CODES / "rtl/ntt/interface/qf_ntt_c2b_if.sv",
}


def source(name):
    return RTL_PATHS[name]


def new_build(prefix):
    directory = CODES / "build"
    directory.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=prefix, dir=directory))
