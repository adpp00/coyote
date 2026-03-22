`timescale 1ns/1ps
import lynxTypes::*;

module nvme_sq_ctrl #(
    parameter int unsigned SQ_ADDR_BITS = 6,  // 64 entries per device
    parameter int unsigned N_NVME_BITS  = 4   // number of NVMe devices bits
)(
    input  logic        aclk,
    input  logic        aresetn,

    // From cmd_s2 stage
    metaIntf.s          s_sqe,       // nvme_cmd_s2_t

    // AXI access to observe/debug SQE contents (512-bit view)
    AXI4.s              s_prp_ctrl
);

    localparam int unsigned ADDR_BITS = SQ_ADDR_BITS + N_NVME_BITS;

    // ============================================================
    localparam int unsigned BRAM_BYTE_BITS  = 6;  // log2(512/8)
    localparam int unsigned BRAM_ADDR_WIDTH = ADDR_BITS + BRAM_BYTE_BITS;  // 16

    // ------------------------------------------------------------
    // Write port A (from s_sqe)
    // ------------------------------------------------------------
    logic                      a_en;
    logic [24:0]               a_we;
    logic [ADDR_BITS-1:0]      a_addr;
    logic [199:0]              a_data_in;

    // ------------------------------------------------------------
    // Read port B (from AXI BRAM controller)
    // ------------------------------------------------------------
    logic                      bram_en_a;
    logic [BRAM_ADDR_WIDTH-1:0] bram_addr_a;    // FIX: full byte address (was [ADDR_BITS-1:0])
    logic [ADDR_BITS-1:0]      b_addr;           // entry index into RAM
    logic [ADDR_BITS-1:0]      b_addr_q;         // 1-cycle delayed for CID alignment
    logic [199:0]              b_data_out;

    // 512-bit SQE view presented to AXI bram controller
    logic [511:0]              sq_entry_wire;

    // ------------------------------------------------------------
    // BRAM controller instance (AXI -> BRAM read address, read data back)
    // NOTE: We provide bram_rddata_a (sq_entry_wire) as the read data.
    // ------------------------------------------------------------
    sq_axi_bram_ctrl inst_sq_bram_ctrl (
        .s_axi_aclk       (aclk),
        .s_axi_aresetn     (aresetn),

        .s_axi_awaddr     (s_prp_ctrl.awaddr[BRAM_ADDR_WIDTH-1:0]),
        .s_axi_awlen      (s_prp_ctrl.awlen),
        .s_axi_awsize     (s_prp_ctrl.awsize),
        .s_axi_awburst    (s_prp_ctrl.awburst),
        .s_axi_awlock     (s_prp_ctrl.awlock),
        .s_axi_awcache    (s_prp_ctrl.awcache),
        .s_axi_awprot     (s_prp_ctrl.awprot),
        .s_axi_awvalid    (s_prp_ctrl.awvalid),
        .s_axi_awready    (s_prp_ctrl.awready),

        .s_axi_wdata      (s_prp_ctrl.wdata),
        .s_axi_wstrb      (s_prp_ctrl.wstrb),
        .s_axi_wlast      (s_prp_ctrl.wlast),
        .s_axi_wvalid     (s_prp_ctrl.wvalid),
        .s_axi_wready     (s_prp_ctrl.wready),

        .s_axi_bresp      (s_prp_ctrl.bresp),
        .s_axi_bvalid     (s_prp_ctrl.bvalid),
        .s_axi_bready     (s_prp_ctrl.bready),

        .s_axi_araddr     (s_prp_ctrl.araddr[BRAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen      (s_prp_ctrl.arlen),
        .s_axi_arsize     (s_prp_ctrl.arsize),
        .s_axi_arburst    (s_prp_ctrl.arburst),
        .s_axi_arlock     (s_prp_ctrl.arlock),
        .s_axi_arcache    (s_prp_ctrl.arcache),
        .s_axi_arprot     (s_prp_ctrl.arprot),
        .s_axi_arvalid    (s_prp_ctrl.arvalid),
        .s_axi_arready    (s_prp_ctrl.arready),

        .s_axi_rdata      (s_prp_ctrl.rdata),
        .s_axi_rresp      (s_prp_ctrl.rresp),
        .s_axi_rlast      (s_prp_ctrl.rlast),
        .s_axi_rvalid     (s_prp_ctrl.rvalid),
        .s_axi_rready     (s_prp_ctrl.rready),

        .bram_addr_a      (bram_addr_a),
        .bram_clk_a       (),                 // tied
        .bram_wrdata_a    (),                 // tied (read-only view from AXI)
        .bram_rddata_a    (sq_entry_wire),    // 512-bit SQE view
        .bram_en_a        (bram_en_a),
        .bram_rst_a       (),                 // tied
        .bram_we_a        ()                  // tied
    );

    // ------------------------------------------------------------
    // FIX: byte address → entry index conversion
    //   bram_addr_a = byte address from IP
    //   b_addr      = entry index  = bram_addr_a >> 6
    // (was: assign b_addr = bram_addr_a;)
    // ------------------------------------------------------------
    assign b_addr = bram_addr_a[BRAM_ADDR_WIDTH-1 : BRAM_BYTE_BITS];

    // ------------------------------------------------------------
    // Register b_addr to align CID with b_data_out.
    //   ram_sdp_c has 2-cycle read latency → need 2-stage delay.
    // ------------------------------------------------------------
    logic [ADDR_BITS-1:0] b_addr_q1;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            b_addr_q1 <= '0;
            b_addr_q  <= '0;
        end else if (bram_en_a) begin
            b_addr_q1 <= b_addr;
            b_addr_q  <= b_addr_q1;
        end
    end

    // ------------------------------------------------------------
    // SQ BRAM (200-bit stored format, 2-cycle read latency)
    // ------------------------------------------------------------
    ram_sdp_c #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_BITS (200)
    ) inst_sq_bram (
        .clk        (aclk),
        .a_en       (a_en),
        .a_we       (a_we),
        .a_addr     (a_addr),
        .a_data_in  (a_data_in),
        .b_en       (bram_en_a),
        .b_addr     (b_addr),
        .b_data_out (b_data_out)
    );

    // ------------------------------------------------------------
    // Ingress: cmd_s2 -> BRAM write
    // Store layout (200b):
    // [  3:  0] cmd4
    // [  7:  4] nsid4
    // [ 71:  8] prp1  (64)
    // [135: 72] prp2  (64)
    // [183:136] slba48
    // [199:184] nlba16
    // ------------------------------------------------------------
    always_comb begin
        logic [3:0] cmd4;
        logic [3:0] nsid4;

        cmd4  = s_sqe.data.writeRead ? 4'd1 : 4'd2; // WRITE=1, READ=2
        nsid4 = s_sqe.data.nsid[3:0];

        a_en      = s_sqe.valid;
        a_we      = {25{s_sqe.valid}};
        a_addr    = s_sqe.data.entry;

        a_data_in = '0;
        a_data_in[3:0]     = cmd4;
        a_data_in[7:4]     = nsid4;
        a_data_in[71:8]    = s_sqe.data.prp1;
        a_data_in[135:72]  = s_sqe.data.prp2;
        a_data_in[183:136] = s_sqe.data.slba[47:0];
        a_data_in[199:184] = s_sqe.data.nlba[15:0];

        s_sqe.ready = 1'b1;
    end

    // ------------------------------------------------------------
    // Egress: BRAM (200b) -> 512b NVMe SQE view for AXI reads
    //
    // Use b_addr_q (2-stage registered) for CID generation,
    // aligned with b_data_out (both 2-cycle delayed from read).
    // ------------------------------------------------------------
    always_comb begin
        logic [15:0] cid16;
        logic [7:0]  opcode8;
        logic [31:0] nsid32;
        logic [63:0] prp1_64;
        logic [63:0] prp2_64;
        logic [63:0] slba64;
        logic [15:0] nlba16;

        cid16   = {{(16-ADDR_BITS){1'b0}}, b_addr_q};   // FIX: registered addr (was b_addr)
        opcode8 = {4'b0, b_data_out[3:0]};
        nsid32  = {28'b0, b_data_out[7:4]};
        prp1_64 = b_data_out[71:8];
        prp2_64 = b_data_out[135:72];
        slba64  = {16'b0, b_data_out[183:136]};
        nlba16  = b_data_out[199:184];

        sq_entry_wire = '0;

        // DW0: OPC + FUSE/RSVD + CID
        sq_entry_wire[7:0]   = opcode8;
        sq_entry_wire[15:8]  = 8'h00;
        sq_entry_wire[31:16] = cid16;

        // DW1: NSID
        sq_entry_wire[63:32] = nsid32;

        // DW2..DW5 reserved
        sq_entry_wire[32*2+31:32*2+0] = 32'h0;
        sq_entry_wire[32*3+31:32*3+0] = 32'h0;
        sq_entry_wire[32*4+31:32*4+0] = 32'h0;
        sq_entry_wire[32*5+31:32*5+0] = 32'h0;

        // DW6..DW9 PRP1/PRP2
        sq_entry_wire[32*6+31:32*6+0] = prp1_64[31:0];
        sq_entry_wire[32*7+31:32*7+0] = prp1_64[63:32];
        sq_entry_wire[32*8+31:32*8+0] = prp2_64[31:0];
        sq_entry_wire[32*9+31:32*9+0] = prp2_64[63:32];

        // DW10..DW11 SLBA
        sq_entry_wire[32*10+31:32*10+0] = slba64[31:0];
        sq_entry_wire[32*11+31:32*11+0] = slba64[63:32];

        // DW12 NLB
        sq_entry_wire[32*12+15:32*12+0]  = nlba16;
        sq_entry_wire[32*12+31:32*12+16] = 16'h0;

        // DW13..DW15 reserved
        sq_entry_wire[32*13+31:32*13+0] = 32'h0;
        sq_entry_wire[32*14+31:32*14+0] = 32'h0;
        sq_entry_wire[32*15+31:32*15+0] = 32'h0;
    end

    // ================================================================
    // ILA Debug
    // ================================================================
`define EN_ILA_NVME_SQ_CTRL
`ifdef EN_ILA_NVME_SQ_CTRL
    ila_nvme_sq_ctrl inst_ila_nvme_sq_ctrl (
        .clk    (aclk),
        .probe0 (s_sqe.valid),                          // 1
        .probe1 (s_sqe.ready),                          // 1
        .probe2 (s_sqe.data.dev_id),                    // N_NVME_BITS (4)
        .probe3 (s_sqe.data.entry),                     // N_NVME_BITS+NVME_QUEUE_BITS (10)
        .probe4 (bram_en_a),                            // 1
        .probe5 (a_addr),                               // ADDR_BITS (10)
        .probe6 (a_en),                                 // 1
        .probe7 (b_addr),                               // ADDR_BITS (10)
        .probe8 (b_addr_q),                             // ADDR_BITS (10)
        .probe9 (sq_entry_wire[31:0])                   // 32
    );
`endif

endmodule