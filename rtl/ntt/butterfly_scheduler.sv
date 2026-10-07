// Q-FLOW28-PF: lane-batched logical radix-2 scheduling, no arithmetic/memory.
// Every port is a PROPOSED INTERNAL INTERFACE, not a frozen team contract.
// Legal builds: power-of-two N >= 2, LANES in {1,2,4,8}.
//
// Stage command: stage_start is accepted only in IDLE, with cancellation low.
// Capture stage ordinal, span exponent and direction on that edge. The profile
// layer supplies span; this block does not decode algorithm IDs or twiddles.
// butterfly_enable must stay high during execution until done or cancellation.
//
// Batch command: batch_valid && batch_ready transfers ALL active lane entries
// atomically. This is a work descriptor, NOT a PAU start or memory write pulse.
// The backend handles reads, twiddles, PAU launch, results and write retirement.
// Exactly one batch may be outstanding. batch_retired is a one-cycle response
// at least one edge AFTER acceptance, after ALL lane writes have retired.
//
// Cancellation is synchronous, shared by sender and receiver. It overrides
// acceptance even for a stalled valid descriptor. Previously accepted work can
// retire normally or be invalidated by the backend's coordinated zeroization.
// backend_flushed certifies no old work can write or return a stale response.
// It must NOT depend on scheduler_quiescent (that would create a deadlock).
// scheduler_quiescent can contribute to the controller's global zeroize_done.
// No secret data, zeroization engine, memory arbitration, or twiddle ROM here.
module butterfly_scheduler #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned STAGE_COUNT = $clog2(N),
    localparam int unsigned STAGE_W =
        (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT),
    localparam int unsigned ADDR_W = (N <= 2) ? 1 : $clog2(N),
    localparam int unsigned BUTTERFLIES = (N >= 2) ? N / 2 : 1,
    localparam int unsigned BF_W =
        (BUTTERFLIES <= 1) ? 1 : $clog2(BUTTERFLIES)
) (
    input logic clk,
    input logic rst_n,
    input logic stage_start,
    input logic [STAGE_W-1:0] stage_count,
    input logic [STAGE_W-1:0] stage_span_log2,
    // PROPOSED: public schedule configuration, held for the transform.
    input logic [STAGE_W-1:0] schedule_first_span_log2,
    input logic schedule_span_descending,
    input logic transform_intt,
    input logic butterfly_enable,
    input logic abort_req,
    input logic zeroize,
    input logic zeroize_req,

    output logic batch_valid,
    input  logic batch_ready,
    output logic [LANES-1:0] lane_valid,
    output logic [LANES-1:0][ADDR_W-1:0] coeff_addr_a,
    output logic [LANES-1:0][ADDR_W-1:0] coeff_addr_b,
    output logic [LANES-1:0][BF_W-1:0] butterfly_index,
    output logic [STAGE_W-1:0] batch_stage,
    output logic [STAGE_W-1:0] batch_span_log2,
    output logic batch_intt,
    input  logic batch_retired,
    input  logic backend_flushed,

    output logic stage_done,
    output logic scheduler_quiescent,
    output logic scheduler_fault
);
    localparam int unsigned SAFE_LANES = (LANES > 0) ? LANES : 1;
    localparam int unsigned BATCHES =
        (BUTTERFLIES + SAFE_LANES - 1) / SAFE_LANES;
    localparam int unsigned BATCH_W = (BATCHES <= 1) ? 1 : $clog2(BATCHES);
    localparam int unsigned LANE_SHIFT = $clog2(SAFE_LANES);
    localparam logic [BATCH_W-1:0] LAST_BATCH = BATCH_W'(BATCHES - 1);
    localparam logic [STAGE_W-1:0] MAX_STAGE =
        STAGE_W'((STAGE_COUNT > 0) ? STAGE_COUNT - 1 : 0);
    localparam bit PARAMS_VALID =
        (N >= 2) && ((N & (N - 32'd1)) == 0) &&
        ((LANES == 1) || (LANES == 2) || (LANES == 4) || (LANES == 8));

    typedef enum logic [2:0] {
        S_IDLE        = 3'd0,
        S_OFFER       = 3'd1,
        S_WAIT_RETIRE = 3'd2,
        S_DONE        = 3'd3,
        S_DRAIN       = 3'd4
    } state_t;
    state_t state, next_state;
    logic [BATCH_W-1:0] batch_index_q;
    logic [STAGE_W-1:0] stage_q, span_q;
    logic intt_q, fault_q;
    logic cancel, config_valid, fault_event, accept_stage;
    logic [ADDR_W-1:0] low_mask, distance_mask;

    logic [STAGE_W:0] expected_span;
    logic range_valid;
    generate
        if (MAX_STAGE == {STAGE_W{1'b1}}) begin : g_full_range
            always_comb range_valid = 1'b1;
        end else begin : g_partial_range
            always_comb range_valid = (stage_count <= MAX_STAGE) &&
                (schedule_first_span_log2 <= MAX_STAGE);
        end
    endgenerate
    always_comb begin
        // Widen before arithmetic: an underflow/overflow must not wrap into
        // a legal exponent. Stage ordinal is execution order, not distance.
        if (schedule_span_descending)
            expected_span = {1'b0, schedule_first_span_log2} - {1'b0, stage_count};
        else
            expected_span = {1'b0, schedule_first_span_log2} + {1'b0, stage_count};
        config_valid = PARAMS_VALID && range_valid &&
            (expected_span <= {1'b0, MAX_STAGE}) &&
            (expected_span == {1'b0, stage_span_log2});
    end

    always_comb begin
        cancel = abort_req || zeroize || zeroize_req;
        fault_event = 1'b0;
        case (state)
            S_IDLE, S_OFFER, S_WAIT_RETIRE, S_DONE: begin
                if (!cancel) begin
                    if (stage_start && ((state != S_IDLE) || !config_valid))
                        fault_event = 1'b1;
                    if (batch_retired && (state != S_WAIT_RETIRE))
                        fault_event = 1'b1;
                    if (backend_flushed && (state != S_IDLE))
                        fault_event = 1'b1;
                    // Do not reuse the backend before its flush fence releases.
                    if (stage_start && backend_flushed)
                        fault_event = 1'b1;
                end
            end
            S_DRAIN: begin end
            default: fault_event = 1'b1;
        endcase
        accept_stage = rst_n && (state == S_IDLE) && stage_start &&
                       !cancel && !fault_event && !fault_q;
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (accept_stage) next_state = S_OFFER;
            end
            S_OFFER: begin
                if (cancel) next_state = S_IDLE;
                else if (batch_valid && batch_ready) next_state = S_WAIT_RETIRE;
            end
            S_WAIT_RETIRE: begin
                if (cancel) begin
                    if (batch_retired || backend_flushed) next_state = S_IDLE;
                    else next_state = S_DRAIN;
                end else if (batch_retired) begin
                    if (batch_index_q == LAST_BATCH) next_state = S_DONE;
                    else next_state = S_OFFER;
                end
            end
            S_DONE: next_state = S_IDLE;
            S_DRAIN: begin
                // Protocol/illegal-state faults require a backend flush fence;
                // ordinary cancellation may also resolve by normal retirement.
                if (backend_flushed || (batch_retired && !fault_q))
                    next_state = S_IDLE;
            end
            default: next_state = S_DRAIN;
        endcase
        if (fault_event) next_state = S_DRAIN;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            batch_index_q <= '0;
            stage_q       <= '0;
            span_q        <= '0;
            intt_q        <= 1'b0;
            fault_q       <= 1'b0;
        end else begin
            state <= next_state;
            // Registered reporting avoids a loop through controller abort ->
            // stage_start -> fault detection -> controller abort.
            if (fault_event) fault_q <= 1'b1;
            else if ((state == S_DRAIN) && backend_flushed) fault_q <= 1'b0;

            if (accept_stage) begin
                batch_index_q <= '0;
                stage_q       <= stage_count;
                span_q        <= stage_span_log2;
                intt_q        <= transform_intt;
            end else if (next_state == S_IDLE) begin
                batch_index_q <= '0;
                stage_q       <= '0;
                span_q        <= '0;
                intt_q        <= 1'b0;
            end else if ((state == S_WAIT_RETIRE) && (next_state == S_OFFER)) begin
                batch_index_q <= batch_index_q + BATCH_W'(1);
            end
        end
    end

    always_comb begin
        batch_valid = 1'b0;
        stage_done = 1'b0;
        scheduler_quiescent = 1'b0;
        scheduler_fault = fault_q;
        batch_stage = stage_q;
        batch_span_log2 = span_q;
        batch_intt = intt_q;
        distance_mask = ADDR_W'(1) << span_q;
        low_mask = distance_mask - ADDR_W'(1);
        if (rst_n && !fault_q && !fault_event) begin
            case (state)
                S_IDLE: scheduler_quiescent = 1'b1;
                S_OFFER: batch_valid = butterfly_enable && !cancel;
                S_WAIT_RETIRE: begin end
                S_DONE: begin
                    stage_done = !cancel;
                    scheduler_quiescent = 1'b1;
                end
                S_DRAIN: begin end
                default: begin end
            endcase
        end
    end

    // Insert a zero at span_q in ordinal i to obtain A; set that bit for B.
    // Stage-varying logic is a mask; the shift of the high portion is fixed.
    // These are LOGICAL coefficient indices, not SRAM bank/port addresses.
    always_comb begin : decode_lanes
        logic [ADDR_W-1:0] ordinal;
        ordinal = '0;
        lane_valid = '0;
        butterfly_index = '0;
        coeff_addr_a = '0;
        coeff_addr_b = '0;
        for (int unsigned lane = 0; lane < LANES; lane++) begin
            if (lane < BUTTERFLIES) begin
                ordinal = (ADDR_W'(batch_index_q) << LANE_SHIFT) | ADDR_W'(lane);
                // Descriptor mask is valid ONLY with the offer. Backend must
                // capture all fields at batch_valid && batch_ready.
                lane_valid[lane] = batch_valid;
                butterfly_index[lane] = BF_W'(ordinal);
                coeff_addr_a[lane] = ((ordinal & ~low_mask) << 1) |
                                      (ordinal & low_mask);
                coeff_addr_b[lane] = coeff_addr_a[lane] | distance_mask;
            end
        end
    end
endmodule
