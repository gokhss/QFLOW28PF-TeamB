// Verification-only wrapper around the existing directed test case.
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
