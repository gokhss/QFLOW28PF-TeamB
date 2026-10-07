// Q-FLOW28-PF: one shared forward/inverse transform controller.
// All ports except clk/rst_n and a2b_*/b2a_* are PROPOSED INTERNAL INTERFACES.
// Instantiate this module ONCE with runtime intt_mode for shared NTT/INTT.
// No arithmetic, coefficient memory, or lane scheduler is implemented here.
//
// Contract for the downstream integration:
// - Inputs are synchronous to clk; rst_n is asynchronously asserted and
//   synchronously deasserted by the reset distribution logic.
// - Acceptance is a2b_start && b2a_ready at a rising edge. Configuration is
//   captured there. cfg_last_stage = STAGE_COUNT-1 selects the full schedule.
// - LOAD is one initialization cycle, NOT a coefficient-load handshake.
// - Every stage_start pulse is accepted at its rising edge (no backpressure).
// - butterfly_enable authorizes scheduler execution; it is NOT a datapath
//   clock or write-enable. Work committed on the cancellation edge may finish.
// - stage_done is meaningful only in BUTTERFLY and means all stage work and
//   coefficient writes have retired. Clear it before the next stage executes.
// - zeroize_done is asserted only in response to zeroize_req, after all owned
//   state is scrubbed and old writes can no longer repopulate that state.
//   Hold the acknowledgement until zeroize_req drops; deassert it otherwise.
// - Faults must be routed through abort/zeroize by the fabric. This module
//   cannot suppress completion for a fault it has not been told about.
// - b2a_* describe this local operation. The fabric must aggregate them; a
//   single transform is not necessarily a complete Team-A crypto command.

module ntt_controller #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned STAGE_COUNT = $clog2(N),
    localparam int unsigned STAGE_W = (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [5:0] a2b_cmd_opcode,
    input  logic [3:0] a2b_profile_id,
    input  logic [4:0] a2b_context_id,
    input  logic a2b_start,
    input  logic a2b_abort,
    input  logic a2b_zeroize,

    input  logic ntt_enable,
    input  logic intt_mode,
    input  logic [STAGE_W-1:0] cfg_last_stage,
    input  logic butterfly_done,
    input  logic stage_done,
    input  logic zeroize_done,

    output logic b2a_ready,
    output logic b2a_busy,
    output logic b2a_done,
    output logic [15:0] b2a_error_code,
    output logic ntt_active,
    output logic ntt_start,
    output logic stage_start,
    output logic butterfly_enable,
    output logic zeroize_req,
    output logic transform_done,
    output logic transform_abort,
    output logic controller_fault, // PROPOSED: illegal controller encoding
    output logic transform_intt,
    output logic [STAGE_W-1:0] stage_count
);

    // Constant-folded build checks; no simulation-only constructs in the RTL.
    // Invalid builds never accept work. Verification must reject such builds.
    localparam bit LANES_VALID =
        ((LANES == 1) || (LANES == 2) || (LANES == 4) || (LANES == 8));

    typedef enum logic [3:0] {
        S_IDLE        = 4'd0,
        S_LOAD        = 4'd1,
        S_STAGE_START = 4'd2,
        S_BUTTERFLY   = 4'd3,
        S_STAGE_WAIT  = 4'd4,
        S_COMPLETE    = 4'd5,
        S_ABORT       = 4'd6,
        S_ZEROIZE     = 4'd7
    } state_t;

    state_t state, next_state;
    logic intt_mode_q;
    logic accept_start, cancel, last_stage, cfg_valid;
    logic stage_clear, stage_advance;

    // Exactly one stage owner. The controller only generates lifecycle events.
    stage_counter #(.N(N)) u_stage_counter (
        .clk(clk), .rst_n(rst_n), .clear(stage_clear),
        .load(accept_start), .advance(stage_advance),
        .cfg_last_stage(cfg_last_stage), .stage_count(stage_count),
        .last_stage(last_stage), .cfg_valid(cfg_valid)
    );

    // State-only fault decode is independent of abort and command outputs.
    always_comb begin
        controller_fault = 1'b0;
        case (state)
            S_IDLE, S_LOAD, S_STAGE_START, S_BUTTERFLY,
            S_STAGE_WAIT, S_COMPLETE, S_ABORT, S_ZEROIZE: begin end
            default: controller_fault = rst_n;
        endcase
    end

    // Metadata stays in the fabric/profile/context layer. butterfly_done is
    // reserved for scheduler integration: stage_done is the retirement event
    // consumed here. These inputs deliberately have no dummy "use" logic:
    // a2b_cmd_opcode, a2b_profile_id, a2b_context_id, butterfly_done.
    always_comb begin
        cancel       = a2b_zeroize || a2b_abort;
        accept_start = a2b_start && b2a_ready;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (accept_start)
                    next_state = S_LOAD;
            end
            S_LOAD:        next_state = S_STAGE_START;
            S_STAGE_START: next_state = S_BUTTERFLY;
            S_BUTTERFLY: begin
                if (stage_done)
                    next_state = S_STAGE_WAIT;
            end
            S_STAGE_WAIT: begin
                if (last_stage)
                    next_state = S_COMPLETE;
                else
                    next_state = S_STAGE_START;
            end
            S_COMPLETE: next_state = S_IDLE;
            S_ABORT:    next_state = S_ZEROIZE;
            S_ZEROIZE: begin
                if (zeroize_done)
                    next_state = S_IDLE;
            end
            default: next_state = S_ZEROIZE;
        endcase

        // Synchronous state transitions. A new zeroize request also prevents
        // exit from ZEROIZE even if its acknowledgement is already asserted.
        if (a2b_zeroize) begin
            next_state = S_ZEROIZE;
        end else if (a2b_abort) begin
            case (state)
                S_LOAD, S_STAGE_START, S_BUTTERFLY,
                S_STAGE_WAIT, S_COMPLETE: next_state = S_ABORT;
                S_IDLE, S_ABORT, S_ZEROIZE: begin end
                default: next_state = S_ZEROIZE;
            endcase
        end
    end

    always_comb begin
        stage_clear = 1'b0;
        stage_advance = 1'b0;
        case (state)
            S_STAGE_WAIT: stage_advance = (next_state == S_STAGE_START);
            S_COMPLETE, S_ABORT, S_ZEROIZE: stage_clear = 1'b1;
            S_IDLE, S_LOAD, S_STAGE_START, S_BUTTERFLY: begin end
            default: stage_clear = 1'b1;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            intt_mode_q <= 1'b0;
        else if (stage_clear)
            intt_mode_q <= 1'b0;
        else if (accept_start)
            intt_mode_q <= intt_mode;
    end

    always_comb begin
        b2a_ready        = 1'b0;
        b2a_busy         = 1'b0;
        b2a_done         = 1'b0;
        // No error namespace is selected here. Abort/zeroize have no success
        // pulse; fabric owns their error reporting and invalidation status.
        b2a_error_code   = 16'h0000;
        ntt_active       = 1'b0;
        ntt_start        = 1'b0;
        stage_start      = 1'b0;
        butterfly_enable = 1'b0;
        zeroize_req      = 1'b0;
        transform_done   = 1'b0;
        transform_abort  = 1'b0;
        transform_intt   = intt_mode_q;

        if (rst_n) begin
            case (state)
                S_IDLE: begin
                    b2a_ready = LANES_VALID && ntt_enable && !cancel && cfg_valid;
                end
                S_LOAD: begin
                    b2a_busy  = 1'b1;
                    ntt_active = 1'b1;
                    ntt_start = !cancel;
                end
                S_STAGE_START: begin
                    b2a_busy   = 1'b1;
                    ntt_active = 1'b1;
                    stage_start = !cancel;
                end
                S_BUTTERFLY: begin
                    b2a_busy         = 1'b1;
                    ntt_active       = 1'b1;
                    butterfly_enable = 1'b1;
                end
                S_STAGE_WAIT: begin
                    b2a_busy   = 1'b1;
                    ntt_active = 1'b1;
                end
                S_COMPLETE: begin
                    // Ownership lasts through the result-retirement edge.
                    // Qualify success itself, not just the following state.
                    b2a_busy       = 1'b1;
                    b2a_done       = !cancel;
                    transform_done = !cancel;
                end
                S_ABORT: begin
                    b2a_busy       = 1'b1;
                    transform_abort = 1'b1;
                end
                S_ZEROIZE: begin
                    b2a_busy   = 1'b1;
                    zeroize_req = 1'b1;
                end
                default: begin
                    // Fail closed for unused encodings. Gate-level recovery
                    // still requires synthesis FSM-recoding review.
                    b2a_busy        = 1'b1;
                    transform_abort = 1'b1;
                end
            endcase
        end
    end
endmodule
