// Verification only. Backend models acknowledge work; no memory/datapath RTL.
module scheduling_case #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned SC = $clog2(N),
    localparam int unsigned SW = (SC <= 1) ? 1 : $clog2(SC),
    localparam int unsigned AW = $clog2(N),
    localparam int unsigned BF = N/2,
    localparam int unsigned BW = (BF <= 1) ? 1 : $clog2(BF),
    localparam int unsigned GROUPS = (BF+LANES-1)/LANES,
    localparam int unsigned PW = LANES*(1+2*AW+BW)+2*SW+1
) (output bit finished);
    bit clk;
    always #5 clk = ~clk;
    logic rst_n, stage_start, transform_intt, butterfly_enable;
    logic [SW-1:0] stage_count, stage_span_log2;
    logic abort_req, zeroize, zeroize_req, batch_ready, batch_retired, backend_flushed;
    logic batch_valid, stage_done, scheduler_quiescent, scheduler_fault;
    logic [LANES-1:0] lane_valid;
    logic [LANES-1:0][AW-1:0] coeff_addr_a, coeff_addr_b;
    logic [LANES-1:0][BW-1:0] butterfly_index;
    logic [SW-1:0] batch_stage, batch_span_log2;
    logic batch_intt;
    logic [SW-1:0] schedule_first_span_log2;
    logic schedule_span_descending;
    bit integrated;
    logic ctl_start, ctl_ready, ctl_busy, ctl_done, ctl_stage_start, ctl_enable;
    logic ctl_zeroize, ctl_intt, ctl_zeroize_done, ctl_mode;
    logic [SW-1:0] ctl_stage, ctl_last;
    logic [15:0] ctl_error;
    logic ctl_active, ctl_ntt_start, ctl_transform_done, ctl_abort;
    logic count_clear, count_load, count_advance, count_last, count_valid;
    logic [SW-1:0] count_cfg, count_value;

    stage_counter #(.N(N)) counter (
        .clk(clk), .rst_n(rst_n), .clear(count_clear), .load(count_load),
        .advance(count_advance), .cfg_last_stage(count_cfg),
        .stage_count(count_value), .last_stage(count_last), .cfg_valid(count_valid)
    );
    ntt_controller #(.N(N), .LANES(LANES)) controller (
        .clk(clk), .rst_n(rst_n), .a2b_cmd_opcode(6'b0),
        .a2b_profile_id(4'b0), .a2b_context_id(5'b0),
        .a2b_start(ctl_start), .a2b_abort(abort_req || scheduler_fault),
        .a2b_zeroize(zeroize), .ntt_enable(1'b1), .intt_mode(ctl_mode),
        .cfg_last_stage(ctl_last), .butterfly_done(1'b0), .stage_done(stage_done),
        .zeroize_done(ctl_zeroize_done), .b2a_ready(ctl_ready),
        .b2a_busy(ctl_busy), .b2a_done(ctl_done), .b2a_error_code(ctl_error),
        .ntt_active(ctl_active), .ntt_start(ctl_ntt_start),
        .stage_start(ctl_stage_start), .butterfly_enable(ctl_enable),
        .zeroize_req(ctl_zeroize), .transform_done(ctl_transform_done),
        .transform_abort(ctl_abort), .transform_intt(ctl_intt), .stage_count(ctl_stage)
    );
    butterfly_scheduler #(.N(N), .LANES(LANES)) dut (
        .clk(clk), .rst_n(rst_n),
        .stage_start(integrated ? ctl_stage_start : stage_start),
        .stage_count(integrated ? ctl_stage : stage_count),
        .stage_span_log2(stage_span_log2),
        .schedule_first_span_log2(schedule_first_span_log2),
        .schedule_span_descending(schedule_span_descending),
        .transform_intt(integrated ? ctl_intt : transform_intt),
        .butterfly_enable(integrated ? ctl_enable : butterfly_enable),
        .abort_req(abort_req), .zeroize(zeroize),
        .zeroize_req(integrated ? ctl_zeroize : zeroize_req),
        .batch_valid(batch_valid), .batch_ready(batch_ready),
        .lane_valid(lane_valid), .coeff_addr_a(coeff_addr_a), .coeff_addr_b(coeff_addr_b),
        .butterfly_index(butterfly_index), .batch_stage(batch_stage),
        .batch_span_log2(batch_span_log2), .batch_intt(batch_intt),
        .batch_retired(batch_retired), .backend_flushed(backend_flushed),
        .stage_done(stage_done), .scheduler_quiescent(scheduler_quiescent),
        .scheduler_fault(scheduler_fault)
    );

    task automatic check(input bit ok, input string why);
        if (!ok) $fatal(1, "N=%0d LANES=%0d: %s", N, LANES, why);
    endtask
    task automatic tick;
        @(posedge clk); #1;
    endtask
    function automatic logic [PW-1:0] payload();
        return {lane_valid,coeff_addr_a,coeff_addr_b,butterfly_index,
                batch_stage,batch_span_log2,batch_intt};
    endfunction
    task automatic reset_all;
        rst_n = 0;
        integrated = 0; stage_start = 0; transform_intt = 0; butterfly_enable = 0;
        stage_count = '0; stage_span_log2 = '0;
        schedule_first_span_log2 = '0; schedule_span_descending = 0;
        abort_req = 0; zeroize = 0; zeroize_req = 0;
        batch_ready = 0; batch_retired = 0; backend_flushed = 0;
        ctl_start = 0; ctl_zeroize_done = 0; ctl_mode = 0; ctl_last = SW'(SC-1);
        count_clear = 0; count_load = 0; count_advance = 0; count_cfg = SW'(SC-1);
        tick();
        check(!batch_valid && !stage_done && !scheduler_fault && count_value == 0,
              "reset outputs");
        @(negedge clk); rst_n = 1; #1;
        check(scheduler_quiescent, "idle after reset");
    endtask
    task automatic launch(input int span, input int ordinal, input bit inverse);
        stage_span_log2 = SW'(span); stage_count = SW'(ordinal);
        transform_intt = inverse; stage_start = 1; butterfly_enable = 0;
        tick(); stage_start = 0;
        check(!batch_valid, "execution enable required");
        butterfly_enable = 1; #1;
        check(batch_valid, "stage accepted");
    endtask
    assert property (@(posedge clk) disable iff (!rst_n)
        !batch_valid |-> (lane_valid == '0));

    task automatic accept_batch;
        batch_ready = 1; tick(); batch_ready = 0;
        check(!batch_valid && !stage_done && !scheduler_quiescent, "one outstanding batch");
    endtask
    task automatic service_stage(input int span, input int ordinal, input bit inverse);
        int expected_a [BF];
        int expected_b [BF];
        bit seen [N];
        int k, distance;
        logic [PW-1:0] saved;
        // Independent nested-block oracle, not the RTL's bit insertion formula.
        k = 0; distance = 2**span;
        for (int base = 0; base < N; base += 2*distance) begin
            for (int off = 0; off < distance; off++) begin
                expected_a[k] = base+off;
                expected_b[k] = base+off+distance;
                k++;
            end
        end
        for (int i = 0; i < N; i++) seen[i] = 0;
        for (int g = 0; g < GROUPS; g++) begin
            check(batch_valid && !stage_done && !scheduler_fault, "offer batch");
            check(batch_stage == SW'(ordinal) && batch_span_log2 == SW'(span) &&
                  batch_intt == inverse, "captured descriptor metadata");
            saved = payload();
            repeat (1+(g % 3)) begin
                tick();
                check(batch_valid && payload() === saved && !stage_done,
                      "stable descriptor under backpressure");
            end
            for (int lane = 0; lane < LANES; lane++) begin
                int i;
                i = g*LANES+lane;
                if (i < BF) begin
                    check(lane_valid[lane] && butterfly_index[lane] == BW'(i), "lane ordinal");
                    check(int'(coeff_addr_a[lane]) == expected_a[i] &&
                          int'(coeff_addr_b[lane]) == expected_b[i], "pair address oracle");
                    check(!seen[expected_a[i]] && !seen[expected_b[i]], "no coefficient repeats");
                    seen[expected_a[i]] = 1; seen[expected_b[i]] = 1;
                end else begin
                    check(!lane_valid[lane] && coeff_addr_a[lane] == 0 &&
                          coeff_addr_b[lane] == 0 && butterfly_index[lane] == 0,
                          "inactive lane deterministic");
                end
            end
            accept_batch();
            repeat (1+(g % 4)) begin
                tick();
                check(!batch_valid && !stage_done && !scheduler_quiescent,
                      "issue is not retirement");
            end
            batch_retired = 1; tick(); batch_retired = 0; #1;
            if (g != GROUPS-1) check(batch_valid && !stage_done, "advance batch only");
        end
        foreach (seen[i]) check(seen[i], "complete coefficient coverage");
        check(stage_done && scheduler_quiescent && !batch_valid, "retired stage done");
        tick();
        check(!stage_done && scheduler_quiescent, "one-cycle completion");
    endtask
    task automatic cancellation(input int kind, input bit value);
        case (kind)
            0: abort_req = value;
            1: zeroize = value;
            2: zeroize_req = value;
            default: $fatal(1, "bad test cancellation kind");
        endcase
        #1;
    endtask
    task automatic fault_recovery;
        check(scheduler_fault && !batch_valid && !stage_done && !scheduler_quiescent,
              "fault held until flush");
        batch_retired = 1; tick(); batch_retired = 0;
        check(scheduler_fault && !scheduler_quiescent, "retirement cannot clear protocol fault");
        zeroize_req = 1; backend_flushed = 1; tick();
        check(!scheduler_fault && scheduler_quiescent, "flush resolves fault");
        zeroize_req = 0; backend_flushed = 0;
    endtask

    assert property (@(posedge clk) disable iff (!rst_n)
        (abort_req || zeroize || zeroize_req) |-> (!batch_valid && !stage_done));
    assert property (@(posedge clk) disable iff (!rst_n)
        stage_done |-> (!batch_valid && scheduler_quiescent && !scheduler_fault));
    assert property (@(posedge clk) disable iff (!rst_n)
        (batch_valid && batch_ready) |=> !batch_valid);

    initial begin
        finished = 0;
        reset_all();
        // Counter load/advance/clear priorities, captured limit and saturation.
        for (int limit = 0; limit < SC; limit++) begin
            count_cfg = SW'(limit); count_load = 1; count_advance = 1; tick();
            count_load = 0; count_cfg = '0;
            check(count_value == 0 && count_last == (limit == 0), "load beats advance");
            for (int s = 1; s <= limit+3; s++) begin
                tick();
                check(count_value == SW'((s < limit) ? s : limit), "stage index/saturation");
                check(count_last == (s >= limit), "last-stage comparison");
            end
            count_clear = 1; count_load = 1; count_cfg = SW'(SC-1); tick();
            check(count_value == 0 && count_last, "clear beats load/advance");
            count_clear = 0; count_load = 0; count_advance = 0;
        end
        if ((2**SW) > SC) begin
            count_cfg = SW'(SC); count_load = 1; #1;
            check(!count_valid, "reject bad counter configuration");
            tick(); count_load = 0;
            check(count_value == 0 && count_last, "invalid load preserves state");
        end

        // Every legal span and direction, with independent coverage oracle.
        for (int mode = 0; mode < 2; mode++) begin
            for (int span = 0; span < SC; span++) begin
                reset_all(); launch(span, span, 1'(mode));
                stage_count = '0; stage_span_log2 = '0;
        schedule_first_span_log2 = '0; schedule_span_descending = 0; transform_intt = !1'(mode);
                service_stage(span, span, 1'(mode));
            end
        end
        for (int kind = 0; kind < 3; kind++) begin
            // Stalled offer cancellation never accepts work, even if ready rises.
            reset_all(); launch(0, 0, 0); batch_ready = 1;
            cancellation(kind, 1);
            check(!batch_valid && !stage_done, "cancel wins acceptance");
            tick(); batch_ready = 0; cancellation(kind, 0);
            check(scheduler_quiescent && !scheduler_fault, "cancel unaccepted offer");
            for (int method = 0; method < 3; method++) begin
                reset_all(); launch(0, 0, 0); accept_batch(); cancellation(kind, 1);
                if (method == 2) batch_retired = 1;
                tick(); batch_retired = 0; cancellation(kind, 0);
                if (method != 2) begin
                    repeat (3) begin
                        tick();
                        check(!scheduler_quiescent && !stage_done && !batch_valid,
                              "drain preserves outstanding accountability");
                    end
                    if (method == 0) batch_retired = 1;
                    else backend_flushed = 1;
                    tick(); batch_retired = 0; backend_flushed = 0; #1;
                end
                check(scheduler_quiescent && !stage_done && !scheduler_fault,
                      "canceled retirement/flush never succeeds");
            end
            // Race with final retirement and with the DONE output cycle.
            for (int race = 0; race < 2; race++) begin
                reset_all(); launch(0, 0, 0);
                for (int g = 0; g < GROUPS; g++) begin
                    accept_batch();
                    if ((g == GROUPS-1) && (race == 0)) cancellation(kind, 1);
                    batch_retired = 1; tick(); batch_retired = 0;
                end
                if (race == 1) cancellation(kind, 1);
                check(!stage_done, "cancellation beats stage completion");
                tick(); cancellation(kind, 0);
                check(scheduler_quiescent && !stage_done, "no delayed success");
            end
        end
        // Protocol errors are registered; a flush fence is mandatory for recovery.
        for (int kind = 0; kind < 4; kind++) begin
            reset_all(); launch(0, 0, 0);
            if (kind >= 2) accept_batch();
            case (kind)
                0, 2: stage_start = 1;
                1: batch_retired = 1;
                3: backend_flushed = 1;
            endcase
            tick(); stage_start = 0; batch_retired = 0; backend_flushed = 0;
            fault_recovery();
        end
        if ((2**SW) > SC) begin
            reset_all(); stage_span_log2 = SW'(SC); stage_start = 1;
            tick(); stage_start = 0; fault_recovery();
            reset_all(); stage_count = SW'(SC); stage_start = 1;
            tick(); stage_start = 0; fault_recovery();
        end
        if (SC > 1) begin
            reset_all(); stage_span_log2 = SW'(1); stage_start = 1;
            tick(); stage_start = 0; fault_recovery();
        end
        reset_all();
        /* verilator lint_off ENUMVALUE */
        force dut.state = 3'd7;
        /* verilator lint_on ENUMVALUE */
        #1; check(!batch_valid && !stage_done && !scheduler_quiescent, "illegal state closed");
        tick(); release dut.state; tick(); fault_recovery();

        // Reset with an outstanding batch and during drain. System reset also
        // invalidates the backend in this test; no stale responses are replayed.
        reset_all(); launch(0, 0, 0); accept_batch(); reset_all();
        launch(0, 0, 0); accept_batch(); abort_req = 1; tick(); reset_all();

        // Real controller-to-scheduler integration: full and shorter schedules.
        for (int mode = 0; mode < 2; mode++) begin
            for (int shortened = 0; shortened < 2; shortened++) begin
                int stages, span;
                stages = ((shortened != 0) && SC > 1) ? SC-1 : SC;
                reset_all(); integrated = 1; ctl_mode = 1'(mode); ctl_last = SW'(stages-1);
                schedule_first_span_log2 = SW'(mode != 0 ? SC-stages : SC-1);
                schedule_span_descending = (mode == 0);
                ctl_start = 1; tick(); ctl_start = 0;
                for (int s = 0; s < stages; s++) begin
                    tick(); check(ctl_stage_start && ctl_stage == SW'(s), "integrated stage progression");
                    span = (mode != 0) ? SC-stages+s : SC-1-s;
                    stage_span_log2 = SW'(span);
                    tick(); check(batch_valid && ctl_busy, "integrated stage acceptance");
                    service_stage(span, s, 1'(mode));
                end
                tick(); check(ctl_done && ctl_busy, "integrated transform completion");
                tick(); check(ctl_ready && !ctl_busy, "integrated return to idle");
            end
        end
        // Integrated abort waits for outstanding effects and controller clearing.
        reset_all(); integrated = 1; ctl_start = 1; tick(); ctl_start = 0;
        tick(); tick(); accept_batch(); abort_req = 1; tick(); abort_req = 0;
        tick(); check(ctl_zeroize && ctl_busy && !scheduler_quiescent, "integrated drain/zeroize");
        backend_flushed = 1; tick();
        check(scheduler_quiescent && !ctl_done && ctl_busy, "backend flush before controller release");
        ctl_zeroize_done = 1; tick(); ctl_zeroize_done = 0; backend_flushed = 0;
        check(ctl_ready && !ctl_done, "integrated cancellation complete");
        // Registered scheduler faults propagate through the existing controller
        // abort path without a stage_start/fault/abort combinational loop.
        reset_all(); integrated = 1; ctl_start = 1; tick(); ctl_start = 0;
        tick(); tick(); batch_retired = 1; tick(); batch_retired = 0;
        check(scheduler_fault && !stage_done, "integrated early-retirement fault");
        tick(); check(ctl_abort && ctl_busy, "fault reaches controller abort");
        tick(); check(ctl_zeroize && !ctl_done, "fault reaches zeroization");
        backend_flushed = 1; tick();
        check(!scheduler_fault && scheduler_quiescent, "integrated fault flush");
        ctl_zeroize_done = 1; tick(); ctl_zeroize_done = 0; backend_flushed = 0;
        check(ctl_ready && !ctl_done, "integrated fault recovery completes");
        $display("PASS scheduling N=%0d LANES=%0d", N, LANES);
        finished = 1;
    end
endmodule

module scheduling_tb;
    wire [23:0] finished;
    for (genvar n = 0; n < 6; n++) begin : g_n
        for (genvar l = 0; l < 4; l++) begin : g_l
            localparam int unsigned POINTS = (n < 3) ? (2 << n) : (256 << (n-3));
            scheduling_case #(.N(POINTS), .LANES(1 << l)) tc (.finished(finished[n*4+l]));
        end
    end
    initial begin
        wait (&finished);
        $display("PASS all 24 scheduling configurations and controller integration");
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "scheduling test timeout");
    end
endmodule
