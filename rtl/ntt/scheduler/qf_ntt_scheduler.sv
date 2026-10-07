`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// qf_ntt_scheduler.sv
//
// Q-FLOW28-PF Team-B standalone single-lane NTT read/write scheduler.
//
// Fixed architecture for this isolated verification phase:
//   N                    = 256 coefficients
//   butterflies/stage    = 128
//   stages               = 8
//   coefficient address  = 8 bits
//   butterfly index      = 7 bits
//   writeback pipeline   = 2 cycles
//
// Pair progression:
//   Forward CT: stride = 1 << stage_count
//   Inverse GS: stride = 1 << (7 - stage_count)
//
// Synchronous abort semantics:
//   abort_i is sampled on the active clock edge.  The butterfly already
//   presented by rd_en at that edge is considered committed and enters the
//   two-cycle writeback pipeline.  After that edge, no further rd_en dispatch
//   occurs.  Already-committed writebacks drain normally.  stage_done is
//   suppressed for an aborted stage.
//
// This standalone scheduler contains no zeroize datapath.  scheduler_busy
// deassertion after the abort drain is the handoff point at which a separate
// zeroize block/FSM may safely scrub state.
// ============================================================================

module qf_ntt_scheduler (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       stage_start,
    input  logic       butterfly_enable,
    input  logic       transform_intt,
    input  logic [2:0] stage_count,
    input  logic       abort_i,

    output logic       rd_en,
    output logic [7:0] rd_addr_u,
    output logic [7:0] rd_addr_v,
    output logic [6:0] bf_index,

    output logic       wr_en,
    output logic [7:0] wr_addr_u,
    output logic [7:0] wr_addr_v,

    output logic       butterfly_done,
    output logic       stage_done,
    output logic       scheduler_busy
);

    localparam int unsigned PIPELINE_LATENCY = 2;

    logic       active_q;
    logic       abort_q;
    logic       issuing_done_q;
    logic       mode_q;
    logic [2:0] stage_q;
    logic [6:0] bf_index_q;

    logic [2:0] pair_shift;
    logic [3:0] pair_shift_plus_one;
    logic [7:0] distance;
    logic [7:0] bf_ext;
    logic [7:0] offset;
    logic [7:0] group_index;
    logic [7:0] calc_addr_u;
    logic [7:0] calc_addr_v;

    logic [PIPELINE_LATENCY-1:0] valid_pipe_q;
    logic [PIPELINE_LATENCY-1:0] last_pipe_q;
    logic [7:0] addr_u_pipe_q [0:PIPELINE_LATENCY-1];
    logic [7:0] addr_v_pipe_q [0:PIPELINE_LATENCY-1];

    logic pipe_after_shift_any;

    assign scheduler_busy = active_q;
    assign bf_index       = bf_index_q;

    // Abort is deliberately not a combinational term in rd_en.  abort_i is
    // synchronous: the operation committed on the sampling edge completes.
    // abort_q blocks all dispatch immediately after that edge.
    assign rd_en =
        active_q &&
        butterfly_enable &&
        !issuing_done_q &&
        !abort_q;

    assign rd_addr_u = calc_addr_u;
    assign rd_addr_v = calc_addr_v;

    assign wr_en     = valid_pipe_q[PIPELINE_LATENCY-1];
    assign wr_addr_u = addr_u_pipe_q[PIPELINE_LATENCY-1];
    assign wr_addr_v = addr_v_pipe_q[PIPELINE_LATENCY-1];

    assign butterfly_done = wr_en;

    // Fault/abort has priority over normal stage completion.
    assign stage_done =
        wr_en &&
        last_pipe_q[PIPELINE_LATENCY-1] &&
        !abort_q &&
        !abort_i;

    always_comb begin
        if (!mode_q) begin
            pair_shift = stage_q;
        end else begin
            pair_shift = 3'd7 - stage_q;
        end

        pair_shift_plus_one = {1'b0, pair_shift} + 4'd1;
        distance            = 8'd1 << pair_shift;
        bf_ext              = {1'b0, bf_index_q};
        offset              = bf_ext & (distance - 8'd1);
        group_index         = bf_ext >> pair_shift;

        calc_addr_u =
            (group_index << pair_shift_plus_one) |
            offset;

        calc_addr_v =
            calc_addr_u |
            distance;
    end

    // Occupancy that will remain after the next pipeline shift.  The final
    // writeback stage is consumed at the current edge and is intentionally
    // excluded from this expression.
    always_comb begin
        pipe_after_shift_any = rd_en;

        for (int unsigned p = 0;
             p < (PIPELINE_LATENCY - 1);
             p++) begin
            pipe_after_shift_any =
                pipe_after_shift_any |
                valid_pipe_q[p];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q       <= 1'b0;
            abort_q        <= 1'b0;
            issuing_done_q <= 1'b0;
            mode_q         <= 1'b0;
            stage_q        <= 3'b0;
            bf_index_q     <= 7'b0;
            valid_pipe_q   <= '0;
            last_pipe_q    <= '0;

            for (int unsigned p = 0;
                 p < PIPELINE_LATENCY;
                 p++) begin
                addr_u_pipe_q[p] <= 8'b0;
                addr_v_pipe_q[p] <= 8'b0;
            end
        end else begin
            // Fixed two-cycle writeback pipeline shifts every cycle.
            valid_pipe_q[1] <= valid_pipe_q[0];
            last_pipe_q[1]  <= last_pipe_q[0];
            addr_u_pipe_q[1] <= addr_u_pipe_q[0];
            addr_v_pipe_q[1] <= addr_v_pipe_q[0];

            valid_pipe_q[0] <= rd_en;
            last_pipe_q[0]  <= rd_en && (bf_index_q == 7'd127);

            if (rd_en) begin
                addr_u_pipe_q[0] <= calc_addr_u;
                addr_v_pipe_q[0] <= calc_addr_v;
            end

            if (!active_q) begin
                abort_q        <= 1'b0;
                issuing_done_q <= 1'b0;
                bf_index_q     <= 7'b0;

                if (stage_start && !abort_i) begin
                    active_q   <= 1'b1;
                    mode_q     <= transform_intt;
                    stage_q    <= stage_count;
                    bf_index_q <= 7'b0;
                end
            end else begin
                // OPEN-TEAMB-003 synchronous abort sampling.
                if (abort_i) begin
                    abort_q        <= 1'b1;
                    issuing_done_q <= 1'b1;
                end else if (!abort_q && rd_en) begin
                    if (bf_index_q == 7'd127) begin
                        issuing_done_q <= 1'b1;
                    end else begin
                        bf_index_q <= bf_index_q + 7'd1;
                    end
                end

                // Abort drain takes priority over normal stage completion.
                if ((abort_q || abort_i) &&
                    !pipe_after_shift_any) begin
                    // The final committed write has been consumed at this
                    // edge.  Clear scheduler-resident pipeline metadata before
                    // handing the block back to a separate zeroize controller.
                    active_q       <= 1'b0;
                    abort_q        <= 1'b0;
                    issuing_done_q <= 1'b0;
                    mode_q         <= 1'b0;
                    stage_q        <= 3'b0;
                    bf_index_q     <= 7'b0;
                    valid_pipe_q   <= '0;
                    last_pipe_q    <= '0;
                    addr_u_pipe_q[0] <= 8'b0;
                    addr_u_pipe_q[1] <= 8'b0;
                    addr_v_pipe_q[0] <= 8'b0;
                    addr_v_pipe_q[1] <= 8'b0;
                end else if (stage_done) begin
                    // Normal stage retirement also removes stale scheduler
                    // metadata after the final writeback edge.
                    active_q       <= 1'b0;
                    abort_q        <= 1'b0;
                    issuing_done_q <= 1'b0;
                    mode_q         <= 1'b0;
                    stage_q        <= 3'b0;
                    bf_index_q     <= 7'b0;
                    valid_pipe_q   <= '0;
                    last_pipe_q    <= '0;
                    addr_u_pipe_q[0] <= 8'b0;
                    addr_u_pipe_q[1] <= 8'b0;
                    addr_v_pipe_q[0] <= 8'b0;
                    addr_v_pipe_q[1] <= 8'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
