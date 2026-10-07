// Verification only; not part of the synthesizable subsystem.
module controller_case #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned SC = $clog2(N),
    localparam int unsigned SW = (SC <= 1) ? 1 : $clog2(SC)
) (output bit finished);
    bit clk = 0;
    always #5 clk = ~clk;
    logic rst_n, a2b_start, a2b_abort, a2b_zeroize;
    logic ntt_enable, intt_mode, butterfly_done, stage_done, zeroize_done;
    logic [5:0] a2b_cmd_opcode;
    logic [3:0] a2b_profile_id;
    logic [4:0] a2b_context_id;
    logic [SW-1:0] cfg_last_stage;
    logic b2a_ready, b2a_busy, b2a_done;
    logic [15:0] b2a_error_code;
    logic ntt_active, ntt_start, stage_start, butterfly_enable;
    logic zeroize_req, transform_done, transform_abort, transform_intt;
    logic [SW-1:0] stage_count;
    logic wr, wb, wd, wa, wn, ws, we, wz, wt, wx, wi;
    logic [15:0] werr;
    logic [SW-1:0] wc;
    bit compare_wrapper;

    logic controller_fault;
    ntt_controller #(.N(N), .LANES(LANES)) dut (.*);
    intt_controller #(.N(N), .LANES(LANES)) inverse (
        .clk(clk), .rst_n(rst_n),
        .a2b_cmd_opcode(a2b_cmd_opcode), .a2b_profile_id(a2b_profile_id),
        .a2b_context_id(a2b_context_id), .a2b_start(a2b_start),
        .a2b_abort(a2b_abort), .a2b_zeroize(a2b_zeroize),
        .ntt_enable(ntt_enable), .cfg_last_stage(cfg_last_stage),
        .butterfly_done(butterfly_done), .stage_done(stage_done),
        .zeroize_done(zeroize_done), .b2a_ready(wr), .b2a_busy(wb),
        .b2a_done(wd), .b2a_error_code(werr), .ntt_active(wa),
        .ntt_start(wn), .stage_start(ws), .butterfly_enable(we),
        .zeroize_req(wz), .transform_done(wt), .transform_abort(wx),
        .transform_intt(wi), .stage_count(wc)
    );

    task automatic check(input bit ok, input string why);
        if (!ok) $fatal(1, "N=%0d LANES=%0d: %s", N, LANES, why);
    endtask
    task automatic tick;
        @(posedge clk);
        #1;
    endtask
    task automatic reset_dut;
        compare_wrapper = 0;
        rst_n = 0;
        a2b_start = 0; a2b_abort = 0; a2b_zeroize = 0;
        ntt_enable = 1; intt_mode = 1;
        butterfly_done = 0; stage_done = 0; zeroize_done = 0;
        a2b_cmd_opcode = '0; a2b_profile_id = '0; a2b_context_id = '0;
        cfg_last_stage = SW'(SC-1);
        #1;
        check(!b2a_ready && !b2a_busy && !b2a_done && !stage_start &&
              !zeroize_req && stage_count == 0, "reset outputs");
        tick();
        @(negedge clk);
        rst_n = 1;
        #1;
        compare_wrapper = 1;
        check(b2a_ready, "ready after reset");
    endtask
    task automatic launch;
        check(b2a_ready, "acceptance precondition");
        a2b_start = 1;
        tick();
        a2b_start = 0;
        check(ntt_start && b2a_busy && !b2a_ready, "LOAD");
    endtask
    task automatic complete_stages(input int unsigned count);
        for (int unsigned s = 0; s < count; s++) begin
            tick();
            check(stage_start && b2a_busy && stage_count == SW'(s), "stage dispatch/index");
            tick();
            check(butterfly_enable && b2a_busy, "butterfly entry");
            // Exercise arbitrary public latency, start-while-busy, and an
            // independent butterfly completion that must NOT end the stage.
            repeat (1 + (s % 3)) begin
                a2b_start = 1;
                butterfly_done = 1;
                tick();
                check(butterfly_enable && !stage_start && !b2a_done &&
                      stage_count == SW'(s), "wait/ignore busy start and butterfly_done");
            end
            a2b_start = 0; butterfly_done = 0;
            stage_done = 1;
            tick();
            stage_done = 0;
            check(b2a_busy && !butterfly_enable && !b2a_done, "stage retirement wait");
        end
        tick();
        check(b2a_done && transform_done && b2a_busy && !b2a_ready, "COMPLETE");
    endtask
    task automatic reach(input int target);
        reset_dut();
        if (target != 0) begin
            launch();
            case (target)
                1: begin end
                2: tick();
                3: begin tick(); tick(); end
                4: begin tick(); tick(); stage_done = 1; tick(); stage_done = 0; end
                5: complete_stages(SC);
                6: begin a2b_abort = 1; tick(); a2b_abort = 0; end
                7: begin a2b_zeroize = 1; tick(); a2b_zeroize = 0; end
                default: $fatal(1, "bad test target");
            endcase
        end
    endtask
    task automatic finish_scrub;
        repeat (3) begin
            tick();
            check(zeroize_req && b2a_busy && !b2a_ready && !b2a_done &&
                  !stage_start && !butterfly_enable, "hold through clearing");
        end
        zeroize_done = 1;
        tick();
        check(b2a_ready && !b2a_busy && !zeroize_req && !b2a_done, "clearing retirement");
        zeroize_done = 0;
    endtask

    always @(negedge clk) begin
        if (compare_wrapper && rst_n)
            check({b2a_ready,b2a_busy,b2a_done,b2a_error_code,ntt_active,ntt_start,
                   stage_start,butterfly_enable,zeroize_req,transform_done,
                   transform_abort,transform_intt,stage_count} ===
                  {wr,wb,wd,werr,wa,wn,ws,we,wz,wt,wx,wi,wc}, "inverse wrapper equivalence");
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        (a2b_abort || a2b_zeroize) |-> (!b2a_done && !transform_done && !stage_start));
    assert property (@(posedge clk) disable iff (!rst_n)
        (a2b_start && b2a_ready) |=> b2a_busy);
    assert property (@(posedge clk) disable iff (!rst_n)
        zeroize_req |-> (b2a_busy && !b2a_ready && !b2a_done));
    assert property (@(posedge clk) disable iff (!rst_n)
        (zeroize_req && (!zeroize_done || a2b_zeroize)) |=> zeroize_req);
    assert property (@(posedge clk) disable iff (!rst_n)
        !(b2a_ready && b2a_busy));
    assert property (@(posedge clk) disable iff (!rst_n)
        b2a_done == transform_done);

    initial begin
        finished = 0;
        // Full forward and inverse schedules, including captured config/mode.
        for (int mode = 0; mode < 2; mode++) begin
            reset_dut();
            compare_wrapper = (mode == 1);
            intt_mode = 1'(mode);
            launch();
            intt_mode = !intt_mode;
            cfg_last_stage = '0;
            complete_stages(SC);
            check(transform_intt == 1'(mode), "captured direction");
            tick();
            check(b2a_ready && !b2a_busy && !b2a_done && stage_count == 0, "normal retirement");
        end
        // Shorter profile and minimum one-stage operation.
        if (SC > 1) begin
            reset_dut(); cfg_last_stage = SW'(SC-2); launch();
            complete_stages(SC-1); tick();
        end
        reset_dut(); cfg_last_stage = '0; launch(); complete_stages(1); tick();

        // Abort in every active state, including a stage_done/completion race.
        for (int target = 1; target <= 5; target++) begin
            reach(target);
            a2b_abort = 1; stage_done = 1;
            #1;
            check(!stage_start && !ntt_start && !b2a_done, "cancel dispatch/success");
            tick();
            check(transform_abort && b2a_busy && !b2a_done, "synchronous abort");
            if (target == 4) check(stage_count == 0, "no canceled stage increment");
            a2b_abort = 0; stage_done = 0;
            tick();
            check(zeroize_req, "abort enters zeroize");
            finish_scrub();
        end
        // Zeroize in every state, also racing abort and stage completion.
        for (int target = 0; target <= 7; target++) begin
            reach(target);
            a2b_zeroize = 1; a2b_abort = 1; stage_done = 1; a2b_start = 1;
            #1;
            check(!b2a_done && !stage_start && !b2a_ready, "zeroize priority before edge");
            tick();
            check(zeroize_req && !transform_abort && b2a_busy, "zeroize beats abort");
            zeroize_done = 1;
            repeat (2) begin
                tick();
                check(zeroize_req && !b2a_ready, "held zeroize blocks acknowledged exit");
            end
            a2b_zeroize = 0; a2b_abort = 0; stage_done = 0; a2b_start = 0;
            tick(); zeroize_done = 0;
            check(b2a_ready && !b2a_done, "zeroize release");
        end
        // Asynchronous reset assertion during all lifecycle states.
        for (int target = 0; target <= 7; target++) begin
            reach(target); reset_dut();
        end
        reset_dut();
        a2b_abort = 1; a2b_start = 1; tick();
        check(!b2a_busy && !b2a_ready, "idle abort inhibits start");
        a2b_abort = 0; a2b_start = 0;
        ntt_enable = 0; #1; check(!b2a_ready, "disabled admission");
        ntt_enable = 1;
        if ((2**SW) > SC) begin
            cfg_last_stage = SW'(SC); #1;
            check(!b2a_ready, "out-of-range stage configuration");
            a2b_start = 1; tick(); check(!b2a_busy, "invalid config not accepted");
            a2b_start = 0; cfg_last_stage = SW'(SC-1);
        end
        // Inject an unused encoding; this is RTL recovery, not gate fault proof.
        reset_dut(); compare_wrapper = 0;
        // Deliberately violate the enum for fault injection only.
        /* verilator lint_off ENUMVALUE */
        force dut.state = 4'hf;
        /* verilator lint_on ENUMVALUE */
        #1;
        check(!b2a_ready && !b2a_done && b2a_busy, "illegal state fail closed");
        tick();
        release dut.state;
        tick();
        check(zeroize_req && b2a_busy, "illegal state recovery");
        finish_scrub();
        $display("PASS N=%0d LANES=%0d", N, LANES);
        finished = 1;
    end
endmodule

module controller_tb;
    wire [14:0] finished;
    for (genvar n = 0; n < 3; n++) begin : g_n
        for (genvar l = 0; l < 4; l++) begin : g_l
            controller_case #(.N(256 << n), .LANES(1 << l)) tc
                (.finished(finished[n*4+l]));
        end
    end
    controller_case #(.N(2), .LANES(1)) small2 (.finished(finished[12]));
    controller_case #(.N(4), .LANES(2)) small4 (.finished(finished[13]));
    controller_case #(.N(8), .LANES(8)) small8 (.finished(finished[14]));
    initial begin
        wait (&finished);
        $display("PASS all 15 configurations, both modules and assertions");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "test timeout");
    end
endmodule
