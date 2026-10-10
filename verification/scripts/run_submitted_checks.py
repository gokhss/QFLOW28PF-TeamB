#!/usr/bin/env python3
"""Component evidence only; cannot certify the absent full architecture."""
from pathlib import Path
import os
import re
import subprocess
from paths import CODES, TB, source, new_build

MODULES = ('qf_ntt_scheduler', 'qf_ntt_twiddle_addr_gen',
           'qf_ntt_twiddle_mem', 'qf_ntt_c2b_if')


def main():
    build = new_build(prefix='qf-submitted-')
    print(f'Logs/build: {build}', flush=True)
    for module in MODULES:
        result = subprocess.run(['verilator', '--lint-only', '--sv', '-Wall',
                                 '--top-module', module, str(source(module+'.sv'))],
                                capture_output=True, text=True)
        (build / (module+'.lint.log')).write_text(result.stdout+result.stderr)
        print(result.stdout+result.stderr, end='', flush=True)
        result.check_returncode()
    # Expose the existing fixed control layer's inline warning waivers without
    # modifying that RTL: lint temporary copies with only pragma comments removed.
    audit = build / 'unwaived'
    audit.mkdir()
    control_sources = ('stage_counter.sv', 'ntt_controller.sv',
                       'butterfly_scheduler.sv', 'ntt_control.sv')
    for name in control_sources:
        text = source(name).read_text()
        text = re.sub(r'/\*\s*verilator\s+lint_(?:off|on).*?\*/',
                      '/* Baseline waiver removed for audit only. */', text, flags=re.S)
        (audit / name).write_text(text)
    result = subprocess.run(['verilator', '--lint-only', '--sv', '-Wall', '-Wno-fatal',
                             '--top-module', 'ntt_control',
                             *[str(audit / name) for name in control_sources]],
                            capture_output=True, text=True)
    (build / 'control-unwaived.lint.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr, end='', flush=True)
    result.check_returncode()  # Warnings are reported, never labeled a clean lint.
    env = os.environ.copy()
    env['CCACHE_DIR'] = str(build / 'ccache')
    env['CCACHE_TEMPDIR'] = str(build / 'ccache-tmp')
    Path(env['CCACHE_TEMPDIR']).mkdir()
    command = ['verilator', '--binary', '--timing', '--assert', '--timescale', '1ns/1ps',
               '-Wall', '-Wno-fatal', '--top-module', 'submitted_blocks_tb',
               '--Mdir', str(build / 'obj'), '-j', '2',
               *[str(source(m+'.sv')) for m in MODULES],
               str(TB / 'submitted_blocks_tb.sv')]
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    (build / 'build.log').write_text(result.stdout+result.stderr)
    # Warnings remain visible/nonfatal in the verification-only build; strict
    # standalone RTL lint above has no waivers and treats warnings as errors.
    print(result.stderr, end='', flush=True)
    result.check_returncode()
    result = subprocess.run([str(build / 'obj/Vsubmitted_blocks_tb')],
                            capture_output=True, text=True)
    (build / 'simulation.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr, end='', flush=True)
    result.check_returncode()
    print('Full fixed-architecture integration: BLOCKED (see docs/FIXED_INTEGRATION_REVIEW.md)')


if __name__ == '__main__':
    main()
