/**
 * tb_nvme_top — Integration testbench for nvme_top
 *
 * Per-stage verification with individual timeouts.
 * Each stage waits for a specific event; if it doesn't arrive
 * within STAGE_TIMEOUT cycles, the test reports exactly where
 * the pipeline is stuck and dumps internal state.
 */

`timescale 1ns/1ps

import lynxTypes::*;

module tb_nvme_top;

    // ================================================================
    // Clock & Reset
    // ================================================================
    logic aclk = 0;
    logic aresetn = 0;
    always #2.5 aclk = ~aclk;  // 200 MHz (5ns period)

    localparam int STAGE_TIMEOUT = 2000;  // cycles per stage (~10us)

    // ================================================================
    // Interfaces
    // ================================================================
    metaIntf #(.STYPE(nvme_user_req_t)) s_nvme_user_req [1] (.aclk(aclk));
    metaIntf #(.STYPE(logic [15:0]))    m_nvme_user_rsp [1] (.aclk(aclk));
    metaIntf #(.STYPE(nvme_cqe_t))      m_nvme_cpl      [1] (.aclk(aclk));
    metaIntf #(.STYPE(nvme_mmu_req_t))  m_nvme_rd_sq       (.aclk(aclk));
    metaIntf #(.STYPE(nvme_mmu_rsp_t))  s_nvme_rd_rsp      (.aclk(aclk));
    dmaIntf  m_db_wr_req (.aclk(aclk));
    AXI4S    m_db_wr_data (.aclk(aclk));
    AXI4L    s_nvme_cnfg (.aclk(aclk));
    AXI4     s_nvme_prp  (.aclk(aclk));
    AXI4     s_nvme_sq   (.aclk(aclk));
    AXI4     s_nvme_cq   (.aclk(aclk));

    // ================================================================
    // DUT
    // ================================================================
    nvme_top dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_nvme_user_req(s_nvme_user_req),
        .m_nvme_user_rsp(m_nvme_user_rsp),
        .m_nvme_cpl(m_nvme_cpl),
        .m_nvme_rd_sq(m_nvme_rd_sq),
        .s_nvme_rd_rsp(s_nvme_rd_rsp),
        .m_db_wr_req(m_db_wr_req),
        .m_db_wr_data(m_db_wr_data),
        .s_nvme_cnfg(s_nvme_cnfg),
        .s_nvme_prp(s_nvme_prp),
        .s_nvme_sq(s_nvme_sq),
        .s_nvme_cq(s_nvme_cq)
    );

    // ================================================================
    // Test parameters
    // ================================================================
    localparam logic [3:0]  TEST_DEV_ID     = 4'd0;
    localparam logic [3:0]  TEST_NSID       = 4'd1;
    localparam logic [3:0]  TEST_LBAF       = 4'd9;   // 512B = 2^9
    localparam logic [63:0] TEST_NSZE       = 64'd1000000;
    localparam logic [63:0] TEST_DB_ADDR    = 64'h0000_0000_DEAD_1000;
    localparam logic [63:0] TEST_BAR_BASE   = 64'h0000_0001_0000_0000;
    localparam logic [63:0] TEST_LBA_OFFSET = 64'd0;
    localparam logic [63:0] TEST_LBA_SIZE   = 64'd8192;
    localparam logic [63:0] TEST_VADDR      = 64'h0000_7FFF_0000_0000;
    localparam int unsigned  TEST_LEN       = 4096;
    localparam logic [63:0] TEST_PADDR      = 64'h0000_0000_1234_0000;

    // ================================================================
    // Event flags (set by monitors, checked by main)
    // ================================================================
    logic ev_user_req_accepted = 0;
    logic ev_tbl_req_sent      = 0;
    logic ev_tbl_rsp_received  = 0;
    logic ev_user_rsp_received = 0;
    logic [15:0] user_rsp_error = '0;
    logic ev_mmu_req_out       = 0;
    logic [63:0] mmu_req_vaddr = '0;
    logic ev_mmu_rsp_in        = 0;
    logic ev_sqe_written       = 0;
    logic ev_db_req             = 0;
    logic [63:0] db_paddr       = '0;
    logic ev_db_data            = 0;
    logic [31:0] db_value       = '0;
    logic ev_cqe_detected      = 0;
    logic ev_cpl_out            = 0;
    nvme_cqe_t cpl_data_captured;

    // ================================================================
    // Debug: print user_req_arb / s0 state every cycle after request sent
    // (only prints for 50 cycles to avoid flooding)
    // ================================================================
    // Post-request debug: starts when request accepted, prints 30 cycles
    logic dbg_armed = 0;
    int dbg_cnt = 0;
    always @(posedge aclk) begin
        if (ev_user_req_accepted && !dbg_armed) dbg_armed <= 1;
        if (dbg_armed && dbg_cnt < 30) begin
            dbg_cnt <= dbg_cnt + 1;
            $display("[%0t] [PIPE %0d] s0=%0d tbl_v/r=%0b/%0b cmd_s0_v/r=%0b/%0b | s1=%0d rsp_v/r=%0b/%0b prp_v/r=%0b/%0b cmd_s1_v/r=%0b/%0b | prp_mgr=%0d mmu_v/r=%0b/%0b",
                $time, dbg_cnt,
                dut.inst_nvme_s0.state_C,
                dut.tbl_req.valid, dut.tbl_req.ready,
                dut.cmd_s0.valid, dut.cmd_s0.ready,
                dut.inst_nvme_s1.state_C,
                dut.tbl_rsp.valid, dut.tbl_rsp.ready,
                dut.prp_req.valid, dut.prp_req.ready,
                dut.cmd_s1.valid, dut.cmd_s1.ready,
                dut.inst_nvme_manage_prp.state_C,
                dut.mmu_req_int.valid, dut.mmu_req_int.ready);
        end
    end

    // ================================================================
    // Hierarchical signal monitors (inside DUT)
    // ================================================================

    // --- s0 → info_table (tbl_req) ---
    always @(posedge aclk) begin
        if (dut.tbl_req.valid && dut.tbl_req.ready && !ev_tbl_req_sent) begin
            ev_tbl_req_sent <= 1;
            $display("[%0t] [MONITOR] tbl_req: dev_id=%0d nsid=%0d region=%0d naddr=0x%h len=%0d",
                $time, dut.tbl_req.data.dev_id, dut.tbl_req.data.nsid,
                dut.tbl_req.data.region_id, dut.tbl_req.data.naddr, dut.tbl_req.data.len);
        end
    end

    // --- info_table → s1 (tbl_rsp) ---
    always @(posedge aclk) begin
        if (dut.tbl_rsp.valid && dut.tbl_rsp.ready && !ev_tbl_rsp_received) begin
            ev_tbl_rsp_received <= 1;
            $display("[%0t] [MONITOR] tbl_rsp: error=0x%04h sq_tail=%0d dev_id=%0d lba_offset=%0d lbaf=%0d",
                $time, dut.tbl_rsp.data.error, dut.tbl_rsp.data.sq_tail,
                dut.tbl_rsp.data.dev_id, dut.tbl_rsp.data.lba_offset, dut.tbl_rsp.data.lbaf);
        end
    end

    // --- s1 → user_rsp ---
    always @(posedge aclk) begin
        if (m_nvme_user_rsp[0].valid && m_nvme_user_rsp[0].ready && !ev_user_rsp_received) begin
            ev_user_rsp_received <= 1;
            user_rsp_error <= m_nvme_user_rsp[0].data;
            $display("[%0t] [MONITOR] user_rsp: error=0x%04h", $time, m_nvme_user_rsp[0].data);
        end
    end

    // --- manage_prp → MMU req (external) ---
    always @(posedge aclk) begin
        if (m_nvme_rd_sq.valid && m_nvme_rd_sq.ready && !ev_mmu_req_out) begin
            ev_mmu_req_out <= 1;
            mmu_req_vaddr <= m_nvme_rd_sq.data.vaddr;
            $display("[%0t] [MONITOR] mmu_req_out: vaddr=0x%h len=%0d",
                $time, m_nvme_rd_sq.data.vaddr, m_nvme_rd_sq.data.len);
        end
    end

    // --- MMU rsp → manage_prp ---
    always @(posedge aclk) begin
        if (s_nvme_rd_rsp.valid && s_nvme_rd_rsp.ready && !ev_mmu_rsp_in) begin
            ev_mmu_rsp_in <= 1;
            $display("[%0t] [MONITOR] mmu_rsp_in: paddr=0x%h is_host=%0b last=%0b fault=%0b",
                $time, s_nvme_rd_rsp.data.paddr, s_nvme_rd_rsp.data.is_host,
                s_nvme_rd_rsp.data.last, s_nvme_rd_rsp.data.fault);
        end
    end

    // --- s2 → sqe_strm (SQE written to sq_ctrl) ---
    always @(posedge aclk) begin
        if (dut.sqe_strm.valid && dut.sqe_strm.ready && !ev_sqe_written) begin
            ev_sqe_written <= 1;
            $display("[%0t] [MONITOR] sqe_strm: dev_id=%0d writeRead=%0b nsid=%0d slba=%0d nlba=%0d prp1=0x%h",
                $time, dut.sqe_strm.data.dev_id, dut.sqe_strm.data.writeRead,
                dut.sqe_strm.data.nsid, dut.sqe_strm.data.slba, dut.sqe_strm.data.nlba,
                dut.sqe_strm.data.prp1);
        end
    end

    // --- doorbell DMA req ---
    always @(posedge aclk) begin
        if (m_db_wr_req.valid && m_db_wr_req.ready && !ev_db_req) begin
            ev_db_req <= 1;
            db_paddr <= m_db_wr_req.req.paddr;
            $display("[%0t] [MONITOR] db_wr_req: paddr=0x%h len=%0d",
                $time, m_db_wr_req.req.paddr, m_db_wr_req.req.len);
        end
    end

    // --- doorbell DMA data ---
    always @(posedge aclk) begin
        if (m_db_wr_data.tvalid && m_db_wr_data.tready && !ev_db_data) begin
            ev_db_data <= 1;
            db_value <= m_db_wr_data.tdata[31:0];
            $display("[%0t] [MONITOR] db_wr_data: value=0x%08h (sq_tail=%0d)",
                $time, m_db_wr_data.tdata[31:0], m_db_wr_data.tdata[5:0]);
        end
    end

    // --- CQE detected by cq_ctrl (internal) ---
    always @(posedge aclk) begin
        if (dut.cqe_strm.valid && dut.cqe_strm.ready && !ev_cqe_detected) begin
            ev_cqe_detected <= 1;
            $display("[%0t] [MONITOR] cqe_strm: dev_id=%0d status=0x%04h phase=%0b",
                $time, dut.cqe_strm.data.dev_id, dut.cqe_strm.data.status,
                dut.cqe_strm.data.phase);
        end
    end

    // --- Completion to user ---
    always @(posedge aclk) begin
        if (m_nvme_cpl[0].valid && m_nvme_cpl[0].ready && !ev_cpl_out) begin
            ev_cpl_out <= 1;
            cpl_data_captured <= m_nvme_cpl[0].data;
            $display("[%0t] [MONITOR] m_nvme_cpl: dev_id=%0d status=0x%04h phase=%0b",
                $time, m_nvme_cpl[0].data.dev_id, m_nvme_cpl[0].data.status,
                m_nvme_cpl[0].data.phase);
        end
    end

    // ================================================================
    // MMU Responder (auto-responds to TLB requests)
    // ================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_nvme_rd_rsp.valid <= 1'b0;
            s_nvme_rd_rsp.data  <= '0;
            m_nvme_rd_sq.ready  <= 1'b0;
        end else begin
            m_nvme_rd_sq.ready <= 1'b1;

            if (s_nvme_rd_rsp.valid && s_nvme_rd_rsp.ready)
                s_nvme_rd_rsp.valid <= 1'b0;

            if (m_nvme_rd_sq.valid && m_nvme_rd_sq.ready && !s_nvme_rd_rsp.valid) begin
                s_nvme_rd_rsp.valid       <= 1'b1;
                s_nvme_rd_rsp.data.paddr  <= TEST_PADDR;
                s_nvme_rd_rsp.data.len    <= m_nvme_rd_sq.data.len;
                s_nvme_rd_rsp.data.fault  <= 1'b0;
                s_nvme_rd_rsp.data.is_host<= 1'b1;
                s_nvme_rd_rsp.data.last   <= 1'b1;
            end
        end
    end

    // ================================================================
    // AXI-Lite write task
    // ================================================================
    task automatic axil_write(input logic [63:0] addr, input logic [63:0] data);
        @(posedge aclk);
        s_nvme_cnfg.awaddr   <= addr;
        s_nvme_cnfg.awvalid  <= 1'b1;
        s_nvme_cnfg.awprot   <= 3'b0;
        s_nvme_cnfg.awqos    <= 4'b0;
        s_nvme_cnfg.awregion <= 4'b0;
        s_nvme_cnfg.wdata    <= data;
        s_nvme_cnfg.wstrb    <= {(AXIL_DATA_BITS/8){1'b1}};
        s_nvme_cnfg.wvalid   <= 1'b1;
        s_nvme_cnfg.bready   <= 1'b1;
        wait (s_nvme_cnfg.awready && s_nvme_cnfg.wready);
        @(posedge aclk);
        s_nvme_cnfg.awvalid <= 1'b0;
        s_nvme_cnfg.wvalid  <= 1'b0;
        wait (s_nvme_cnfg.bvalid);
        @(posedge aclk);
        s_nvme_cnfg.bready <= 1'b0;
    endtask

    function automatic logic [63:0] cnfg_addr(int idx);
        return idx * (AXIL_DATA_BITS / 8);
    endfunction

    // ================================================================
    // AXI4 write task (CQ injection)
    // ================================================================
    task automatic axi4_write_cq(
        input logic [63:0]  addr,
        input logic [511:0] data,
        input logic [63:0]  strb
    );
        @(posedge aclk);
        s_nvme_cq.awaddr   <= addr;
        s_nvme_cq.awlen    <= 8'd0;
        s_nvme_cq.awsize   <= 3'b100;
        s_nvme_cq.awburst  <= 2'b01;
        s_nvme_cq.awlock   <= 1'b0;
        s_nvme_cq.awcache  <= 4'b0;
        s_nvme_cq.awprot   <= 3'b0;
        s_nvme_cq.awqos    <= 4'b0;
        s_nvme_cq.awregion <= 4'b0;
        s_nvme_cq.awid     <= '0;
        s_nvme_cq.awvalid  <= 1'b1;
        s_nvme_cq.wdata    <= data;
        s_nvme_cq.wstrb    <= strb;
        s_nvme_cq.wlast    <= 1'b1;
        s_nvme_cq.wvalid   <= 1'b1;
        s_nvme_cq.bready   <= 1'b1;
        wait (s_nvme_cq.awready && s_nvme_cq.wready);
        @(posedge aclk);
        s_nvme_cq.awvalid <= 1'b0;
        s_nvme_cq.wvalid  <= 1'b0;
        s_nvme_cq.wlast   <= 1'b0;
        wait (s_nvme_cq.bvalid);
        @(posedge aclk);
        s_nvme_cq.bready <= 1'b0;
    endtask

    // ================================================================
    // Wait-with-timeout helper
    // Returns 1 if event arrived, 0 if timeout
    // ================================================================
    task automatic wait_event(ref logic flag, input string name, output logic ok);
        int cnt;
        cnt = 0;
        ok = 0;
        while (cnt < STAGE_TIMEOUT) begin
            @(posedge aclk);
            if (flag) begin
                ok = 1;
                return;
            end
            cnt++;
        end
        $display("[%0t] TIMEOUT waiting for: %s (%0d cycles)", $time, name, STAGE_TIMEOUT);
    endtask

    // ================================================================
    // Dump internal pipeline state (for debugging stuck stages)
    // ================================================================
    task automatic dump_pipeline_state();
        $display("  --- Internal Pipeline State ---");
        $display("  s0 state          = %0d", dut.inst_nvme_s0.state_C);
        $display("  tbl_req v/r       = %0b/%0b", dut.tbl_req.valid, dut.tbl_req.ready);
        $display("  tbl_rsp v/r       = %0b/%0b", dut.tbl_rsp.valid, dut.tbl_rsp.ready);
        $display("  s1 state          = %0d", dut.inst_nvme_s1.state_C);
        $display("  user_rsp_arb v/r  = %0b/%0b", dut.user_rsp_arb.valid, dut.user_rsp_arb.ready);
        $display("  prp_req v/r       = %0b/%0b", dut.prp_req.valid, dut.prp_req.ready);
        $display("  cmd_s1 v/r        = %0b/%0b", dut.cmd_s1.valid, dut.cmd_s1.ready);
        $display("  manage_prp state  = %0d", dut.inst_nvme_manage_prp.state_C);
        $display("  mmu_req_int v/r   = %0b/%0b", dut.mmu_req_int.valid, dut.mmu_req_int.ready);
        $display("  m_nvme_rd_sq v/r  = %0b/%0b", m_nvme_rd_sq.valid, m_nvme_rd_sq.ready);
        $display("  s_nvme_rd_rsp v/r = %0b/%0b", s_nvme_rd_rsp.valid, s_nvme_rd_rsp.ready);
        $display("  prp_rsp v/r       = %0b/%0b", dut.prp_rsp.valid, dut.prp_rsp.ready);
        $display("  s2 state          = %0d", dut.inst_nvme_s2.state_C);
        $display("  sqe_strm v/r      = %0b/%0b", dut.sqe_strm.valid, dut.sqe_strm.ready);
        $display("  sq_db_strm v/r    = %0b/%0b", dut.sq_db_strm.valid, dut.sq_db_strm.ready);
        $display("  m_db_wr_req v/r   = %0b/%0b", m_db_wr_req.valid, m_db_wr_req.ready);
        $display("  cqe_strm v/r      = %0b/%0b", dut.cqe_strm.valid, dut.cqe_strm.ready);
        $display("  --------------------------------");
    endtask

    // ================================================================
    // Tie-off initial values
    // ================================================================
    initial begin
        s_nvme_cnfg.awaddr = '0; s_nvme_cnfg.awvalid = 0; s_nvme_cnfg.awprot = '0;
        s_nvme_cnfg.awqos = '0; s_nvme_cnfg.awregion = '0;
        s_nvme_cnfg.wdata = '0; s_nvme_cnfg.wstrb = '0; s_nvme_cnfg.wvalid = 0;
        s_nvme_cnfg.bready = 0;
        s_nvme_cnfg.araddr = '0; s_nvme_cnfg.arvalid = 0; s_nvme_cnfg.arprot = '0;
        s_nvme_cnfg.arqos = '0; s_nvme_cnfg.arregion = '0; s_nvme_cnfg.rready = 0;

        s_nvme_cq.awaddr='0; s_nvme_cq.awvalid=0; s_nvme_cq.awlen='0; s_nvme_cq.awsize='0;
        s_nvme_cq.awburst=2'b01; s_nvme_cq.awlock=0; s_nvme_cq.awcache='0; s_nvme_cq.awprot='0;
        s_nvme_cq.awqos='0; s_nvme_cq.awregion='0; s_nvme_cq.awid='0;
        s_nvme_cq.wdata='0; s_nvme_cq.wstrb='0; s_nvme_cq.wlast=0; s_nvme_cq.wvalid=0;
        s_nvme_cq.bready=0;
        s_nvme_cq.araddr='0; s_nvme_cq.arvalid=0; s_nvme_cq.arlen='0; s_nvme_cq.arsize='0;
        s_nvme_cq.arburst=2'b01; s_nvme_cq.arlock=0; s_nvme_cq.arcache='0; s_nvme_cq.arprot='0;
        s_nvme_cq.arqos='0; s_nvme_cq.arregion='0; s_nvme_cq.arid='0; s_nvme_cq.rready=0;

        s_nvme_sq.awaddr='0; s_nvme_sq.awvalid=0; s_nvme_sq.awlen='0; s_nvme_sq.awsize='0;
        s_nvme_sq.awburst=2'b01; s_nvme_sq.awlock=0; s_nvme_sq.awcache='0; s_nvme_sq.awprot='0;
        s_nvme_sq.awqos='0; s_nvme_sq.awregion='0; s_nvme_sq.awid='0;
        s_nvme_sq.wdata='0; s_nvme_sq.wstrb='0; s_nvme_sq.wlast=0; s_nvme_sq.wvalid=0;
        s_nvme_sq.bready=1; s_nvme_sq.araddr='0; s_nvme_sq.arvalid=0;
        s_nvme_sq.arlen='0; s_nvme_sq.arsize='0; s_nvme_sq.arburst=2'b01; s_nvme_sq.arlock=0;
        s_nvme_sq.arcache='0; s_nvme_sq.arprot='0; s_nvme_sq.arqos='0; s_nvme_sq.arregion='0;
        s_nvme_sq.arid='0; s_nvme_sq.rready=1;

        s_nvme_prp.awaddr='0; s_nvme_prp.awvalid=0; s_nvme_prp.awlen='0; s_nvme_prp.awsize='0;
        s_nvme_prp.awburst=2'b01; s_nvme_prp.awlock=0; s_nvme_prp.awcache='0; s_nvme_prp.awprot='0;
        s_nvme_prp.awqos='0; s_nvme_prp.awregion='0; s_nvme_prp.awid='0;
        s_nvme_prp.wdata='0; s_nvme_prp.wstrb='0; s_nvme_prp.wlast=0; s_nvme_prp.wvalid=0;
        s_nvme_prp.bready=1; s_nvme_prp.araddr='0; s_nvme_prp.arvalid=0;
        s_nvme_prp.arlen='0; s_nvme_prp.arsize='0; s_nvme_prp.arburst=2'b01; s_nvme_prp.arlock=0;
        s_nvme_prp.arcache='0; s_nvme_prp.arprot='0; s_nvme_prp.arqos='0; s_nvme_prp.arregion='0;
        s_nvme_prp.arid='0; s_nvme_prp.rready=1;

        s_nvme_user_req[0].valid = 0; s_nvme_user_req[0].data = '0;
        s_nvme_rd_rsp.valid = 0; s_nvme_rd_rsp.data = '0;
        m_nvme_user_rsp[0].ready = 1;
        m_nvme_cpl[0].ready = 1;
        m_db_wr_req.ready = 1; m_db_wr_req.rsp = '0;
        m_db_wr_data.tready = 1;
        m_nvme_rd_sq.ready = 0;
    end

    // ================================================================
    // Main test sequence
    // ================================================================
    integer pass_count;
    integer fail_count;
    logic stage_ok;

    initial begin
        pass_count = 0;
        fail_count = 0;

        $display("\n========================================");
        $display("  tb_nvme_top: NVMe Pipeline Test");
        $display("  Stage timeout: %0d cycles", STAGE_TIMEOUT);
        $display("========================================\n");

        // ---- Reset ----
        aresetn = 0;
        repeat (20) @(posedge aclk);
        aresetn = 1;
        repeat (10) @(posedge aclk);
        $display("[%0t] Reset released\n", $time);

        // ============================================================
        // STAGE A: Configure device info + permission
        // ============================================================
        $display("=== STAGE A: Configure device info + permission ===");
        axil_write(cnfg_addr(0), TEST_BAR_BASE);
        axil_write(cnfg_addr(2), {60'b0, TEST_DEV_ID});
        axil_write(cnfg_addr(3), {60'b0, TEST_NSID});
        axil_write(cnfg_addr(4), {60'b0, TEST_LBAF});
        axil_write(cnfg_addr(5), TEST_NSZE);
        axil_write(cnfg_addr(6), TEST_DB_ADDR);
        axil_write(cnfg_addr(7), 64'h3);   // valid + reset_queue
        repeat (5) @(posedge aclk);
        axil_write(cnfg_addr(8),  64'd0);
        axil_write(cnfg_addr(9),  {60'b0, TEST_DEV_ID});
        axil_write(cnfg_addr(10), TEST_LBA_OFFSET);
        axil_write(cnfg_addr(11), TEST_LBA_SIZE);
        axil_write(cnfg_addr(12), 64'h1);   // perm_valid
        repeat (10) @(posedge aclk);
        $display("[%0t] STAGE A: PASS (config done)\n", $time);
        pass_count++;

        // ============================================================
        // STAGE B: Send user request → check tbl_req fires
        // ============================================================
        $display("=== STAGE B: Send user request → tbl_req ===");
        begin
            nvme_user_req_t req;
            req = '0;
            req.dev_id    = TEST_DEV_ID;
            req.writeRead = 1'b1;
            req.nsid      = TEST_NSID;
            req.vaddr     = TEST_VADDR;
            req.len       = TEST_LEN;
            req.naddr     = 64'd0;
            req.region_id = '0;

            $display("[%0t] [DBG] Before sending: s0_state=%0d, user_req_arb_ready=%0b",
                $time, dut.inst_nvme_s0.state_C, dut.user_req_arb.ready);

            @(posedge aclk);
            s_nvme_user_req[0].valid <= 1'b1;
            s_nvme_user_req[0].data  <= req;

            $display("[%0t] [DBG] Valid asserted (NBA), waiting for ready...", $time);

            // Wait for ready with local timeout
            begin
                int wait_cnt = 0;
                while (!s_nvme_user_req[0].ready && wait_cnt < 100) begin
                    @(posedge aclk);
                    wait_cnt++;
                    if (wait_cnt <= 10 || wait_cnt % 20 == 0)
                        $display("[%0t] [DBG] wait_cnt=%0d s0_state=%0d arb_v=%0b arb_r=%0b req_v=%0b req_r=%0b",
                            $time, wait_cnt, dut.inst_nvme_s0.state_C,
                            dut.user_req_arb.valid, dut.user_req_arb.ready,
                            s_nvme_user_req[0].valid, s_nvme_user_req[0].ready);
                end
                if (wait_cnt >= 100) begin
                    $display("[%0t] [DBG] STUCK: user_req never accepted! s0_state=%0d", $time, dut.inst_nvme_s0.state_C);
                    $display("[%0t] [DBG]   user_req_arb v/r = %0b/%0b", $time, dut.user_req_arb.valid, dut.user_req_arb.ready);
                    $display("[%0t] [DBG]   tbl_req v/r = %0b/%0b", $time, dut.tbl_req.valid, dut.tbl_req.ready);
                    $display("[%0t] [DBG]   cmd_s0 v/r = %0b/%0b", $time, dut.cmd_s0.valid, dut.cmd_s0.ready);
                    dump_pipeline_state();
                    $finish;
                end
            end

            @(posedge aclk);
            s_nvme_user_req[0].valid <= 1'b0;
            ev_user_req_accepted <= 1;
            $display("[%0t] [DBG] Request accepted!", $time);
        end
        wait_event(ev_tbl_req_sent, "tbl_req (s0 → info_table)", stage_ok);
        if (stage_ok) begin pass_count++; $display("[%0t] STAGE B: PASS\n", $time); end
        else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE C: info_table → tbl_rsp
        // ============================================================
        $display("=== STAGE C: tbl_rsp (info_table → s1) ===");
        wait_event(ev_tbl_rsp_received, "tbl_rsp (info_table → s1)", stage_ok);
        if (stage_ok) begin pass_count++; $display("[%0t] STAGE C: PASS\n", $time); end
        else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE D: user_rsp (error code from s1)
        // ============================================================
        $display("=== STAGE D: user_rsp (s1 → user) ===");
        wait_event(ev_user_rsp_received, "user_rsp (s1 → user)", stage_ok);
        if (stage_ok) begin
            if (user_rsp_error == NVME_NO_ERROR) begin
                pass_count++; $display("[%0t] STAGE D: PASS (NO_ERROR)\n", $time);
            end else begin
                fail_count++;
                $display("[%0t] STAGE D: FAIL (error=0x%04h)\n", $time, user_rsp_error);
                dump_pipeline_state(); $finish;
            end
        end else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE E: MMU request out
        // ============================================================
        $display("=== STAGE E: MMU request (manage_prp → external) ===");
        wait_event(ev_mmu_req_out, "mmu_req out", stage_ok);
        if (stage_ok) begin
            pass_count++;
            $display("[%0t] STAGE E: PASS (vaddr=0x%h)\n", $time, mmu_req_vaddr);
        end else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE F: MMU response consumed
        // ============================================================
        $display("=== STAGE F: MMU response consumed ===");
        wait_event(ev_mmu_rsp_in, "mmu_rsp consumed", stage_ok);
        if (stage_ok) begin pass_count++; $display("[%0t] STAGE F: PASS\n", $time); end
        else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE G: SQE written to sq_ctrl
        // ============================================================
        $display("=== STAGE G: SQE written (s2 → sq_ctrl) ===");
        wait_event(ev_sqe_written, "sqe_strm handshake", stage_ok);
        if (stage_ok) begin pass_count++; $display("[%0t] STAGE G: PASS\n", $time); end
        else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE H: Doorbell DMA request
        // ============================================================
        $display("=== STAGE H: Doorbell DMA request ===");
        wait_event(ev_db_req, "db_wr_req", stage_ok);
        if (stage_ok) begin
            pass_count++;
            $display("[%0t] STAGE H: PASS (paddr=0x%h)\n", $time, db_paddr);
        end else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE I: Doorbell DMA data
        // ============================================================
        $display("=== STAGE I: Doorbell DMA data ===");
        wait_event(ev_db_data, "db_wr_data", stage_ok);
        if (stage_ok) begin
            pass_count++;
            $display("[%0t] STAGE I: PASS (sq_tail value=0x%08h)\n", $time, db_value);
        end else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE J: Inject CQE → cqe_strm detected
        // ============================================================
        $display("=== STAGE J: Inject CQE → cqe detected ===");
        begin
            logic [511:0] cqe_data;
            logic [63:0]  cqe_addr;
            // CID = {dev_id, sq_tail} = {0, 0} = 0
            // DW3 = {status[31:17], phase[16], CID[15:0]}
            cqe_data = '0;
            cqe_data[127:96] = {15'h0000, 1'b1, 16'd0};  // status=0, phase=1, CID=0
            cqe_addr = 64'd0;  // dev_id=0 * 4096 + cq_head=0 * 16
            axi4_write_cq(cqe_addr, cqe_data, 64'h0000_0000_0000_FFFF);
        end
        wait_event(ev_cqe_detected, "cqe_strm (cq_ctrl → output)", stage_ok);
        if (stage_ok) begin pass_count++; $display("[%0t] STAGE J: PASS\n", $time); end
        else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // STAGE K: Completion delivered to user
        // ============================================================
        $display("=== STAGE K: Completion to user ===");
        wait_event(ev_cpl_out, "m_nvme_cpl (user completion)", stage_ok);
        if (stage_ok) begin
            pass_count++;
            $display("[%0t] STAGE K: PASS (dev_id=%0d status=0x%04h phase=%0b)\n",
                $time, cpl_data_captured.dev_id, cpl_data_captured.status,
                cpl_data_captured.phase);
        end else begin fail_count++; dump_pipeline_state(); $finish; end

        // ============================================================
        // Summary
        // ============================================================
        repeat (10) @(posedge aclk);
        $display("\n========================================");
        $display("  Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL STAGES PASSED");
        else
            $display("  TEST FAILED");
        $display("========================================\n");
        $finish;
    end

    // Watchdog — 100us
    initial begin
        #100_000;
        $display("[%0t] WATCHDOG — dumping state:", $time);
        dump_pipeline_state();
        $finish;
    end

endmodule
