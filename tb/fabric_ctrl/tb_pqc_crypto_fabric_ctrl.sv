`timescale 1ns/1ps

/*
 * Self-checking testbench for pqc_crypto_fabric_ctrl.
 *
 * The test verifies:
 * - Reset behaviour
 * - Normal transaction state transitions
 * - Ready, busy and done outputs
 * - Command capture on a valid start/ready handshake
 * - Command stability while the controller is busy
 * - Rejection of another start request while busy
 * - Capture of a later command after returning to Idle
 * - Asynchronous reset during an active transaction
 *
 * Pattern A and Pattern B are arbitrary verification values. They do not
 * represent approved command or profile encodings.
 *
 * Inputs are changed on falling clock edges so that they are stable before
 * the DUT samples them on rising edges. Checks occur 1 ns after a rising
 * edge to allow registered and combinational values to settle.
 *
 * Hierarchical references to state_q and the captured command registers
 * are used for white-box verification.
 */

module tb_pqc_crypto_fabric_ctrl;

  // Clock and active-low reset.
  logic clk_i;
  logic rst_ni;

  // Transaction-control inputs.
  logic a2b_start;
  logic fake_engine_done;

  // Command inputs from Team A.
  logic [5:0] a2b_cmd_opcode;
  logic [3:0] a2b_profile_id;
  logic [4:0] a2b_context_id;

  // Controller response outputs.
  logic b2a_ready;
  logic b2a_busy;
  logic b2a_done;

  // Device under test.
  pqc_crypto_fabric_ctrl dut (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),

    .a2b_start        (a2b_start),
    .fake_engine_done (fake_engine_done),

    .a2b_cmd_opcode   (a2b_cmd_opcode),
    .a2b_profile_id   (a2b_profile_id),
    .a2b_context_id   (a2b_context_id),

    .b2a_ready        (b2a_ready),
    .b2a_busy         (b2a_busy),
    .b2a_done         (b2a_done)
  );

  /*
   * Check the externally visible controller outputs.
   * Any mismatch stops the simulation immediately.
   */
  task automatic check_outputs(
    input logic expected_ready,
    input logic expected_busy,
    input logic expected_done
  );

    if ({b2a_ready, b2a_busy, b2a_done} !==
        {expected_ready, expected_busy, expected_done}) begin

      $fatal(
        1,
        "FAIL time=%0t expected outputs=%03b actual=%03b",
        $time,
        {expected_ready, expected_busy, expected_done},
        {b2a_ready, b2a_busy, b2a_done}
      );

    end else begin

      $display(
        "PASS time=%0t outputs=%03b",
        $time,
        {b2a_ready, b2a_busy, b2a_done}
      );

    end
  endtask

  /*
   * Check the command stored inside the controller.
   * Hierarchical access is used only for verification.
   */
  task automatic check_captured_command(
    input logic [5:0] expected_cmd_opcode,
    input logic [3:0] expected_profile_id,
    input logic [4:0] expected_context_id
  );

    if ({dut.a2b_cmd_opcode_q,
         dut.a2b_profile_id_q,
         dut.a2b_context_id_q} !==
        {expected_cmd_opcode,
         expected_profile_id,
         expected_context_id}) begin

      $fatal(
        1,
        "FAIL time=%0t expected command=%015b actual=%015b",
        $time,
        {expected_cmd_opcode,
         expected_profile_id,
         expected_context_id},
        {dut.a2b_cmd_opcode_q,
         dut.a2b_profile_id_q,
         dut.a2b_context_id_q}
      );

    end else begin

      $display(
        "PASS time=%0t captured command=%015b",
        $time,
        {dut.a2b_cmd_opcode_q,
         dut.a2b_profile_id_q,
         dut.a2b_context_id_q}
      );

    end
  endtask

  /*
   * Check the internal FSM state.
   *
   * State encoding:
   *   00 = Idle
   *   01 = Dispatch
   *   10 = WaitEngine
   *   11 = Report
   */
  task automatic check_state(
    input logic [1:0] expected_state
  );

    if (dut.state_q !== expected_state) begin

      $fatal(
        1,
        "FAIL time=%0t expected state=%02b actual=%02b",
        $time,
        expected_state,
        dut.state_q
      );

    end else begin

      $display(
        "PASS time=%0t state=%02b",
        $time,
        dut.state_q
      );

    end
  endtask

  // Generate a 100 MHz clock with a 10 ns period.
  initial begin
    clk_i = 1'b0;

    forever begin
      #5;
      clk_i = ~clk_i;
    end
  end

  // Main stimulus and checking sequence.
  initial begin

    // Start with reset active and all inputs inactive.
    rst_ni           = 1'b0;
    a2b_start        = 1'b0;
    fake_engine_done = 1'b0;

    a2b_cmd_opcode = '0;
    a2b_profile_id = '0;
    a2b_context_id = '0;

    /*
     * Reset test
     *
     * Keep reset active for two clock cycles and verify that the response
     * outputs and captured command registers are cleared.
     */
    repeat (2) @(negedge clk_i);

    check_outputs(1'b0, 1'b0, 1'b0);
    check_captured_command('0, '0, '0);

    // Make reset inactive and verify that the controller becomes ready.
    rst_ni = 1'b1;

    @(posedge clk_i);
    #1;

    check_outputs(1'b1, 1'b0, 1'b0);
    check_state(2'b00);

    /*
     * Transaction 1
     *
     * Present Pattern A while the controller is ready. The controller
     * must accept and store all three command fields.
     */
    @(negedge clk_i);

    a2b_cmd_opcode = 6'b101101;
    a2b_profile_id = 4'b0110;
    a2b_context_id = 5'b10011;
    a2b_start      = 1'b1;

    // The command is accepted and the controller enters Dispatch.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b1, 1'b0);
    check_state(2'b01);

    check_captured_command(
      6'b101101,
      4'b0110,
      5'b10011
    );

    // Remove start after one clock.
    @(negedge clk_i);
    a2b_start = 1'b0;

    // The controller advances from Dispatch to WaitEngine.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b1, 1'b0);
    check_state(2'b10);

    check_captured_command(
      6'b101101,
      4'b0110,
      5'b10011
    );

    /*
     * Start-while-busy test
     *
     * Present Pattern B and make start active while the controller is
     * waiting for completion. Because ready is low, the new command must
     * not be accepted and Pattern A must remain stored.
     */
    @(negedge clk_i);

    a2b_cmd_opcode = 6'b010010;
    a2b_profile_id = 4'b1001;
    a2b_context_id = 5'b01100;
    a2b_start      = 1'b1;

    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b1, 1'b0);
    check_state(2'b10);

    // Pattern A must remain unchanged.
    check_captured_command(
      6'b101101,
      4'b0110,
      5'b10011
    );

    /*
     * Complete Transaction 1.
     *
     * fake_engine_done models completion from a downstream engine.
     */
    @(negedge clk_i);

    a2b_start        = 1'b0;
    fake_engine_done = 1'b1;

    // Completion moves the controller into Report for one clock.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b0, 1'b1);
    check_state(2'b11);

    check_captured_command(
      6'b101101,
      4'b0110,
      5'b10011
    );

    // Remove the completion indication.
    @(negedge clk_i);
    fake_engine_done = 1'b0;

    // Report lasts one clock, after which the controller returns to Idle.
    @(posedge clk_i);
    #1;

    check_outputs(1'b1, 1'b0, 1'b0);
    check_state(2'b00);

    /*
     * Transaction 2
     *
     * Pattern B remains on the command inputs. Because the controller is
     * ready again, the new transaction must replace Pattern A with Pattern B.
     */
    @(negedge clk_i);
    a2b_start = 1'b1;

    // Pattern B is accepted and the controller enters Dispatch.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b1, 1'b0);
    check_state(2'b01);

    check_captured_command(
      6'b010010,
      4'b1001,
      5'b01100
    );

    // Remove start after one clock.
    @(negedge clk_i);
    a2b_start = 1'b0;

    // The controller advances to WaitEngine.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b1, 1'b0);
    check_state(2'b10);

    check_captured_command(
      6'b010010,
      4'b1001,
      5'b01100
    );

    /*
     * Reset-during-operation test
     *
     * Make reset active while the controller is in WaitEngine. Because
     * reset is asynchronous, the state, outputs and captured fields must
     * clear without waiting for another rising clock edge.
     */
    @(negedge clk_i);
    rst_ni = 1'b0;

    #1;

    check_outputs(1'b0, 1'b0, 1'b0);
    check_state(2'b00);
    check_captured_command('0, '0, '0);

    // Values must remain cleared while reset stays active.
    @(posedge clk_i);
    #1;

    check_outputs(1'b0, 1'b0, 1'b0);
    check_state(2'b00);
    check_captured_command('0, '0, '0);

    // Make reset inactive and verify the controller returns ready.
    @(negedge clk_i);
    rst_ni = 1'b1;

    @(posedge clk_i);
    #1;

    check_outputs(1'b1, 1'b0, 1'b0);
    check_state(2'b00);
    check_captured_command('0, '0, '0);

    $display("ALL CONTROLLER TESTS PASSED");
    $finish;
  end

endmodule
