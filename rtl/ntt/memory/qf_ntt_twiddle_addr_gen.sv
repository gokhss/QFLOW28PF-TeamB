`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// qf_ntt_twiddle_addr_gen.sv
//
// Q-FLOW28-PF Team-B standalone NTT twiddle-address generator.
//
// Fixed architectural shape for this verification phase:
//   N                = 256
//   stage_count      = 3 bits, stages 0..7
//   bf_index         = 7 bits, butterflies 0..127
//   twiddle_addr     = 8 bits, ROM addresses 0..255
//
// Address schedules:
//   Forward CT:
//     (1 << stage_count) + (bf_index >> (7 - stage_count))
//
//   Inverse GS:
//     (1 << (7 - stage_count)) - 1
//       - (bf_index >> (stage_count + 1))
//
// The block is purely combinational and contains no data-dependent control.
// ============================================================================

module qf_ntt_twiddle_addr_gen (
    input  logic       transform_intt,
    input  logic [2:0] stage_count,
    input  logic [6:0] bf_index,
    output logic [7:0] twiddle_addr
);

    logic [7:0] bf_ext;
    logic [7:0] base_term;
    logic [7:0] group_term;
    logic [2:0] reverse_stage;
    logic [3:0] inverse_shift;

    always_comb begin
        bf_ext        = {1'b0, bf_index};
        reverse_stage = 3'd7 - stage_count;
        inverse_shift = {1'b0, stage_count} + 4'd1;

        if (!transform_intt) begin
            base_term   = 8'd1 << stage_count;
            group_term  = bf_ext >> reverse_stage;
            twiddle_addr = base_term + group_term;
        end else begin
            base_term   = (8'd1 << reverse_stage) - 8'd1;
            group_term  = bf_ext >> inverse_shift;
            twiddle_addr = base_term - group_term;
        end
    end

endmodule

`default_nettype wire
