`timescale 1ns/1ps
import lynxTypes::*;

module tb_minimal;
    logic aclk = 0;
    logic aresetn = 0;
    always #2.5 aclk = ~aclk;

    // Interfaces
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

    nvme_top dut (.*);

    // Tie-off everything
    initial begin
        s_nvme_user_req[0].valid=0; s_nvme_user_req[0].data='0;
        m_nvme_user_rsp[0].ready=1; m_nvme_cpl[0].ready=1;
        s_nvme_rd_rsp.valid=0; s_nvme_rd_rsp.data='0;
        m_nvme_rd_sq.ready=1;
        m_db_wr_req.ready=1; m_db_wr_req.rsp='0;
        m_db_wr_data.tready=1;

        s_nvme_cnfg.awaddr='0; s_nvme_cnfg.awvalid=0; s_nvme_cnfg.awprot='0;
        s_nvme_cnfg.awqos='0; s_nvme_cnfg.awregion='0;
        s_nvme_cnfg.wdata='0; s_nvme_cnfg.wstrb='0; s_nvme_cnfg.wvalid=0;
        s_nvme_cnfg.bready=1;
        s_nvme_cnfg.araddr='0; s_nvme_cnfg.arvalid=0; s_nvme_cnfg.arprot='0;
        s_nvme_cnfg.arqos='0; s_nvme_cnfg.arregion='0; s_nvme_cnfg.rready=1;

        s_nvme_cq.awaddr='0; s_nvme_cq.awvalid=0; s_nvme_cq.awlen='0; s_nvme_cq.awsize='0;
        s_nvme_cq.awburst=1; s_nvme_cq.awlock=0; s_nvme_cq.awcache='0; s_nvme_cq.awprot='0;
        s_nvme_cq.awqos='0; s_nvme_cq.awregion='0; s_nvme_cq.awid='0;
        s_nvme_cq.wdata='0; s_nvme_cq.wstrb='0; s_nvme_cq.wlast=0; s_nvme_cq.wvalid=0;
        s_nvme_cq.bready=1;
        s_nvme_cq.araddr='0; s_nvme_cq.arvalid=0; s_nvme_cq.arlen='0; s_nvme_cq.arsize='0;
        s_nvme_cq.arburst=1; s_nvme_cq.arlock=0; s_nvme_cq.arcache='0; s_nvme_cq.arprot='0;
        s_nvme_cq.arqos='0; s_nvme_cq.arregion='0; s_nvme_cq.arid='0; s_nvme_cq.rready=1;

        s_nvme_sq.awaddr='0; s_nvme_sq.awvalid=0; s_nvme_sq.awlen='0; s_nvme_sq.awsize='0;
        s_nvme_sq.awburst=1; s_nvme_sq.awlock=0; s_nvme_sq.awcache='0; s_nvme_sq.awprot='0;
        s_nvme_sq.awqos='0; s_nvme_sq.awregion='0; s_nvme_sq.awid='0;
        s_nvme_sq.wdata='0; s_nvme_sq.wstrb='0; s_nvme_sq.wlast=0; s_nvme_sq.wvalid=0;
        s_nvme_sq.bready=1;
        s_nvme_sq.araddr='0; s_nvme_sq.arvalid=0; s_nvme_sq.arlen='0; s_nvme_sq.arsize='0;
        s_nvme_sq.arburst=1; s_nvme_sq.arlock=0; s_nvme_sq.arcache='0; s_nvme_sq.arprot='0;
        s_nvme_sq.arqos='0; s_nvme_sq.arregion='0; s_nvme_sq.arid='0; s_nvme_sq.rready=1;

        s_nvme_prp.awaddr='0; s_nvme_prp.awvalid=0; s_nvme_prp.awlen='0; s_nvme_prp.awsize='0;
        s_nvme_prp.awburst=1; s_nvme_prp.awlock=0; s_nvme_prp.awcache='0; s_nvme_prp.awprot='0;
        s_nvme_prp.awqos='0; s_nvme_prp.awregion='0; s_nvme_prp.awid='0;
        s_nvme_prp.wdata='0; s_nvme_prp.wstrb='0; s_nvme_prp.wlast=0; s_nvme_prp.wvalid=0;
        s_nvme_prp.bready=1;
        s_nvme_prp.araddr='0; s_nvme_prp.arvalid=0; s_nvme_prp.arlen='0; s_nvme_prp.arsize='0;
        s_nvme_prp.arburst=1; s_nvme_prp.arlock=0; s_nvme_prp.arcache='0; s_nvme_prp.arprot='0;
        s_nvme_prp.arqos='0; s_nvme_prp.arregion='0; s_nvme_prp.arid='0; s_nvme_prp.rready=1;
    end

    initial begin
        aresetn = 0;
        repeat(10) @(posedge aclk);
        aresetn = 1;
        $display("[%0t] Reset done", $time);
        repeat(100) @(posedge aclk);
        $display("[%0t] 100 cycles done", $time);
        $finish;
    end
endmodule
