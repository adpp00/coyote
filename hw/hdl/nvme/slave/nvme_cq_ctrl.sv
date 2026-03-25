`timescale 1ns/1ps
import lynxTypes::*;

// ------------------------------------------------------------
// CQ Controller (coyote-tcp variant, multi-device)
//
// Single AXI port serves all NVMe devices.
// AXI address[N_NVME_BITS+CQ_ADDR_BITS+3:CQ_ADDR_BITS+4] = dev_id
//   (each device has 4KB = 256 CQE slots × 16B)
//
// CQ table BRAM indexed by {dev_id, CID}.
// FSM round-robins across devices, polling each device's cq_head.
// ------------------------------------------------------------
module nvme_cq_ctrl #(
    parameter int unsigned CQ_ADDR_BITS = 6,
    parameter int unsigned N_NVME_BITS  = N_NVME_BITS,
    parameter int unsigned READ_LATENCY = 1
)(
    input  logic        aclk,
    input  logic        aresetn,

    metaIntf.m          m_cqe,       // nvme_cqe_t {dev_id, status[14:0], phase}
    AXI4.s              s_prp_ctrl
);

    localparam int unsigned CQ_DEPTH     = (1 << CQ_ADDR_BITS);
    localparam int unsigned N_NVME       = (1 << N_NVME_BITS);
    localparam int unsigned CQ_TOTAL_BITS = CQ_ADDR_BITS + N_NVME_BITS;

    // ============================================================
    // AXI BRAM Controller (128-bit, 1 beat = 1 CQE)
    // ============================================================
    logic               bram_en_a;
    logic               bram_clk_a;
    logic               bram_rst_a;
    logic [127:0]       bram_wrdata_a;
    logic [15:0]        bram_we_a;
    logic [18:0]        bram_addr_a;
    logic [127:0]       bram_rddata_a;

    cq_axi_bram_ctrl inst_cq_bram_ctrl (
        .s_axi_aclk       (aclk),
        .s_axi_aresetn    (aresetn),

        .s_axi_awaddr     (s_prp_ctrl.awaddr[18:0]),
        .s_axi_awlen      (s_prp_ctrl.awlen),
        .s_axi_awsize     (s_prp_ctrl.awsize),
        .s_axi_awburst    (s_prp_ctrl.awburst),
        .s_axi_awlock     (s_prp_ctrl.awlock),
        .s_axi_awcache    (s_prp_ctrl.awcache),
        .s_axi_awprot     (s_prp_ctrl.awprot),
        .s_axi_awvalid    (s_prp_ctrl.awvalid),
        .s_axi_awready    (s_prp_ctrl.awready),

        .s_axi_wdata      (s_prp_ctrl.wdata[127:0]),
        .s_axi_wstrb      (s_prp_ctrl.wstrb[15:0]),
        .s_axi_wlast      (s_prp_ctrl.wlast),
        .s_axi_wvalid     (s_prp_ctrl.wvalid),
        .s_axi_wready     (s_prp_ctrl.wready),

        .s_axi_bresp      (s_prp_ctrl.bresp),
        .s_axi_bvalid     (s_prp_ctrl.bvalid),
        .s_axi_bready     (s_prp_ctrl.bready),

        .s_axi_araddr     (s_prp_ctrl.araddr[18:0]),
        .s_axi_arlen      (s_prp_ctrl.arlen),
        .s_axi_arsize     (s_prp_ctrl.arsize),
        .s_axi_arburst    (s_prp_ctrl.arburst),
        .s_axi_arlock     (s_prp_ctrl.arlock),
        .s_axi_arcache    (s_prp_ctrl.arcache),
        .s_axi_arprot     (s_prp_ctrl.arprot),
        .s_axi_arvalid    (s_prp_ctrl.arvalid),
        .s_axi_arready    (s_prp_ctrl.arready),

        .s_axi_rdata      (s_prp_ctrl.rdata[127:0]),
        .s_axi_rresp      (s_prp_ctrl.rresp),
        .s_axi_rlast      (s_prp_ctrl.rlast),
        .s_axi_rvalid     (s_prp_ctrl.rvalid),
        .s_axi_rready     (s_prp_ctrl.rready),

        .bram_addr_a      (bram_addr_a),
        .bram_clk_a       (bram_clk_a),
        .bram_wrdata_a    (bram_wrdata_a),
        .bram_rddata_a    (bram_rddata_a),
        .bram_en_a        (bram_en_a),
        .bram_rst_a       (bram_rst_a),
        .bram_we_a        (bram_we_a)
    );

    // ============================================================
    // CQE Write Detection
    // DW3 = {status[31:17], phase[16], cid[15:0]}
    // dev_id extracted from AXI byte address: addr[N_NVME_BITS+11:12]
    //   (each device = 4KB = 2^12 bytes)
    // ============================================================
    logic                      cqe_wr_detect;
    logic [31:0]               dw3;
    logic [N_NVME_BITS-1:0]    wr_dev_id;
    logic [CQ_ADDR_BITS-1:0]   wr_cid;

    assign cqe_wr_detect = bram_en_a && (|bram_we_a);
    assign dw3           = bram_wrdata_a[127:96];
    assign wr_dev_id     = bram_addr_a[N_NVME_BITS+11:12];
    assign wr_cid        = dw3[CQ_ADDR_BITS-1:0];

    // ============================================================
    // CQ Table BRAM: indexed by {dev_id, CID}
    //   Port A : Write (from NVMe completions)
    //   Port B : Read  (polling by FSM)
    // ============================================================
    logic                       a_en;
    logic [1:0]                 a_we;
    logic [CQ_TOTAL_BITS-1:0]   a_addr;
    logic [15:0]                a_data_in;
    logic [15:0]                a_data_out;

    logic                       b_en;
    logic [CQ_TOTAL_BITS-1:0]   b_addr;
    logic [15:0]                b_data_out;

    assign a_en      = cqe_wr_detect;
    assign a_we      = cqe_wr_detect ? 2'b11 : 2'b00;
    assign a_addr    = {wr_dev_id, wr_cid};
    assign a_data_in = {dw3[31:17], dw3[16]};  // {status[14:0], phase}
    assign b_en      = 1'b1;

    ram_tp_c #(
        .ADDR_BITS (CQ_TOTAL_BITS),
        .DATA_BITS (16)
    ) inst_cq_table (
        .clk        (aclk),
        .a_en       (a_en),
        .a_we       (a_we),
        .a_addr     (a_addr),
        .a_data_in  (a_data_in),
        .a_data_out (a_data_out),
        .b_en       (b_en),
        .b_addr     (b_addr),
        .b_data_out (b_data_out)
    );

    // Last-written CQE latch (for AXI read-back)
    logic [15:0]              last_cqe_data_r;
    logic [CQ_ADDR_BITS-1:0]  last_cqe_cid_r;
    logic [31:0]              last_cqe_word;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            last_cqe_data_r <= '0;
            last_cqe_cid_r  <= '0;
        end else if (a_en && (|a_we)) begin
            last_cqe_data_r <= a_data_in;
            last_cqe_cid_r  <= wr_cid;
        end
    end

    assign last_cqe_word = {{(16-CQ_ADDR_BITS){1'b0}}, last_cqe_cid_r, last_cqe_data_r};
    assign bram_rddata_a = {4{last_cqe_word}};

    // ============================================================
    // Reader FSM types and registers (declared before use)
    // ============================================================
    typedef enum logic [2:0] {
        ST_NEXT_DEV = 3'd0,
        ST_RD_REQ   = 3'd1,
        ST_RD_WAIT  = 3'd2,
        ST_CHECK    = 3'd3,
        ST_OUT      = 3'd4
    } cq_state_e;

    cq_state_e                state_r, state_n;
    logic [N_NVME_BITS-1:0]   poll_dev_r, poll_dev_n;    // current device being polled
    logic [15:0]              cqe_word_r, cqe_word_n;

    // ============================================================
    // Per-device state
    // ============================================================
    logic [CQ_ADDR_BITS-1:0] cq_head_r    [N_NVME];
    logic                    exp_phase_r  [N_NVME];
    logic [CQ_DEPTH-1:0]     cqe_valid_bits [N_NVME];

    // ============================================================
    // Valid Bit Management (per device)
    // ============================================================
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            for (int d = 0; d < N_NVME; d++)
                cqe_valid_bits[d] <= '0;
        end else begin
            // Set on SSD write
            if (cqe_wr_detect) begin
                cqe_valid_bits[wr_dev_id][wr_cid] <= 1'b1;
            end
            // Clear on FSM output
            if (state_r == ST_OUT && m_cqe.valid && m_cqe.ready) begin
                cqe_valid_bits[poll_dev_r][cq_head_r[poll_dev_r]] <= 1'b0;
            end
        end
    end

    // ============================================================
    // Reader FSM: Round-robin across devices, poll cq_head
    // ============================================================

    localparam int unsigned CNT_W = (READ_LATENCY <= 1) ? 1 : $clog2(READ_LATENCY);
    logic [CNT_W-1:0]         wait_cnt_r, wait_cnt_n;

    // BRAM read address = {poll_dev, cq_head[poll_dev]}
    assign b_addr = {poll_dev_r, cq_head_r[poll_dev_r]};

    // Output
    always_comb begin
        m_cqe.valid        = (state_r == ST_OUT);
        m_cqe.data         = '0;
        m_cqe.data.dev_id  = poll_dev_r;
        m_cqe.data.status  = cqe_word_r[15:1];
        m_cqe.data.phase   = cqe_word_r[0];
    end

    // Sequential
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state_r     <= ST_NEXT_DEV;
            poll_dev_r  <= '0;
            cqe_word_r  <= '0;
            wait_cnt_r  <= '0;
            for (int d = 0; d < N_NVME; d++) begin
                cq_head_r[d]   <= '0;
                exp_phase_r[d] <= 1'b1;
            end
        end else begin
            state_r     <= state_n;
            poll_dev_r  <= poll_dev_n;
            cqe_word_r  <= cqe_word_n;
            wait_cnt_r  <= wait_cnt_n;

            // Advance cq_head on successful output
            if (state_r == ST_OUT && m_cqe.valid && m_cqe.ready) begin
                if (cq_head_r[poll_dev_r] == (CQ_DEPTH-1)) begin
                    cq_head_r[poll_dev_r]   <= '0;
                    exp_phase_r[poll_dev_r] <= ~exp_phase_r[poll_dev_r];
                end else begin
                    cq_head_r[poll_dev_r] <= cq_head_r[poll_dev_r] + 1'b1;
                end
            end
        end
    end

    // Next-state logic
    always_comb begin
        state_n     = state_r;
        poll_dev_n  = poll_dev_r;
        cqe_word_n  = cqe_word_r;
        wait_cnt_n  = wait_cnt_r;

        case (state_r)

            ST_NEXT_DEV: begin
                // Round-robin: try next device
                poll_dev_n = poll_dev_r + 1'b1;
                state_n    = ST_RD_REQ;
            end

            ST_RD_REQ: begin
                // Check valid bit for current device's cq_head
                if (cqe_valid_bits[poll_dev_r][cq_head_r[poll_dev_r]]) begin
                    wait_cnt_n = '0;
                    state_n    = (READ_LATENCY == 0) ? ST_CHECK : ST_RD_WAIT;
                end else begin
                    // Nothing ready on this device, try next
                    state_n = ST_NEXT_DEV;
                end
            end

            ST_RD_WAIT: begin
                if (READ_LATENCY <= 1) begin
                    state_n = ST_CHECK;
                end else if (wait_cnt_r == (READ_LATENCY-2)) begin
                    state_n = ST_CHECK;
                end else begin
                    wait_cnt_n = wait_cnt_r + 1'b1;
                end
            end

            ST_CHECK: begin
                cqe_word_n = b_data_out;
                state_n    = ST_OUT;
            end

            ST_OUT: begin
                if (m_cqe.ready) begin
                    state_n = ST_NEXT_DEV;
                end
            end

            default: state_n = ST_NEXT_DEV;

        endcase
    end

    // ================================================================
    // ILA Debug
    // ================================================================
// `define EN_ILA_NVME_CQ_CTRL
`ifdef EN_ILA_NVME_CQ_CTRL
    // Wire for probing current device's cq_head
    logic [CQ_ADDR_BITS-1:0] dbg_cq_head_cur;
    assign dbg_cq_head_cur = cq_head_r[poll_dev_r];

    // Wire for probing current device's valid bits (first 8 bits)
    logic [7:0] dbg_cqe_valid_bits_cur;
    assign dbg_cqe_valid_bits_cur = cqe_valid_bits[poll_dev_r][7:0];

    ila_nvme_cq_ctrl inst_ila_nvme_cq_ctrl (
        .clk    (aclk),
        .probe0 (cqe_wr_detect),                        // 1
        .probe1 (wr_dev_id),                            // N_NVME_BITS (4)
        .probe2 (wr_cid),                               // CQ_ADDR_BITS (6)
        .probe3 (m_cqe.valid),                          // 1
        .probe4 (m_cqe.ready),                          // 1
        .probe5 (m_cqe.data.dev_id),                    // N_NVME_BITS (4)
        .probe6 (m_cqe.data.status),                    // 15
        .probe7 (m_cqe.data.phase),                     // 1
        .probe8 (state_r),                              // 3
        .probe9 (poll_dev_r),                           // N_NVME_BITS (4)
        .probe10(dbg_cq_head_cur),                      // CQ_ADDR_BITS (6)
        .probe11(dbg_cqe_valid_bits_cur),               // 8
        .probe12(b_data_out),                           // 16
        .probe13(cqe_word_r)                            // 16
    );
`endif

endmodule
