from pathlib import Path
import subprocess,sys,json,hashlib,concurrent.futures,os,shutil
ROOT=Path('/home/gokhs/QFLOW28PF-TeamB')
OUT=ROOT/'reports/yosys/run_20261010'
SOURCES=['rtl/ntt/control/stage_counter.sv','rtl/ntt/control/ntt_controller.sv','rtl/ntt/scheduler/butterfly_scheduler.sv','rtl/ntt/control/ntt_control.sv']
YOSYS='/tmp/qflow-tools-20261009/oss-cad-suite/bin/yosys'
LIB='/labroot/openroad/OpenROAD/test/Nangate45/Nangate45_typ.lib'
def cmd(args,log,cwd=ROOT,env=None):
 with Path(log).open('w') as f:p=subprocess.run(args,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,env=env)
 return p.returncode
def audit():
 OUT.mkdir(parents=True,exist_ok=True)
 data={'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'status_before':subprocess.check_output(['git','status','--short'],cwd=ROOT,text=True),'sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'rtl').rglob('*.sv'))}}
 (OUT/'baseline.json').write_text(json.dumps(data,indent=2)+'\n')
 cmd(['git','diff','5501d63..HEAD','--','rtl'],OUT/'historical_rtl.diff')
 cmd(['git','diff','--','rtl'],OUT/'working_rtl.diff')
 cmd(['/usr/bin/yosys','-p','read_verilog -sv rtl/ntt/control/stage_counter.sv'],OUT/'old_yosys_parse.log')
 print('Audit saved:',OUT,flush=True)
def tests():
 (OUT/'tests').mkdir(parents=True,exist_ok=True)
 common=SOURCES+['rtl/ntt/control/intt_controller.sv']
 specs={'controller_tb':common,'ntt_control_tb':common,'scheduling_tb':common,'submitted_blocks_tb':['rtl/ntt/scheduler/qf_ntt_scheduler.sv','rtl/ntt/memory/qf_ntt_twiddle_addr_gen.sv','rtl/ntt/memory/qf_ntt_twiddle_mem.sv','rtl/ntt/interface/qf_ntt_c2b_if.sv']}
 def run(item):
  top,src=item;build=OUT/'tests'/top;build.mkdir(exist_ok=True);env=os.environ.copy();env['CCACHE_DIR']=str(OUT/'ccache');env['CCACHE_TEMPDIR']=str(OUT/'ccache_tmp');Path(env['CCACHE_TEMPDIR']).mkdir(exist_ok=True)
  args=['/usr/local/bin/verilator','--binary','--timing','--assert','--timescale','1ns/1ps','-Wall','-Wno-fatal','--top-module',top,'--Mdir',str(build/'obj'),'-j','2',*src,'tb/ntt/'+top+'.sv']
  if top=='scheduling_tb':args[args.index('--Mdir'):args.index('--Mdir')]=['-CFLAGS','-O0','--output-split','10000']
  rc=cmd(args,build/'build.log',env=env);sim=None
  if rc==0:sim=cmd([str(build/'obj'/('V'+top))],build/'simulation.log',env=env)
  print(top,'build',rc,'simulation',sim,flush=True);return top,{'build':rc,'simulation':sim,'command':args}
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=dict(pool.map(run,specs.items()))
 (OUT/'test_results.json').write_text(json.dumps(results,indent=2)+'\n')
 if any(x['build']!=0 or x['simulation']!=0 for x in results.values()):raise SystemExit(1)
def ecc_test():
 p=ROOT/'tb/ntt/submitted_blocks_tb.sv';s=p.read_text()
 assert s.count("16'h9002")==1
 p.write_text(s.replace("16'h9002","16'h8002"))
 target=OUT/'tests/submitted_blocks_tb'
 shutil.copyfile(target/'simulation.log',target/'simulation_before_expectation_fix.log')
 args=['/usr/local/bin/verilator','--binary','--timing','--assert','--timescale','1ns/1ps','-Wall','-Wno-fatal','--top-module','submitted_blocks_tb','--Mdir',str(target/'obj'),'-j','2','rtl/ntt/scheduler/qf_ntt_scheduler.sv','rtl/ntt/memory/qf_ntt_twiddle_addr_gen.sv','rtl/ntt/memory/qf_ntt_twiddle_mem.sv','rtl/ntt/interface/qf_ntt_c2b_if.sv','tb/ntt/submitted_blocks_tb.sv']
 env=os.environ.copy();env['CCACHE_DIR']=str(OUT/'ccache');env['CCACHE_TEMPDIR']=str(OUT/'ccache_tmp')
 rc=cmd(args,target/'build_after_expectation_fix.log',env=env)
 if rc:raise SystemExit(rc)
 rc=cmd([str(target/'obj/Vsubmitted_blocks_tb')],target/'simulation_after_expectation_fix.log',env=env)
 data=json.loads((OUT/'test_results.json').read_text());data['submitted_blocks_tb']['corrected_expectation_simulation']=rc;(OUT/'test_results.json').write_text(json.dumps(data,indent=2)+'\n')
 cmd(['git','diff','--','tb/ntt/submitted_blocks_tb.sv'],OUT/'test_expectation.diff')
 print('Corrected-expectation standalone simulation exit',rc,flush=True)
 raise SystemExit(rc)
def activity():
 directory=OUT/'activity';directory.mkdir(exist_ok=True)
 wrapper=directory/'power_tb.sv'
 wrapper.write_text('''// Verification-only wrapper around the existing directed test case.
module power_tb;
 wire [3:0] finished;
 for(genvar l=0;l<4;l++) begin : g_l
  ntt_control_case #(.N(256),.LANES(2**l)) test_case(.finished(finished[l]));
  integer cycle=0;
  integer accepted_cycle=0;
  integer completed=0;
  always @(posedge test_case.clk) begin
   cycle=cycle+1;
   if(test_case.start && test_case.ready) accepted_cycle=cycle;
   if(test_case.done && completed<2) begin
    completed=completed+1;
    $display("ACTIVITY LANES=%0d OP=%0d CYCLES=%0d END_PS=%0d",2**l,completed,cycle-accepted_cycle,$time*1000);
   end
  end
 end
 initial begin $dumpfile("control_activity.vcd");$dumpvars(0,power_tb);end
 initial begin wait(&finished);$finish;end
 initial begin #2000000;$fatal(1,"timeout");end
endmodule
''')
 args=['/usr/local/bin/verilator','--binary','--timing','--assert','--trace','--trace-depth','8','--timescale','1ns/1ps','-Wall','-Wno-fatal','--top-module','power_tb','--Mdir',str(directory/'obj'),'-j','2',*SOURCES,'tb/ntt/ntt_control_tb.sv',str(wrapper)]
 env=os.environ.copy();env['CCACHE_DIR']=str(OUT/'ccache');env['CCACHE_TEMPDIR']=str(OUT/'ccache_tmp')
 rc=cmd(args,directory/'build.log',env=env)
 if rc:raise SystemExit(rc)
 rc=cmd([str(directory/'obj/Vpower_tb')],directory/'simulation.log',cwd=directory,env=env)
 print('Activity simulation',rc,flush=True)
 raise SystemExit(rc)
def synth_one(n=256,lanes=1):
 directory=OUT/f'N{n}_L{lanes}';directory.mkdir(exist_ok=True)
 script=directory/'synthesis.ys'
 common=f"read_slang --top ntt_control -G N={n} -G LANES={lanes} "+' '.join(SOURCES)
 flow=[common,'hierarchy -check -top ntt_control','proc','flatten','opt','check -assert','scc -expect 0',f'tee -o {directory}/word_stat.json stat -json','design -save word_level','synth -top ntt_control -flatten','check -assert','scc -expect 0',f'tee -o {directory}/ntt_control_stat.txt stat',f'tee -o {directory}/ntt_control_stat.json stat -json',f'write_json {directory}/generic_netlist.json',f'write_verilog -noattr {directory}/ntt_control_netlist.v','design -load word_level',f'read_liberty -lib {LIB}','synth -top ntt_control -flatten -noabc',f'dfflibmap -liberty {LIB}',f'abc -liberty {LIB}','clean','check -assert','scc -expect 0',f'tee -o {directory}/mapped_stat.txt stat -liberty {LIB}',f'tee -o {directory}/mapped_stat.json stat -json -liberty {LIB}',f'write_json {directory}/mapped_netlist.json',f'write_verilog -noattr {directory}/mapped_netlist.v']
 script.write_text('\n'.join(flow)+'\n')
 rc=cmd([YOSYS,'-m','slang','-s',str(script)],directory/'ntt_control_synthesis.log')
 print('Synthesis',n,lanes,'exit',rc,flush=True)
 return {'N':n,'LANES':lanes,'exit_code':rc,'directory':str(directory)}
def synth_default():
 result=synth_one();(OUT/'synthesis_default.json').write_text(json.dumps(result,indent=2)+'\n')
 raise SystemExit(result['exit_code'])
def sweep():
 configs=[(n,l) for n in (2,4,8,256,512,1024) for l in (1,2,4,8)]
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda p:synth_one(*p),configs))
 (OUT/'synthesis_runs.json').write_text(json.dumps(results,indent=2)+'\n')
 raise SystemExit(any(r['exit_code'] for r in results))
def physical():
 import re
 openroad='/labroot/openroad/install/OpenROAD/bin/openroad'
 activity_log=(OUT/'activity/simulation.log').read_text()
 ends={int(l):int(t) for l,t in re.findall(r'ACTIVITY LANES=(\d+) OP=2 CYCLES=\d+ END_PS=(\d+)',activity_log)}
 results=[]
 for n in (2,4,8,256,512,1024):
  for lanes in (1,2,4,8):
   d=OUT/f'N{n}_L{lanes}'
   script=d/'sta_power.tcl'
   if (d/'sta_power.log').exists(): shutil.copyfile(d/'sta_power.log', d/'sta_power_initial_no_lef.log')
   lines=['read_lef /labroot/openroad/OpenROAD/test/Nangate45/Nangate45_tech.lef','read_lef /labroot/openroad/OpenROAD/test/Nangate45/Nangate45_stdcell.lef',f'read_liberty {LIB}',f'read_verilog {d}/mapped_netlist.v','link_design ntt_control','create_clock -name clk -period 10 [get_ports clk]','set_input_delay 0 -clock clk [get_ports {start enable intt_mode cfg_last_stage* cfg_first_span_log2* cfg_span_descending abort_req zeroize ecc_uncorrectable datapath_fault scrub_done backend_flushed batch_ready batch_retired}]','set_false_path -from [get_ports rst_n]','set_input_transition 0.05 [all_inputs]','set_output_delay 0 -clock clk [all_outputs]','set_load 1 [all_outputs]',f'report_checks -path_delay max -group_path_count 5 -digits 5 > {d}/timing_paths.txt','report_worst_slack -max','report_check_types -violators','check_setup']
   if n==256:
    idx=(1,2,4,8).index(lanes)
    lines+=['set_power_activity -input -activity 0 -duty 0',f'read_vcd -scope {{power_tb/g_l[{idx}]/test_case/dut}} -end_time {ends[lanes]} {OUT}/activity/control_activity.vcd',f'report_power -digits 8 > {d}/power.txt',f'report_power -format json > {d}/power.json']
   lines+=['exit'];script.write_text('\n'.join(lines)+'\n')
   rc=cmd([openroad,'-exit',str(script)],d/'sta_power.log')
   results.append({'N':n,'LANES':lanes,'exit_code':rc});print('STA/power',n,lanes,rc,flush=True)
 (OUT/'physical_runs.json').write_text(json.dumps(results,indent=2)+'\n')
 raise SystemExit(any(r['exit_code'] for r in results))
def finish():
 import re,csv,datetime
 baseline=json.loads((OUT/'baseline.json').read_text())
 current={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'rtl').rglob('*.sv'))}
 assert current==baseline['sha256'], 'RTL changed during analysis'
 (OUT/'source_integrity.json').write_text(json.dumps({'commit':baseline['commit'],'all_nine_rtl_files_unchanged':True,'sha256':current},indent=2)+'\n')
 cmd(['git','diff','--','rtl'],OUT/'final_rtl.diff')
 cmd(['git','diff','--','tb/ntt/submitted_blocks_tb.sv'],OUT/'test_expectation.diff')
 cmd(['git','status','--short'],OUT/'final_git_status.txt')
 lint_args=['/usr/local/bin/verilator','--lint-only','-Wall','-Wno-fatal','--top-module','ntt_control',*SOURCES]
 lint_rc=cmd(lint_args,OUT/'ntt_control_lint.log')
 (OUT/'lint_result.json').write_text(json.dumps({'command':lint_args,'exit_code':lint_rc,'warnings_allowed_but_not_suppressed':True},indent=2)+'\n')
 tools_report=[]
 for args in [['which','yosys'],['which','verilator'],['which','sby'],['/usr/bin/yosys','-V'],['/usr/local/bin/verilator','--version'],[YOSYS,'-V'],['/tmp/qflow-tools-20261009/oss-cad-suite/bin/slang','--version'],['/tmp/qflow-tools-20261009/oss-cad-suite/bin/sby','--version'],['/labroot/openroad/install/OpenROAD/bin/openroad','-version'],['df','-h',str(ROOT),'/tmp']]:
  r=subprocess.run(args,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  tools_report += ['$ '+' '.join(args),r.stdout.strip(),'exit='+str(r.returncode),'']
 for p in [Path(YOSYS),Path('/tmp/qflow-tools-20261009/oss-cad-suite/libexec/yosys'),Path('/tmp/qflow-tools-20261009/oss-cad-suite/share/yosys/plugins/slang.so'),Path('/labroot/openroad/install/OpenROAD/bin/openroad'),Path(LIB)]:
  if p.is_file():tools_report.append('SHA256 '+str(p)+' '+hashlib.sha256(p.read_bytes()).hexdigest())
 tools_report+=['','Installed release: OSS CAD Suite 2026-10-09, isolated under /tmp; original PATH/tools unchanged.','Official archive: https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-09/oss-cad-suite-linux-x64-20261009.tgz','Archive SHA256: 20b7bd2d24e187aa87bbb3a0b70369a6aa352dac2048033eb2e68439a477ca0d','Archive size: 747604015 bytes; verified before extraction.','The initial curl attempt stalled; Python urllib downloaded the verified complete archive.','read_slang plugin is identified by this release and binary digest; standalone bundled slang version is recorded above. read_slang --version is unsupported.','Before installation: sby absent from PATH; no compatible SV synthesis frontend found. After installation: suite includes sby, eqy, SMT solvers and slang; formal proofs were NOT run.','Installed reference libraries found: Nangate45, sky130, IHP130 (OpenROAD tests), GF180 (OpenLane reproducible). No suitable TSMC28 library found.']
 (OUT/'tool_versions.txt').write_text('\n'.join(tools_report)+'\n')
 rows=[]
 cycles={1:4122,2:2074,4:1050,8:538}
 for n in (2,4,8,256,512,1024):
  for l in (1,2,4,8):
   d=OUT/f'N{n}_L{l}'; g=json.loads((d/'ntt_control_stat.json').read_text())['design'];m=json.loads((d/'mapped_stat.json').read_text())['design'];w=json.loads((d/'word_stat.json').read_text())['design'];types=g['num_cells_by_type'];wt=w['num_cells_by_type']
   ff=sum(v for k,v in types.items() if 'DFF' in k)
   log=(d/'ntt_control_synthesis.log').read_text();sta=(d/'sta_power.log').read_text()
   assert 'ERROR:' not in log and log.count('Found 0 SCCs')>=3
   assert 'ERROR' not in sta
   slack=float(re.search(r'(-?[\d.]+)\s+slack', (d/'timing_paths.txt').read_text()).group(1))
   power=None
   if n==256:
    vals=re.search(r'^Total\s+([\deE+.-]+)\s+([\deE+.-]+)\s+([\deE+.-]+)\s+([\deE+.-]+)',(d/'power.txt').read_text(),re.M)
    power=[float(v)*1e6 for v in vals.groups()]
   row={'configuration':f'ntt_control_N{n}_L{l}','N':n,'LANES':l,'generic_cells':g['num_cells'],'register_bits':ff,'generic_combinational_cells':g['num_cells']-ff,'generic_mux_cells':types.get('$_MUX_',0),'word_adders':wt.get('$add',0),'word_subtractors':wt.get('$sub',0),'word_comparators':sum(wt.get(k,0) for k in ('$eq','$ne','$lt','$le','$gt','$ge')),'word_muxes':wt.get('$mux',0),'word_priority_muxes':wt.get('$pmux',0),'memories':g['num_memories'],'memory_bits':g['num_memory_bits'],'mapped_cells':m['num_cells'],'nangate45_cell_area_um2':m['area'],'setup_slack_ns_at_100MHz':slack,'effective_critical_budget_ns':round(10-slack,5),'max_cap_violations':sta.count('(VIOLATED)'),'power_internal_uW':power[0] if power else None,'power_switching_uW':power[1] if power else None,'power_dynamic_uW':sum(power[:2]) if power else None,'power_leakage_uW':power[2] if power else None,'power_total_uW':power[3] if power else None,'vcd_annotated_pins':int(re.search(r'Annotated (\d+) pin',sta).group(1)) if power else None,'simulation_cycles_per_operation':cycles[l] if n==256 else None,'limitations':'controller only; Nangate45 typical; pre-layout ideal clock/no wire RC; reset false-path; cap violations where listed; power only N256 modeled backend'}
   rows.append(row)
 for r in rows:
  b=next(x for x in rows if x['N']==r['N'] and x['LANES']==1)
  r['relative_area_percent']=round((r['nangate45_cell_area_um2']/b['nangate45_cell_area_um2']-1)*100,4)
  r['relative_register_percent']=round((r['register_bits']/b['register_bits']-1)*100,4)
  r['relative_power_percent']=round((r['power_total_uW']/b['power_total_uW']-1)*100,4) if r['power_total_uW'] is not None else None
  r['model_throughput_operations_per_second']=100e6/r['simulation_cycles_per_operation'] if r['simulation_cycles_per_operation'] else None
 (OUT/'configuration_comparison.json').write_text(json.dumps(rows,indent=2)+'\n')
 with (OUT/'configuration_comparison.csv').open('w',newline='') as f:
  writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
 warnings={}
 for p in sorted((OUT/'tests').glob('*/build*.log')):
  messages=re.findall(r'^%Warning-[^\n]+',p.read_text(),re.M)
  warnings[str(p.relative_to(OUT))]=messages
 warnings['ntt_control_lint.log']=re.findall(r'^%Warning-[^\n]+',(OUT/'ntt_control_lint.log').read_text(),re.M)
 (OUT/'warnings.json').write_text(json.dumps(warnings,indent=2)+'\n')
 (OUT/'.gitignore').write_text('# Generated simulation/compiler caches; preserve reports/scripts/netlists.\nccache/\nccache_tmp/\n**/obj/\n*.vcd\n')
 
 if Path(__file__).resolve() != (OUT/'analysis_driver.py').resolve(): shutil.copyfile(__file__,OUT/'analysis_driver.py')
 table=['| Configuration | N | LANES | Generic cells | FF bits | Mapped cells | Nangate45 area (um2) | Setup slack (ns) | Total power (uW) | Limitations |','|---|---:|---:|---:|---:|---:|---:|---:|---:|---|']
 for r in rows:
  power='unavailable' if r['power_total_uW'] is None else f"{r['power_total_uW']:.3f}"
  table.append(f"| {r['configuration']} | {r['N']} | {r['LANES']} | {r['generic_cells']} | {r['register_bits']} | {r['mapped_cells']} | {r['nangate45_cell_area_um2']:.3f} | {r['setup_slack_ns_at_100MHz']:.5f} | {power} | control only; cap violations={r['max_cap_violations']} |")
 (OUT/'configuration_comparison.md').write_text('\n'.join(table)+'\n')
 report='''# Q-FLOW28PF controller synthesis and baseline review — 2026-10-10

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

'''+ '\n'.join(table)+'''

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
constraint, generating the reported one-input-delay warning. Positive setup
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
'''
 (OUT/'synthesis_summary.md').write_text(report)
 print('Reports finalized; RTL hashes unchanged; lint exit',lint_rc,flush=True)
 print((OUT/'configuration_comparison.md').read_text(),flush=True)

def timing_audit():
 d=OUT/'N256_L1'
 script=d/'sta_diagnostics.tcl'
 script.write_text((d/'sta_power.tcl').read_text().replace('exit\n','check_setup -verbose\nexit\n'))
 rc=cmd(['/labroot/openroad/install/OpenROAD/bin/openroad','-exit',str(script)],d/'sta_diagnostics.log')
 print('STA diagnostics',rc)
def polish():
 rows=json.loads((OUT/'configuration_comparison.json').read_text())
 lines=['## N=256 power and relative comparison detail','', 'All power values are reference estimates in uW; dynamic includes internal and switching. Relative changes use LANES=1 at fixed N. These do not include a datapath or memory backend.','', '| LANES | Dynamic uW | Leakage uW | Total uW | Area change | FF change | Power change | Cycles (each direction) | Annotated pins |','|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
 for r in rows:
  if r['N']==256:
   lines.append(f"| {r['LANES']} | {r['power_dynamic_uW']:.3f} | {r['power_leakage_uW']:.3f} | {r['power_total_uW']:.3f} | {r['relative_area_percent']:.2f}% | {r['relative_register_percent']:.2f}% | {r['relative_power_percent']:.2f}% | {r['simulation_cycles_per_operation']} | {r['vcd_annotated_pins']} |")
 p=OUT/'synthesis_summary.md';s=p.read_text();s=s.replace('## UNOPTFLAT and remaining warnings','\n'.join(lines)+'\n\n## UNOPTFLAT and remaining warnings');s=s.replace('python3 /tmp/qflow_analysis.py finish','python3 /tmp/qflow_analysis.py finish\npython3 /tmp/qflow_analysis.py timing_audit\npython3 /tmp/qflow_analysis.py polish');s=s.replace('constraint, generating the reported one-input-delay warning.','constraint, generating the reported one-input-delay warning. Verbose diagnostics in N256_L1/sta_diagnostics.log confirm this port is rst_n.');p.write_text(s)
 shutil.copyfile(__file__,OUT/'analysis_driver.py')
 assert subprocess.run(['git','diff','--exit-code','--','rtl'],cwd=ROOT).returncode==0
 print('Final report updated; no RTL diff.')
if __name__=='__main__':
 {'audit':audit,'tests':tests,'ecc_test':ecc_test,'activity':activity,'synth_default':synth_default,'sweep':sweep,'physical':physical,'finish':finish,'timing_audit':timing_audit,'polish':polish}[sys.argv[1]]()
