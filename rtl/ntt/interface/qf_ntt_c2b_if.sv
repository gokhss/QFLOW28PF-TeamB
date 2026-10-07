`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// qf_ntt_c2b_if.sv
//
// Q-FLOW28-PF Team-B <-> Team-C Secure Scratchpad interface.
//
// COMMON boundary:
//   B2C:
//     b2c_valid
//     b2c_context_id[4:0]
//     b2c_region_tag[1:0]
//
//   C2B:
//     c2b_ready
//     c2b_data[31:0]
//     c2b_ecc_status[1:0]
//     c2b_completion
//
// Internal Team-B request side:
//   req_valid/req_ready + context/region metadata.
//
// Internal Team-B response side:
//   rsp_valid/rsp_data/rsp_completion plus ECC event outputs.
//
// Handshake interpretation follows the explicit COMMON_SIGNALS rows:
// b2c_valid requests protected-memory access and c2b_ready means Team C accepts
// that access in the current cycle.  Context and region metadata are held
// stable while b2c_valid is asserted and c2b_ready is deasserted.
//
// ECC:
//   2'b00 : no ECC event
//   2'b01 : correctable; data is delivered and ecc_correctable pulses
//   2'b10 : uncorrectable; data/completion are invalidated, ecc_fatal pulses,
//           and canonical error code 16'h9002 is latched
//   2'b11 : reserved by the common register-map encoding.  This block treats
//           the reserved value fail-closed as fatal and reports 16'h9002; it
//           is NOT redefined as a valid architectural ECC encoding.
//
// A new accepted Team-B request clears the previous transaction error code.
// ============================================================================

module qf_ntt_c2b_if (
    input  logic        clk,
    input  logic        rst_n,

    // Internal Team-B request interface.
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [4:0]  req_context_id,
    input  logic [1:0]  req_region_tag,
    input  logic        abort_i,

    // Common B2C boundary.
    output logic        b2c_valid,
    output logic [4:0]  b2c_context_id,
    output logic [1:0]  b2c_region_tag,

    // Common C2B boundary.
    input  logic        c2b_ready,
    input  logic [31:0] c2b_data,
    input  logic [1:0]  c2b_ecc_status,
    input  logic        c2b_completion,

    // Internal Team-B response/event interface.
    output logic        rsp_valid,
    output logic [31:0] rsp_data,
    output logic        rsp_completion,
    output logic        ecc_correctable,
    output logic        ecc_fatal,
    output logic [15:0] error_code
);

    localparam logic [15:0] ERR_OK                  = 16'h0000;
    localparam logic [15:0] ERR_ECC_UNCORRECTABLE = 16'h9002;

    logic       pending_q;
    logic [4:0] context_q;
    logic [1:0] region_q;

    logic request_accept;
    logic beat_accept;
    logic fatal_accept;

    // Do not advertise acceptance while reset discards incoming requests.
    assign req_ready = rst_n && !pending_q && !abort_i;

    assign b2c_valid      = pending_q && !abort_i;
    assign b2c_context_id = context_q;
    assign b2c_region_tag = region_q;

    assign request_accept = req_valid && req_ready;
    assign beat_accept    = b2c_valid && c2b_ready;

    // 2'b10 is architecturally uncorrectable.  2'b11 is reserved but is
    // deliberately handled fail-closed rather than allowing corrupted state.
    assign fatal_accept =
        beat_accept &&
        ((c2b_ecc_status == 2'b10) ||
         (c2b_ecc_status == 2'b11));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q       <= 1'b0;
            context_q       <= 5'b0;
            region_q        <= 2'b0;
            rsp_valid       <= 1'b0;
            rsp_data        <= 32'b0;
            rsp_completion  <= 1'b0;
            ecc_correctable <= 1'b0;
            ecc_fatal       <= 1'b0;
            error_code      <= ERR_OK;
        end else begin
            rsp_valid       <= 1'b0;
            rsp_completion  <= 1'b0;
            ecc_correctable <= 1'b0;
            ecc_fatal       <= 1'b0;

            if (abort_i) begin
                pending_q <= 1'b0;
            end else begin
                if (request_accept) begin
                    pending_q <= 1'b1;
                    context_q <= req_context_id;
                    region_q  <= req_region_tag;
                    error_code <= ERR_OK;
                end

                if (beat_accept) begin
                    pending_q <= 1'b0;

                    unique case (c2b_ecc_status)
                        2'b00: begin
                            rsp_data  <= c2b_data;
                            rsp_valid <= 1'b1;
                        end

                        2'b01: begin
                            rsp_data        <= c2b_data;
                            rsp_valid       <= 1'b1;
                            ecc_correctable <= 1'b1;
                        end

                        2'b10,
                        2'b11: begin
                            ecc_fatal  <= 1'b1;
                            error_code <= ERR_ECC_UNCORRECTABLE;
                        end

                        default: begin
                            ecc_fatal  <= 1'b1;
                            error_code <= ERR_ECC_UNCORRECTABLE;
                        end
                    endcase
                end

                // Completion is meaningful only for a request beat that is
                // actually accepted by this interface.  Unsolicited Team-C
                // completion activity while idle must not fabricate a Team-B
                // response event.
                if (beat_accept &&
                    c2b_completion &&
                    (error_code == ERR_OK) &&
                    !fatal_accept) begin
                    rsp_completion <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
