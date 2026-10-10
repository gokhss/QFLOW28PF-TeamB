read_lef /labroot/openroad/OpenROAD/test/Nangate45/Nangate45_tech.lef
read_lef /labroot/openroad/OpenROAD/test/Nangate45/Nangate45_stdcell.lef
read_liberty /labroot/openroad/OpenROAD/test/Nangate45/Nangate45_typ.lib
read_verilog /home/gokhs/QFLOW28PF-TeamB/reports/yosys/run_20261010/N2_L8/mapped_netlist.v
link_design ntt_control
create_clock -name clk -period 10 [get_ports clk]
set_input_delay 0 -clock clk [get_ports {start enable intt_mode cfg_last_stage* cfg_first_span_log2* cfg_span_descending abort_req zeroize ecc_uncorrectable datapath_fault scrub_done backend_flushed batch_ready batch_retired}]
set_false_path -from [get_ports rst_n]
set_input_transition 0.05 [all_inputs]
set_output_delay 0 -clock clk [all_outputs]
set_load 1 [all_outputs]
report_checks -path_delay max -group_path_count 5 -digits 5 > /home/gokhs/QFLOW28PF-TeamB/reports/yosys/run_20261010/N2_L8/timing_paths.txt
report_worst_slack -max
report_check_types -violators
check_setup
exit
