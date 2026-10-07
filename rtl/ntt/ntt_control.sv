// Shared control integration, instantiated ONCE beneath the Crypto Fabric.
// ALL ports are PROPOSED INTERNAL interfaces. No Team-A command decoding here.
// The existing ntt_controller has legacy a2b/b2a port names; those names below
// are local adapter connections, NOT another Team-A transaction boundary.
//
// cfg_first_span_log2 +/- stage_count defines the distance exponent. The
// profile layer selects schedule and direction independently, before start.
// ecc_uncorrectable MUST be qualified by ownership of the consuming memory
// beat (c2b_ecc_status[1]); never connect an unqualified/stale bus status.
// Fault status is sticky until the next accepted operation or reset. It is
// named status, NOT an encoding of the still-proposed 16-bit error namespace.
// scrub_done certifies scrubbing of ALL owned coefficient/PAU/backend state;
// backend_flushed separately fences old writes/responses. Neither may depend
// on ready. No memory, twiddle or arithmetic implementation is present here.
module ntt_control #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned SC = $clog2(N),
    localparam int unsigned SW = (SC <= 1) ? 1 : $clog2(SC),
    localparam int unsigned AW = (N <= 2) ? 1 : $clog2(N),
    localparam int unsigned BF = (N >= 2) ? N/2 : 1,
    localparam int unsigned BW = (BF <= 1) ? 1 : $clog2(BF)
) (
    input logic clk, rst_n,
    input logic start, enable, intt_mode,
    input logic [SW-1:0] cfg_last_stage, cfg_first_span_log2,
    input logic cfg_span_descending,
    input logic abort_req, zeroize,
    input logic ecc_uncorrectable, datapath_fault,
    input logic scrub_done, backend_flushed,
    output logic ready, busy, done, zeroize_req,
    output logic active, load_start, stage_start, butterfly_enable,
    output logic transform_abort, transform_intt,
    output logic [SW-1:0] stage_count,
    output logic batch_valid,
    input logic batch_ready,
    output logic [LANES-1:0] lane_valid,
    output logic [LANES-1:0][AW-1:0] coeff_addr_a, coeff_addr_b,
    output logic [LANES-1:0][BW-1:0] butterfly_index,
    output logic [SW-1:0] batch_stage, batch_span_log2,
    output logic batch_intt,
    input logic batch_retired,
    output logic stage_done, scheduler_quiescent,
    output logic error_config, error_ecc, error_datapath,
    output logic error_scheduler, error_controller
);
    localparam logic [SW:0] MAX_SPAN = (SW+1)'((SC > 0) ? SC-1 : 0);
    logic [SW-1:0] first_span_q, span;
    logic descending_q;
    logic [SW:0] final_span;
    logic range_valid, config_valid, scheduler_fault, controller_fault;
    logic fault, cancel, clear_done, accept_start, reject_config;

    generate
        if (SC == (2**SW)) begin : g_full_range
            always_comb range_valid = 1'b1;
        end else begin : g_partial_range
            always_comb range_valid = ({1'b0, cfg_last_stage} <= MAX_SPAN) &&
                ({1'b0, cfg_first_span_log2} <= MAX_SPAN);
        end
    endgenerate
    always_comb begin
        if (cfg_span_descending)
            final_span = {1'b0, cfg_first_span_log2} - {1'b0, cfg_last_stage};
        else
            final_span = {1'b0, cfg_first_span_log2} + {1'b0, cfg_last_stage};
        config_valid = range_valid && (final_span <= MAX_SPAN);
        if (descending_q) span = first_span_q - stage_count;
        else span = first_span_q + stage_count;
    end
    always_comb fault = ecc_uncorrectable || datapath_fault || scheduler_fault || controller_fault;
    always_comb cancel = abort_req || fault;
    always_comb accept_start = start && ready;
    always_comb reject_config = rst_n && start && enable && !busy &&
                               !zeroize && !cancel && !config_valid;
    always_comb clear_done = scrub_done && scheduler_quiescent && !fault;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_span_q <= '0;
            descending_q <= 1'b0;
            error_config <= 1'b0;
            error_ecc <= 1'b0;
            error_datapath <= 1'b0;
            error_scheduler <= 1'b0;
            error_controller <= 1'b0;
        end else begin
            if (accept_start) begin
                first_span_q <= cfg_first_span_log2;
                descending_q <= cfg_span_descending;
                error_config <= 1'b0;
                error_ecc <= 1'b0;
                error_datapath <= 1'b0;
                error_scheduler <= 1'b0;
                error_controller <= 1'b0;
            end else if (zeroize_req) begin
                first_span_q <= '0;
                descending_q <= 1'b0;
            end
            if (reject_config) error_config <= 1'b1;
            if (ecc_uncorrectable) error_ecc <= 1'b1;
            if (datapath_fault) error_datapath <= 1'b1;
            if (scheduler_fault) error_scheduler <= 1'b1;
            if (controller_fault) error_controller <= 1'b1;
        end
    end

    // Explicit empty outputs: legacy encoded error is NOT the Fabric error;
    // done already equals transform_done. Metadata is owned by the Fabric.
    /* verilator lint_off PINCONNECTEMPTY */
    ntt_controller #(.N(N), .LANES(LANES)) u_controller (
        .clk(clk), .rst_n(rst_n),
        .a2b_cmd_opcode(6'd0), .a2b_profile_id(4'd0), .a2b_context_id(5'd0),
        .a2b_start(start), .a2b_abort(cancel),
        .a2b_zeroize(zeroize),
        .ntt_enable(enable && config_valid && scheduler_quiescent && !backend_flushed),
        .intt_mode(intt_mode), .cfg_last_stage(cfg_last_stage),
        .butterfly_done(1'b0), .stage_done(stage_done), .zeroize_done(clear_done),
        .b2a_ready(ready), .b2a_busy(busy), .b2a_done(done), .b2a_error_code(),
        .ntt_active(active), .ntt_start(load_start), .stage_start(stage_start),
        .butterfly_enable(butterfly_enable), .zeroize_req(zeroize_req),
        .transform_done(), .transform_abort(transform_abort),
        .controller_fault(controller_fault), .transform_intt(transform_intt),
        .stage_count(stage_count)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    butterfly_scheduler #(.N(N), .LANES(LANES)) u_scheduler (
        .clk(clk), .rst_n(rst_n), .stage_start(stage_start),
        .stage_count(stage_count), .stage_span_log2(span),
        .schedule_first_span_log2(first_span_q), .schedule_span_descending(descending_q),
        .transform_intt(transform_intt), .butterfly_enable(butterfly_enable),
        .abort_req(cancel), .zeroize(zeroize), .zeroize_req(zeroize_req),
        .batch_valid(batch_valid), .batch_ready(batch_ready), .lane_valid(lane_valid),
        .coeff_addr_a(coeff_addr_a), .coeff_addr_b(coeff_addr_b),
        .butterfly_index(butterfly_index), .batch_stage(batch_stage),
        .batch_span_log2(batch_span_log2), .batch_intt(batch_intt),
        .batch_retired(batch_retired), .backend_flushed(backend_flushed),
        .stage_done(stage_done), .scheduler_quiescent(scheduler_quiescent),
        .scheduler_fault(scheduler_fault)
    );
endmodule
