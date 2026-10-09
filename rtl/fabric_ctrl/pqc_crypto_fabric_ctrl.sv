module pqc_crypto_fabric_ctrl (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic a2b_start,
  input  logic fake_engine_done,

  input logic [5:0] a2b_cmd_opcode ,
  input logic [3:0] a2b_profile_id,
  input logic [4:0] a2b_context_id,

  output logic b2a_ready,
  output logic b2a_busy,
  output logic b2a_done
);

  typedef enum logic [1:0] {
    StIdle,
    StDispatch,
    StWaitEngine,
    StReport
  } state_t;

  state_t state_q;      //current state stored in ff
  state_t state_d;      //next state that will be stored at the next rising edge

  logic accept_command;

  // Command acceptance event. Inputs are captured only on this handshake.

  assign accept_command = a2b_start && b2a_ready;


  logic [5:0] a2b_cmd_opcode_q;
  logic [3:0] a2b_profile_id_q;
  logic [4:0] a2b_context_id_q;


  // State flip-flops
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StIdle;
    end else begin
      state_q <= state_d;
    end
  end

  // Next-state and output logic
always_comb begin
  // Defaults
  state_d   = state_q;
  b2a_ready = 1'b0;
  b2a_busy  = 1'b0;
  b2a_done  = 1'b0;

  // The contract says the fabric is not ready during reset.
  if (!rst_ni) begin
    state_d = StIdle;
  end else begin
    case (state_q)

      StIdle: begin
        b2a_ready = 1'b1;

        if (accept_command) begin
          state_d = StDispatch;
        end
      end

      StDispatch: begin
        b2a_busy = 1'b1;
        state_d  = StWaitEngine;
      end

      StWaitEngine: begin
        b2a_busy = 1'b1;

        if (fake_engine_done) begin
          state_d = StReport;
        end
      end

      StReport: begin
        b2a_done = 1'b1;
        state_d  = StIdle;
      end

      default: begin
        state_d = StIdle;
      end

    endcase
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a2b_cmd_opcode_q <= 0;
      a2b_profile_id_q <= 0;
      a2b_context_id_q <= 0;
      end
    
    else if (accept_command) begin
      a2b_cmd_opcode_q <= a2b_cmd_opcode;
      a2b_profile_id_q <= a2b_profile_id;
      a2b_context_id_q <= a2b_context_id;
    end
end

endmodule

/*
This is my very first time write RTL and Tb's so I did follow a lot of Chatgpt words, hope it aint' slop
I dont know much of standard design practices so waiting for some brutally honest feedback to work on and build better */