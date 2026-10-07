// Verification of supplied components only. NOT a full NTT integration.
// ROM contents below are address tags, never cryptographic coefficients.
module submitted_blocks_tb;
    bit clk;
    always #5 clk=~clk;
    logic rst_n=0;
    logic stage_start=0, butterfly_enable=0, transform_intt=0, abort_i=0;
    logic [2:0] stage_count=0;
    wire rd_en,wr_en,butterfly_done,stage_done,scheduler_busy;
    wire [7:0] rd_addr_u,rd_addr_v,wr_addr_u,wr_addr_v,twiddle_addr;
    wire [6:0] bf_index;
    wire [31:0] rd_data;
    wire rd_valid;
    function automatic logic [31:0] tag(input int unsigned addr);
        return 32'hcafe0000 | addr;
    endfunction
    typedef logic [31:0] rom_t [0:255];
    function automatic rom_t make_rom();
        rom_t result;
        for(int i=0;i<256;i++) result[i]=tag(32'(i));
        return result;
    endfunction
    localparam rom_t TAG_ROM=make_rom();
    qf_ntt_scheduler scheduler(.*);
    qf_ntt_twiddle_addr_gen address_gen(.*);
    qf_ntt_twiddle_mem #(.ROM_INIT(TAG_ROM)) rom(
        .clk(clk),.rst_n(rst_n),.rd_en(rd_en),.rd_addr(twiddle_addr),
        .rd_data(rd_data),.rd_valid(rd_valid));
    logic req_valid=0, req_ready, mem_abort=0;
    logic [4:0] req_context_id=0,b2c_context_id;
    logic [1:0] req_region_tag=0,b2c_region_tag;
    logic b2c_valid,c2b_ready=0,c2b_completion=0;
    logic [31:0] c2b_data=0,rsp_data;
    logic [1:0] c2b_ecc_status=0;
    logic rsp_valid,rsp_completion,ecc_correctable,ecc_fatal;
    logic [15:0] error_code;
    qf_ntt_c2b_if memory_if(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
        .req_context_id(req_context_id),.req_region_tag(req_region_tag),.abort_i(mem_abort),
        .b2c_valid(b2c_valid),.b2c_context_id(b2c_context_id),.b2c_region_tag(b2c_region_tag),
        .c2b_ready(c2b_ready),.c2b_data(c2b_data),.c2b_ecc_status(c2b_ecc_status),
        .c2b_completion(c2b_completion),.rsp_valid(rsp_valid),.rsp_data(rsp_data),
        .rsp_completion(rsp_completion),.ecc_correctable(ecc_correctable),
        .ecc_fatal(ecc_fatal),.error_code(error_code));

    bit [1:0] history_valid;
    logic [7:0] history_u[2],history_v[2];
    logic [31:0] history_twiddle;
    int issued, written, stage_pulses;
    bit [255:0] seen;
    int expected_span;
    bit expected_mode;
    always @(posedge clk) begin : scoreboard
        int distance, a, b, tw;
        if(!rst_n) begin
            history_valid<='0; history_twiddle<=0;
            history_u[0]<=0;history_u[1]<=0;history_v[0]<=0;history_v[1]<=0;
        end else begin
            assert(wr_en==history_valid[1]) else $fatal(1,"write latency");
            assert(butterfly_done==wr_en) else $fatal(1,"butterfly completion qualification");
            assert(rd_valid==history_valid[0]) else $fatal(1,"ROM latency");
            if(rd_valid) assert(rd_data==history_twiddle) else $fatal(1,"ROM data association");
            if(wr_en) begin
                assert(wr_addr_u==history_u[1] && wr_addr_v==history_v[1])
                    else $fatal(1,"write address alignment");
                written <= written+1;
            end
            if(stage_done) begin
                assert(wr_en && written==127 && !abort_i)
                    else $fatal(1,"premature stage completion");
                stage_pulses <= stage_pulses+1;
            end
            if(rd_en) begin
                distance=2**expected_span;
                a=(issued/distance)*(2*distance)+(issued%distance); b=a+distance;
                assert(int'(bf_index)==issued && int'(rd_addr_u)==a && int'(rd_addr_v)==b)
                    else $fatal(1,"pair address/index");
                assert(!seen[a] && !seen[b]) else $fatal(1,"duplicate coefficient");
                seen[a]<=1;seen[b]<=1;
                if(!expected_mode) tw=2**int'(stage_count)+issued/(2**(7-int'(stage_count)));
                else tw=2**(7-int'(stage_count))-1-issued/(2**(int'(stage_count)+1));
                assert(int'(twiddle_addr)==tw) else $fatal(1,"submitted twiddle address formula");
                issued <= issued+1;
            end
            history_valid<={history_valid[0],rd_en};
            history_u[1]<=history_u[0];history_v[1]<=history_v[0];
            history_u[0]<=rd_addr_u;history_v[0]<=rd_addr_v;
            history_twiddle<=tag({24'b0,twiddle_addr});
        end
    end
    task automatic tick; @(posedge clk); #1; endtask
    task automatic check(input bit ok,input string msg);
        if(!ok) $fatal(1,"%s",msg);
    endtask
    task automatic run_stage(input bit inverse,input int s,input int abort_cycle);
        int cycles;
        bit canceled;
        issued=0;written=0;stage_pulses=0;seen='0;cycles=0;canceled=0;
        expected_mode=inverse;expected_span=inverse?7-s:s;
        transform_intt=inverse;stage_count=3'(s);stage_start=1;butterfly_enable=1;
        tick();stage_start=0;
        check(scheduler_busy,"stage accepted");
        while(scheduler_busy) begin
            // A pause only suppresses future reads; writes continue draining.
            butterfly_enable=(cycles%11!=5);
            abort_i=(abort_cycle>=0 && cycles==abort_cycle) ||
                    (abort_cycle==-2 && wr_en && written==127);
            if(abort_i) canceled=1;
            tick();cycles++;
            if(canceled) check(!rd_en && !stage_done,"abort stops next issue");
            if(cycles>200) $fatal(1,"scheduler timeout");
        end
        abort_i=0;butterfly_enable=0;
        check(issued==written,"all committed descriptors drain");
        if(abort_cycle==-1) check(issued==128 && &seen && stage_pulses==1,"full stage coefficient coverage");
        else check(canceled && stage_pulses==0,"abort suppresses stage completion");
        tick();
    endtask
    task automatic memory_request;
        req_valid=1;req_context_id=5'd19;req_region_tag=2'd2;
        check(req_ready,"memory request ready");tick();req_valid=0;
        req_context_id=0;req_region_tag=0;
        repeat(3) begin
            check(b2c_valid && b2c_context_id==19 && b2c_region_tag==2,"stalled payload stable");tick();
        end
    endtask
    assert property (@(posedge clk) disable iff(!rst_n) abort_i |-> !stage_done);
    assert property (@(posedge clk) disable iff(!rst_n)
        ecc_fatal |-> (!rsp_valid && !rsp_completion));
    assert property (@(posedge clk) disable iff(!rst_n)
        b2c_valid && !c2b_ready && !mem_abort |=>
        mem_abort || (b2c_valid && $stable({b2c_context_id,b2c_region_tag})));
    initial begin
        tick();check(!req_ready,"request ready must be low in reset");
        rst_n=1;tick();
        for(int mode=0;mode<2;mode++)
            for(int s=0;s<8;s++) run_stage(1'(mode),s,-1);
        for(int mode=0;mode<2;mode++) begin
            run_stage(1'(mode),0,0);
            run_stage(1'(mode),7,64);
            run_stage(1'(mode),3,139);
            run_stage(1'(mode),7,-2);
        end
        // Global reset during outstanding reads/writeback clears local valids.
        for(int reset_delay=0;reset_delay<3;reset_delay++) begin
            issued=0;written=0;stage_pulses=0;seen='0;
            expected_mode=0;expected_span=0;transform_intt=0;stage_count=0;
            stage_start=1;butterfly_enable=1;tick();stage_start=0;
            repeat(reset_delay+1) tick();
            rst_n=0;#1;
            check(!rd_en && !wr_en && !rd_valid && !stage_done && !scheduler_busy,
                  "reset clears local outstanding metadata");
            tick();rst_n=1;butterfly_enable=0;tick();
        end
        // Data/error behavior for every supplied ECC encoding.
        for(int ecc=0;ecc<4;ecc++) begin
            memory_request();c2b_ecc_status=2'(ecc);c2b_data=32'h1234abcd;
            c2b_completion=1;c2b_ready=1;tick();c2b_ready=0;c2b_completion=0;
            if(ecc<2) check(rsp_valid && rsp_data==32'h1234abcd && rsp_completion &&
                ecc_correctable==(ecc==1) && !ecc_fatal && error_code==0,"nonfatal response");
            else check(!rsp_valid && !rsp_completion && ecc_fatal && error_code==16'h9002,"fatal response");
            tick();check(!rsp_valid && !rsp_completion && !ecc_fatal,"one-cycle events");
        end
        memory_request();mem_abort=1;c2b_ready=1;c2b_completion=1;tick();
        check(!b2c_valid && !rsp_valid && !rsp_completion,"abort wins response");
        mem_abort=0;c2b_ready=0;tick();check(!rsp_completion,"unsolicited completion ignored");
        c2b_completion=0;
        $display("COMPONENT CHECKS COMPLETED: not full architecture verification");$finish;
    end
    initial begin #100000; $fatal(1,"test timeout"); end
endmodule
