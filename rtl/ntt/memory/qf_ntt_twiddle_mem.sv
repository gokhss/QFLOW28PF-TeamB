`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// qf_ntt_twiddle_mem.sv
//
// Q-FLOW28-PF Team-B parameterized twiddle ROM interface.
//
// - One-cycle synchronous read.
// - rd_valid is the registered qualification for rd_data.
// - When rd_en=0, rd_valid deasserts and rd_data holds its previous value.
// - Cryptographic coefficients are supplied only through ROM_INIT.  The
//   production default is all zero and intentionally contains no ML-KEM or
//   ML-DSA coefficient table.
//
// A signed/approved coefficient image can replace ROM_INIT at elaboration
// without changing the RTL datapath or address interface.
// ============================================================================

module qf_ntt_twiddle_mem #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 8,
    parameter int unsigned DEPTH      = 256,
    parameter logic [DATA_WIDTH-1:0] ROM_INIT [0:DEPTH-1] =
        '{default:'0}
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  rd_en,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  rd_valid
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data  <= '0;
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;

            if (rd_en) begin
                rd_data <= ROM_INIT[rd_addr];
            end
        end
    end

endmodule

`default_nettype wire
