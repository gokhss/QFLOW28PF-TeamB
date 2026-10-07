// Q-FLOW28-PF: inverse-only integration wrapper around the shared controller.
// Compile with ntt_controller.sv. Internal ports are PROPOSED interfaces.
// Use this INSTEAD OF the mode-configurable core for an inverse-only entry.
// Instantiating this wrapper and another ntt_controller creates TWO FSMs;
// the shared fabric should normally instantiate one runtime-mode core.
module intt_controller #(
    parameter int unsigned N = 256,
    parameter int unsigned LANES = 1,
    localparam int unsigned STAGE_COUNT = $clog2(N),
    localparam int unsigned STAGE_W =
        (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT)
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
    ntt_controller #(.N(N), .LANES(LANES)) u_shared_controller (
        .clk(clk),
        .rst_n(rst_n),
        .a2b_cmd_opcode(a2b_cmd_opcode),
        .a2b_profile_id(a2b_profile_id),
        .a2b_context_id(a2b_context_id),
        .a2b_start(a2b_start),
        .a2b_abort(a2b_abort),
        .a2b_zeroize(a2b_zeroize),
        .ntt_enable(ntt_enable),
        .intt_mode(1'b1),
        .cfg_last_stage(cfg_last_stage),
        .butterfly_done(butterfly_done),
        .stage_done(stage_done),
        .zeroize_done(zeroize_done),
        .b2a_ready(b2a_ready),
        .b2a_busy(b2a_busy),
        .b2a_done(b2a_done),
        .b2a_error_code(b2a_error_code),
        .ntt_active(ntt_active),
        .ntt_start(ntt_start),
        .stage_start(stage_start),
        .butterfly_enable(butterfly_enable),
        .zeroize_req(zeroize_req),
        .transform_done(transform_done),
        .transform_abort(transform_abort),
        .controller_fault(controller_fault),
        .transform_intt(transform_intt),
        .stage_count(stage_count)
    );
endmodule
