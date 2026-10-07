// Verification backend only; does not implement or verify cryptographic math.
module ntt_control_case #(
    parameter int unsigned N=256, LANES=1,
    localparam int unsigned SC=$clog2(N), SW=(SC<=1)?1:$clog2(SC),
    localparam int unsigned AW=$clog2(N), BW=(N<=2)?1:$clog2(N/2)
)(output bit finished);
    bit clk=0;
    always #5 clk=~clk;
    logic rst_n, start, enable, intt_mode;
    logic [SW-1:0] cfg_last_stage, cfg_first_span_log2;
    logic cfg_span_descending, abort_req, zeroize, datapath_fault;
    logic [1:0] c2b_ecc_status;
    logic consuming_beat;
    wire ecc_uncorrectable=consuming_beat && c2b_ecc_status[1];
    logic scrub_done, backend_flushed, ready, busy, done, zeroize_req;
    logic active, load_start, stage_start, butterfly_enable, transform_abort, transform_intt;
    logic [SW-1:0] stage_count, batch_stage, batch_span_log2;
    logic batch_valid, batch_ready, batch_intt, batch_retired, stage_done, scheduler_quiescent;
    logic [LANES-1:0] lane_valid;
    logic [LANES-1:0][AW-1:0] coeff_addr_a, coeff_addr_b;
    logic [LANES-1:0][BW-1:0] butterfly_index;
    logic error_config, error_ecc, error_datapath, error_scheduler, error_controller;
    ntt_control #(.N(N),.LANES(LANES)) dut (.*);
    task automatic check(input bit ok,input string why);
        if (!ok) $fatal(1,"N=%0d LANES=%0d %s",N,LANES,why);
    endtask
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic reset_all;
        rst_n=0; start=0; enable=1; intt_mode=0;
        cfg_last_stage=SW'(SC-1); cfg_first_span_log2=SW'(SC-1);
        cfg_span_descending=1; abort_req=0; zeroize=0; datapath_fault=0;
        consuming_beat=0; c2b_ecc_status=0; scrub_done=0; backend_flushed=0;
        batch_ready=0; batch_retired=0;
        tick(); check(!busy && !done && !batch_valid,"reset");
        @(negedge clk); rst_n=1; #1; check(ready,"ready after reset");
    endtask
    task automatic launch(input bit inverse);
        intt_mode=inverse; cfg_span_descending=!inverse;
        cfg_first_span_log2=inverse?'0:SW'(SC-1);
        cfg_last_stage=SW'(SC-1);
        #1; check(ready,"launch ready"); start=1; tick(); start=0;
        check(busy && !ready,"full-operation busy");
    endtask
    task automatic reach_offer;
        while(!batch_valid) begin tick(); check(busy && !done,"pending operation"); end
    endtask
    task automatic accept_batch;
        batch_ready=1; tick(); batch_ready=0;
        check(!batch_valid && lane_valid=='0,"mask only during offer");
    endtask
    task automatic finish_work(input bit inverse);
        int stages, batches;
        stages=0; batches=0;
        // Input config can change once accepted; the operation uses snapshots.
        cfg_first_span_log2='0; cfg_last_stage='0; cfg_span_descending=inverse;
        intt_mode=!inverse;
        while (!done) begin
            if (stage_start) stages++;
            if (batch_valid) begin
                check(batch_intt==inverse,"latched direction");
                check(batch_span_log2==SW'(inverse?int'(batch_stage):SC-1-int'(batch_stage)),
                      "derived stage/span");
                batches++;
                // A spurious start while busy cannot change the transaction.
                start=1; accept_batch(); start=0;
                repeat(2) tick();
                check(!stage_done,"no completion before write retirement");
                batch_retired=1; tick(); batch_retired=0; #1;
            end else tick();
            check(busy,"busy must cover all stages and completion");
        end
        check(stages==SC && batches==SC*((N/2+LANES-1)/LANES),"complete work count");
    endtask
    task automatic cleanup;
        // Early scrub acknowledgement is insufficient while work can return.
        scrub_done=1;
        repeat(3) begin tick(); check(busy && !done,"drain holds busy"); end
        backend_flushed=1; tick(); tick();
        backend_flushed=0; scrub_done=0; #1;
        check(ready && !busy && !done,"flush/scrub recovery");
    endtask
    assert property (@(posedge clk) disable iff(!rst_n) done |-> busy);
    assert property (@(posedge clk) disable iff(!rst_n) !batch_valid |-> lane_valid=='0);
    assert property (@(posedge clk) disable iff(!rst_n)
        (abort_req || zeroize || ecc_uncorrectable || datapath_fault) |->
        (!done && !stage_start && !batch_valid));
    assert property (@(posedge clk) disable iff(!rst_n) stage_start |-> int'(stage_count)<SC);
    initial begin
        finished=0; reset_all();
        for(int mode=0;mode<2;mode++) begin
            launch(1'(mode));
            c2b_ecc_status=2'b01; consuming_beat=1; // Correctable is not fatal.
            finish_work(1'(mode)); check(!error_ecc,"correctable ECC");
            tick(); check(ready,"back-to-back mode switching");
        end
        // Uncorrectable status without a consuming beat is ignored.
        c2b_ecc_status=2'b10; consuming_beat=0;
        launch(0); reach_offer(); accept_batch(); tick();
        check(!error_ecc && busy,"ECC ownership qualification");
        consuming_beat=1; #1; check(!done && !batch_valid,"ECC immediate invalidation");
        tick(); consuming_beat=0; c2b_ecc_status=0;
        check(error_ecc,"sticky ECC cause"); cleanup(); check(error_ecc,"cause survives scrub");
        launch(1); check(!error_ecc,"cause clears on next accepted command");
        reach_offer(); accept_batch(); datapath_fault=1; tick(); datapath_fault=0;
        cleanup(); check(error_datapath,"datapath cause");
        launch(0); reach_offer(); // Retirement with no accepted descriptor.
        batch_retired=1; tick(); batch_retired=0; tick();
        check(error_scheduler,"scheduler fault propagation"); cleanup();
        launch(0); reach_offer(); accept_batch(); abort_req=1; zeroize=1;
        tick(); abort_req=0; zeroize=0;
        check(zeroize_req && !done,"zeroize over abort"); cleanup();
        // Both fault and zeroize must suppress an otherwise successful cycle.
        for(int kind=0;kind<2;kind++) begin
            launch(0); finish_work(0);
            if(kind==0) begin c2b_ecc_status=2'b10; consuming_beat=1; end
            else zeroize=1;
            #1; check(!done,"completion race suppressed");
            tick(); zeroize=0; consuming_beat=0; c2b_ecc_status=0;
            backend_flushed=1; scrub_done=1;
            repeat(4) tick(); backend_flushed=0; scrub_done=0; #1;
            check(ready && !done,"completion race cleanup");
        end
        if(SC>1) begin
            cfg_first_span_log2='0; cfg_last_stage=SW'(SC-1); cfg_span_descending=1;
            start=1; tick(); start=0;
            check(!busy && error_config,"reject impossible descending schedule");
        end
        launch(0);
        /* verilator lint_off ENUMVALUE */
        force dut.u_controller.state=4'hf;
        /* verilator lint_on ENUMVALUE */
        tick(); release dut.u_controller.state; tick();
        check(error_controller && zeroize_req && !done,"illegal controller recovery");
        backend_flushed=1; scrub_done=1; repeat(3) tick();
        backend_flushed=0; scrub_done=0; #1; check(ready,"illegal recovery complete");
        reset_all(); zeroize=1; tick(); zeroize=0;
        check(busy && zeroize_req,"idle zeroize"); scrub_done=1; tick(); scrub_done=0;
        check(ready,"idle zeroize completes");
        $display("PASS ntt_control N=%0d LANES=%0d",N,LANES); finished=1;
    end
endmodule
module ntt_control_tb;
    wire [23:0] finished;
    for(genvar n=0;n<6;n++) begin : g_n
        localparam int unsigned SIZE=(n==0)?2:(n==1)?4:(n==2)?8:(n==3)?256:(n==4)?512:1024;
        for(genvar l=0;l<4;l++) begin : g_l
            ntt_control_case #(.N(SIZE),.LANES(2**l)) test_case(.finished(finished[n*4+l]));
        end
    end
    initial begin wait(&finished); $display("PASS all integration cases"); $finish; end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule
