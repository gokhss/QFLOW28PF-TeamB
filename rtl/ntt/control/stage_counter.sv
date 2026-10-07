// Q-FLOW28-PF: sole owner of stage progression and the captured final stage.
// PROPOSED INTERNAL INTERFACE. No lane dependence, arithmetic datapath, or FSM.
// Legal N: power of two >= 2. Invalid builds/configurations never load.
// Priority: asynchronous reset > clear > load > guarded advance > hold.
// rst_n must be synchronously deasserted by the reset infrastructure.
module stage_counter #(
    parameter int unsigned N = 256,
    localparam int unsigned STAGE_COUNT = $clog2(N),
    localparam int unsigned STAGE_W =
        (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic load,
    input  logic advance,
    input  logic [STAGE_W-1:0] cfg_last_stage,
    output logic [STAGE_W-1:0] stage_count,
    output logic last_stage,
    output logic cfg_valid
);
    localparam bit N_VALID = (N >= 2) && ((N & (N - 32'd1)) == 0);
    localparam logic [STAGE_W-1:0] LAST_INDEX =
        STAGE_W'((STAGE_COUNT > 0) ? STAGE_COUNT - 1 : 0);
    logic [STAGE_W-1:0] last_stage_q;

    generate
        if (LAST_INDEX == {STAGE_W{1'b1}}) begin : g_full_range
            always_comb cfg_valid = N_VALID;
        end else begin : g_partial_range
            always_comb cfg_valid = N_VALID && (cfg_last_stage <= LAST_INDEX);
        end
    endgenerate

    always_comb last_stage = (stage_count == last_stage_q);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_count  <= '0;
            last_stage_q <= '0;
        end else if (clear) begin
            stage_count  <= '0;
            last_stage_q <= '0;
        end else if (load) begin
            if (cfg_valid) begin
                stage_count  <= '0;
                last_stage_q <= cfg_last_stage;
            end
        end else if (advance && (stage_count < last_stage_q)) begin
            // Saturate at the final stage; never wrap on an extra advance.
            stage_count <= stage_count + STAGE_W'(1);
        end
    end
endmodule
